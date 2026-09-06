################################################################################
# LiteLLM - Universal model-serving proxy
#
# LiteLLM sits in front of every model backend used in this workshop. Agents in
# BOTH tracks (self-managed and integrated) talk to LiteLLM over the OpenAI
# wire format; LiteLLM then routes to vLLM (self-managed) or Bedrock
# (integrated) based on the `model` name in the request. This turns "swap the
# backend" from a code change into a config change — the agent code path,
# SDK, and HTTP endpoint stay identical across tracks.
################################################################################

# Per-deployment master key. Used as:
#   - LiteLLM proxy masterkey (admin UI login + client Bearer token)
#   - LITELLM_API_KEY env var surfaced through the agent-config ConfigMaps
# A fresh random value is generated per `terraform apply`, so the key
# participants see never matches any value in the public repo.
resource "random_password" "litellm_master_key" {
  length  = 32
  special = false
}

locals {
  litellm_master_key = "sk-${random_password.litellm_master_key.result}"
}

resource "kubernetes_namespace_v1" "litellm" {
  metadata {
    name = "litellm"
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
  }
}

################################################################################
# IAM role for LiteLLM pods
#
# LiteLLM — not the agents — is the only in-cluster workload that invokes
# Bedrock directly. Pod Identity binds this role to the `litellm` service
# account, so the proxy pod gets AWS credentials automatically.
################################################################################

