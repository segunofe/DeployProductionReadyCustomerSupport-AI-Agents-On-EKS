################################################################################
# Bedrock AgentCore Memory (Integrated Infrastructure track)
################################################################################

# Short-term event memory. 30-day expiry is sufficient for workshop sessions.
# No memory_strategies configured — the integrated track uses raw event storage
# plus session/actor retrieval, not LLM-derived strategies.
resource "aws_bedrockagentcore_memory" "workshop" {
  name                  = replace("${local.name}_memory", "-", "_")
  event_expiry_duration = 30
  description           = "AgentCore memory for the integrated-infrastructure workshop track"

  tags = local.tags
}

################################################################################
# IAM role for agent pods (integrated track)
#
# Granted to pods via EKS Pod Identity. Allows reading/writing the AgentCore
# memory provisioned above. Model inference goes through LiteLLM (see
# litellm.tf) — the LiteLLM pod holds the Bedrock IAM permissions, not the
# agent pods.
################################################################################

data "aws_iam_policy_document" "agent_pod_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent_pod" {
  name               = "${local.name}-agent-pod"
  assume_role_policy = data.aws_iam_policy_document.agent_pod_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "agent_pod" {
  statement {
    sid    = "AgentCoreMemoryAccess"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:CreateEvent",
      "bedrock-agentcore:GetEvent",
      "bedrock-agentcore:ListEvents",
      "bedrock-agentcore:DeleteEvent",
      "bedrock-agentcore:RetrieveMemoryRecords",
      "bedrock-agentcore:GetMemoryRecord",
      "bedrock-agentcore:ListMemoryRecords",
      "bedrock-agentcore:ListSessions",
      "bedrock-agentcore:ListActors",
    ]
    resources = [aws_bedrockagentcore_memory.workshop.arn]
  }
}

resource "aws_iam_role_policy" "agent_pod" {
  name   = "agent-pod-inline"
  role   = aws_iam_role.agent_pod.id
  policy = data.aws_iam_policy_document.agent_pod.json
}

################################################################################
# Kubernetes wiring: namespace, service account, Pod Identity association
#
# Workshop content for the integrated track deploys agents into the `agents`
# namespace using the `agent` service account. Pod Identity binds the IAM role
# above to that SA, so pods get AWS credentials automatically.
################################################################################

resource "kubernetes_namespace_v1" "agents" {
  metadata {
    name = "agents"
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account_v1" "agent" {
  metadata {
    name      = "agent"
    namespace = kubernetes_namespace_v1.agents.metadata[0].name
  }
}

resource "aws_eks_pod_identity_association" "agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace_v1.agents.metadata[0].name
  service_account = kubernetes_service_account_v1.agent.metadata[0].name
  role_arn        = aws_iam_role.agent_pod.arn
}

################################################################################
# Config surface for the integrated track
#
# Mirrors the self-managed `agent-config` ConfigMap in the default namespace.
# Lives in the `agents` namespace so integrated-track workloads can reference
# it via envFrom without leaking into self-managed modules.
################################################################################

resource "kubernetes_config_map_v1" "agent_config_integrated" {
  metadata {
    name      = "agent-config"
    namespace = kubernetes_namespace_v1.agents.metadata[0].name
  }

  data = {
    AWS_REGION           = local.region
    AGENTCORE_MEMORY_ID  = aws_bedrockagentcore_memory.workshop.id
    AGENTCORE_MEMORY_ARN = aws_bedrockagentcore_memory.workshop.arn
    LITELLM_BASE_URL     = "http://litellm.litellm.svc.cluster.local:4000/v1"
    LITELLM_API_KEY      = local.litellm_master_key
    LANGFUSE_PUBLIC_KEY  = "pk-lf-workshop"
    LANGFUSE_SECRET_KEY  = "sk-lf-workshop"
    LANGFUSE_BASE_URL    = "http://langfuse-web.langfuse.svc.cluster.local:3000"
    # Consumed by the Evaluation with AgentCore lab (700). The agent's OTel
    # spans are dual-exported to Langfuse AND to this AgentCore Observability
    # log group, which AgentCore Evaluations reads from. Defined + created in
    # agentcore-evaluations.tf.
    AGENTCORE_LOG_GROUP     = local.agentcore_eval_log_group
    AGENTCORE_EVAL_ROLE_ARN = aws_iam_role.agentcore_eval_execution.arn
  }
}