data "aws_iam_policy_document" "litellm_pod_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "litellm_pod" {
  name               = "${local.name}-litellm-pod"
  assume_role_policy = data.aws_iam_policy_document.litellm_pod_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "litellm_pod" {
  statement {
    sid    = "BedrockModelInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
    ]
    resources = ["*"]
  }

  # AWS Marketplace subscription actions for Anthropic (Claude) models.
  #
  # Anthropic Claude is an AWS Marketplace model, not an Amazon-owned one. The
  # Bedrock console "Model access" page is retired; a Marketplace model becomes
  # usable only after its caller completes a one-time, account-wide subscription
  # on first invoke — and that requires aws-marketplace:Subscribe /
  # ViewSubscriptions on the CALLING identity. LiteLLM (this pod) is the only
  # in-cluster workload that calls Bedrock, so without these actions the
  # LLM-as-a-Judge route (claude-sonnet-4-5) 403s on a fresh account with
  # "not authorized to perform the required AWS Marketplace actions", while
  # Nova (Amazon-owned) and qwen (self-hosted) keep working. Amazon-owned models
  # need no subscription, so this only matters for the judge route.
  statement {
    sid    = "BedrockMarketplaceSubscribe"
    effect = "Allow"
    actions = [
      "aws-marketplace:Subscribe",
      "aws-marketplace:ViewSubscriptions",
      "aws-marketplace:Unsubscribe",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "litellm_pod" {
  name   = "litellm-pod-inline"
  role   = aws_iam_role.litellm_pod.id
  policy = data.aws_iam_policy_document.litellm_pod.json
}

resource "aws_eks_pod_identity_association" "litellm" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace_v1.litellm.metadata[0].name
  service_account = kubernetes_service_account_v1.litellm.metadata[0].name
  role_arn        = aws_iam_role.litellm_pod.arn
}

################################################################################
# LiteLLM Helm release
#
# Single proxy pod, three model aliases:
#   - qwen2-5-3b-neuron → vLLM service in the `vllm` namespace
#   - nova-lite         → Bedrock (us.amazon.nova-2-lite-v1:0) via Pod Identity
#   - claude-sonnet-4-5 → Bedrock (us.anthropic.claude-sonnet-4-5-...) via Pod Identity
#                         (LLM-as-a-Judge model). Anthropic is an AWS Marketplace
#                         model, so the pod role also carries aws-marketplace:*
#                         subscribe actions (see litellm_pod policy above) to
#                         complete the one-time account subscription on first
#                         invoke; without them this route 403s on a fresh account.
#
# Forwards its own spans to Langfuse so the proxy itself is visible as a
# tracing point — a bonus "model plane view" alongside the per-agent traces.
################################################################################

locals {
  litellm_values = {
    serviceAccount = {
      create = false
      name   = kubernetes_service_account_v1.litellm.metadata[0].name
    }

    # Pin LiteLLM image. Without this, Helm pulls the latest tag from the
    # chart's appVersion which can drift to tags that don't exist on ghcr.io.
    image = {
      repository = "ghcr.io/berriai/litellm-database"
      tag        = "main-v1.82.3"
      pullPolicy = "IfNotPresent"
    }

    # Pin Postgres image. Bitnami removed older tags from docker.io/bitnami,
    # so use the bitnamilegacy mirror which still hosts versioned tags.
    postgresql = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgresql"
        tag        = "17.3.0-debian-12-r1"
      }
      auth = { username = "litellm", password = "litellm-workshop-2025" }
    }

    # Chart expects a master key; pulled from random_password above so every
    # deployment gets a unique value and nothing in the public repo matches it.
    # Doubles as the login for the admin UI at /ui.
    masterkey = local.litellm_master_key

    # Resource requests so Karpenter provisions adequate nodes and the pod
    # doesn't get OOMKilled during Prisma migrations or under load.
    resources = {
      requests = { cpu = "500m", memory = "2Gi" }
      limits   = { memory = "2Gi" }
    }

    # Give the migration Job more time and retries — PG may take a minute
    # to accept connections on cold starts (EKS Auto Mode node provisioning).
    migrationJob = {
      enabled = false
    }

    # The chart deploys a bundled Postgres by default, which backs the UI's
    # request logs, virtual keys, and spend views. We leave it on so the
    # "Explore the LiteLLM UI" step has something to show.

    proxy_config = {
      model_list = [
        {
          model_name = "qwen2-5-3b-neuron"
          litellm_params = {
            model    = "openai/qwen2-5-3b-neuron"
            api_base = "http://qwen2-5-3b-neuron.vllm.svc.cluster.local:8000/v1"
            api_key  = "not-needed"
            extra_body = {
              chat_template_kwargs = { enable_thinking = false }
            }
          }
        },
        {
          model_name = "nova-lite"
          litellm_params = {
            model           = "bedrock/us.amazon.nova-2-lite-v1:0"
            aws_region_name = local.region
          }
        },
        {
          # Judge model for LLM-as-a-Judge. Sonnet 4.5 (not 4.6) is deliberate:
          # the pinned LiteLLM (main-v1.82.3) only does native Bedrock
          # structured output (outputConfig.textFormat) for a hardcoded model
          # list that includes claude-sonnet-4-5 but NOT 4-6. On 4-6 LiteLLM
          # falls back to a synthetic json_tool_call and returns
          # finish_reason=tool_calls with the JSON in message.content and an
          # EMPTY tool_calls[], which Langfuse's Vercel-AI-SDK evaluator can't
          # parse ("No output generated"). 4.5 takes the native path and
          # returns a clean, parseable structured response. To move to 4.6,
          # upgrade LiteLLM to a version that flags 4-6 via
          # supports_native_structured_output in model_cost, then bump this id.
          model_name = "claude-sonnet-4-5"
          litellm_params = {
            model = "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0"
            # Same region as the rest of the stack. Anthropic is an AWS
            # Marketplace model that must be subscribed on first invoke; the pod
            # role carries the aws-marketplace:* actions to do that itself (see
            # the litellm_pod IAM policy). null_resource.enable_judge_model warms
            # the subscription at apply time so the route is live before the
            # first evaluation, rather than 403ing during propagation.
            aws_region_name = local.region
          }
        },
      ]

      litellm_settings = {
        # Forward LiteLLM's own spans into the workshop Langfuse project.
        success_callback = ["langfuse"]
        failure_callback = ["langfuse"]
      }
    }

    # Wire Langfuse env vars so the callback above has somewhere to send to.
    envVars = {
      LANGFUSE_PUBLIC_KEY = "pk-lf-workshop"
      LANGFUSE_SECRET_KEY = "sk-lf-workshop"
      LANGFUSE_HOST       = "http://langfuse-web.langfuse.svc.cluster.local:3000"
    }

    service = {
      type = "ClusterIP"
      port = 4000
    }
  }
}

################################################################################
# Warm the Anthropic judge model's account subscription (one-time, per region)
#
# Anthropic Claude is an AWS Marketplace model. The Bedrock console "Model
# access" page is retired: a Marketplace model becomes usable only after its
# caller completes a one-time, account-wide subscription on first invoke, which
# requires aws-marketplace:Subscribe / ViewSubscriptions on the CALLER (the pod
# role now carries these — see the litellm_pod policy above). The subscription
# is account-wide but takes a couple of minutes to propagate, and the first
# invoke during that window 403s ("try again after 2 minutes"). If the first
# request to hit Claude is a participant's evaluation, they see that 403.
#
# So we fire the enabling invoke here at apply time (from the provisioning
# identity, which also has Marketplace perms) to trigger the subscription early
# and absorb the propagation delay before anyone runs the lab.
#
# Non-fatal by design: an already-subscribed account returns a normal cheap
# completion; a still-propagating one returns the Marketplace 403, which we log
# (the pod role will complete it on the real first invoke) rather than failing
# the whole apply on a transient state.
################################################################################
resource "null_resource" "enable_judge_model" {
  triggers = {
    region   = local.region
    model_id = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      REGION="${local.region}"
      MODEL="us.anthropic.claude-sonnet-4-5-20250929-v1:0"
      echo "Warming Bedrock judge model $MODEL subscription in $REGION..."
      OUT=$(aws bedrock-runtime converse \
        --region "$REGION" \
        --model-id "$MODEL" \
        --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
        --inference-config '{"maxTokens":1}' 2>&1)
      RC=$?
      if [ $RC -eq 0 ]; then
        echo "Judge model is subscribed and invocable in $REGION."
      elif echo "$OUT" | grep -q 'aws-marketplace'; then
        # Subscription just triggered and is propagating (~2-5 min). Don't fail
        # the apply; the pod role completes it on the real first invoke.
        echo "NOTE: Marketplace subscription for $MODEL is propagating in $REGION (allow ~2-5 min)."
        echo "The LLM-as-a-Judge route will succeed once it settles. If it still 403s well after that,"
        echo "confirm the provisioning identity has aws-marketplace:Subscribe / ViewSubscriptions."
        echo "$OUT"
      else
        echo "WARNING: unexpected error invoking $MODEL in $REGION (continuing apply):"
        echo "$OUT"
      fi
    EOT
  }
}

resource "helm_release" "litellm" {
  name       = "litellm"
  repository = "oci://ghcr.io/berriai"
  chart      = "litellm-helm"
  namespace  = kubernetes_namespace_v1.litellm.metadata[0].name
  wait       = false
  timeout    = 600

  values = [yamlencode(local.litellm_values)]

  depends_on = [
    aws_eks_pod_identity_association.litellm,
    kubernetes_service_v1.vllm_neuron,
    null_resource.enable_judge_model,
  ]
}

################################################################################
# Ingress — separate ALB for the LiteLLM UI + API
#
# Workshop participants use a browser-based VSCode IDE and can't easily reach
# port-forwarded services, so we expose LiteLLM on its own ALB. Langfuse has
# its own ALB too; giving each service a dedicated load balancer avoids the
# path-rewrite issues that come with sharing one (both apps want root paths
# for their static assets).
#
# The UI is protected only by the generated master key (surfaced through the
# agent API key — fine for workshop accounts that get reaped after the event,
# not suitable for anything long-lived.
################################################################################

resource "kubernetes_ingress_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/scheme"        = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"   = "ip"
      "alb.ingress.kubernetes.io/listen-ports"  = "[{\"HTTP\":80}]"
      "alb.ingress.kubernetes.io/inbound-cidrs" = join(",", var.allowed_ingress_cidrs)
    }
  }

  spec {
    ingress_class_name = "alb"
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "litellm"
              port {
                number = 4000
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.litellm]
}
