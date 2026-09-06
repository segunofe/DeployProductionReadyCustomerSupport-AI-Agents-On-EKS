
################################################################################
# Langfuse - LLM Observability
################################################################################

locals {
  # Langfuse encrypts stored LLM Connection API keys at rest with this key
  # (AES-256-GCM). Must be 256 bits / 64 hex chars (openssl rand -hex 32).
  # Shared between the Helm values below and the pre-seed step in
  # null_resource.langfuse_judge_connection, which encrypts the LiteLLM key
  # in this exact format before writing it to the llm_api_keys table.
  langfuse_encryption_key = "f2e97cc15226ca3f85c548df1ee50aad82d38baae4e8e3e6a0dc21826c68dbc2"

  langfuse_values = {
    langfuse = {
      salt     = { value = "workshop-salt-2026" }
      nextauth = { secret = { value = "workshop-nextauth-secret-2026" } }
      # Required for LLM-as-a-Judge: Langfuse encrypts stored LLM Connection
      # API keys at rest with this key. Without it, saving an LLM connection
      # in the evaluation lab fails with "Missing environment variable:
      # ENCRYPTION_KEY".
      encryptionKey = { value = local.langfuse_encryption_key }
      # Applies to ALL langfuse pods (web AND worker). The LLM-as-a-Judge
      # connection is validated by langfuse-web, but the judge HTTP call
      # itself is made by langfuse-worker — both pods enforce Langfuse's
      # SSRF guard, which blocks RFC1918 / cluster-internal hosts by
      # default and would otherwise fail with "Blocked IP address detected".
      # Scoped to the LiteLLM service hostname only.
      additionalEnv = [
        { name = "LANGFUSE_LLM_CONNECTION_WHITELISTED_HOST", value = "litellm.litellm.svc.cluster.local" },
      ]
      resources = {
        limits   = { cpu = "2", memory = "4Gi" }
        requests = { cpu = "2", memory = "4Gi" }
      }
      ingress = {
        enabled   = true
        className = "alb"
        annotations = {
          "alb.ingress.kubernetes.io/scheme"        = "internet-facing"
          "alb.ingress.kubernetes.io/target-type"   = "ip"
          "alb.ingress.kubernetes.io/listen-ports"  = "[{\"HTTP\":80}]"
          "alb.ingress.kubernetes.io/inbound-cidrs" = join(",", var.allowed_ingress_cidrs)
        }
        hosts = [
          {
            paths = [
              { path = "/", pathType = "Prefix" }
            ]
          }
        ]
      }
      web = {
        livenessProbe = {
          initialDelaySeconds = 300
          failureThreshold    = 30
          periodSeconds       = 30
        }
        readinessProbe = {
          initialDelaySeconds = 60
          failureThreshold    = 30
          periodSeconds       = 15
        }
        pod = {
          additionalEnv = [
            { name = "LANGFUSE_INIT_ORG_ID", value = "anycompany-shop" },
            { name = "LANGFUSE_INIT_ORG_NAME", value = "AnyCompany Shop" },
            { name = "LANGFUSE_INIT_PROJECT_ID", value = "customer-agent" },
            { name = "LANGFUSE_INIT_PROJECT_NAME", value = "AnyCompany Shop" },
            { name = "LANGFUSE_INIT_PROJECT_PUBLIC_KEY", value = "pk-lf-workshop" },
            { name = "LANGFUSE_INIT_PROJECT_SECRET_KEY", value = "sk-lf-workshop" },
            { name = "LANGFUSE_INIT_USER_EMAIL", value = "admin@workshop.local" },
            { name = "LANGFUSE_INIT_USER_NAME", value = "Workshop Admin" },
            { name = "LANGFUSE_INIT_USER_PASSWORD", value = "workshop2025" },
            { name = "TELEMETRY_ENABLED", value = "false" },
          ]
        }
      }
    }
    postgresql = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgresql"
        tag        = "17.3.0-debian-12-r1"
      }
      auth = { username = "langfuse", password = "langfuse-workshop-2025" }
    }
    clickhouse = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/clickhouse"
        tag        = "25.2.1-debian-12-r0"
      }
      auth         = { password = "clickhouse-workshop-2025" }
      shards       = 1
      replicaCount = 1
      resources = {
        limits   = { cpu = "2", memory = "8Gi" }
        requests = { cpu = "2", memory = "8Gi" }
      }
      zookeeper = {
        image = {
          registry   = "docker.io"
          repository = "bitnamilegacy/zookeeper"
          tag        = "3.9.3-debian-12-r8"
        }
        replicaCount = 1
        resources = {
          limits   = { cpu = "2", memory = "4Gi" }
          requests = { cpu = "2", memory = "4Gi" }
        }
      }
    }
    redis = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/valkey"
        tag        = "8.0.2-debian-12-r2"
      }
      auth = { password = "redis-workshop-2025" }
      primary = {
        resources = {
          limits   = { cpu = "1", memory = "2Gi" }
          requests = { cpu = "1", memory = "2Gi" }
        }
      }
    }
    s3 = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/minio"
        tag        = "2024.12.18-debian-12-r1"
      }
      auth = { rootPassword = "minio-workshop-2025" }
      resources = {
        limits   = { cpu = "2", memory = "4Gi" }
        requests = { cpu = "2", memory = "4Gi" }
      }
    }
  }
}

# Step 1: Install with web/worker replicas=0 (infra only)
resource "helm_release" "langfuse" {
  name = "langfuse"
  # Pinned: an unpinned chart resolves to whatever is latest at apply time. The
  # 2.0.0 chart line uses the Helm `fromToml` template function, which the Helm
  # engine bundled in the Terraform runner cannot render ("function \"fromToml\"
  # not defined"), failing the apply. 1.5.41 is the last chart before the 2.0
  # line and renders cleanly. Bump deliberately after re-testing: `helm repo add
  # langfuse https://langfuse.github.io/langfuse-k8s && helm search repo
  # langfuse/langfuse --versions`.
  version          = "1.5.41"
  repository       = "https://langfuse.github.io/langfuse-k8s"
  chart            = "langfuse"
  namespace        = "langfuse"
  create_namespace = true
  wait             = false
  timeout          = 600

  values = [yamlencode(merge(local.langfuse_values, {
    langfuse = merge(local.langfuse_values.langfuse, {
      web    = merge(local.langfuse_values.langfuse.web, { replicas = 0 })
      worker = { replicas = 0 }
    })
  }))]

  depends_on = [time_sleep.wait_60_seconds]
}

# Step 2: Wait for infra pods, then scale up web/worker
resource "null_resource" "langfuse_wait_and_enable" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}

      # Ensure web/worker are at 0 replicas before waiting for infra.
      # Helm values set replicas=0 but upgrades may not re-apply if release exists.
      echo "Scaling web and worker to 0..."
      kubectl scale deploy -n langfuse langfuse-web --replicas=0 2>/dev/null || true
      kubectl scale deploy -n langfuse langfuse-worker --replicas=0 2>/dev/null || true

      echo "Waiting for ClickHouse pods to be scheduled..."
      for i in $(seq 1 10); do
        PODS=$(kubectl get pods -l app.kubernetes.io/name=clickhouse -n langfuse --no-headers 2>/dev/null | wc -l)
        if [ "$PODS" -gt 0 ]; then
          echo "ClickHouse pods found."
          break
        fi
        echo "Attempt $i/10: No ClickHouse pods yet, waiting 30s..."
        sleep 30
      done

      echo "Waiting for ClickHouse to become ready..."
      for i in $(seq 1 5); do
        if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=clickhouse -n langfuse --timeout=180s 2>/dev/null; then
          echo "ClickHouse is ready."
          break
        fi
        echo "Attempt $i/5: ClickHouse not ready, deleting pods to force reschedule..."
        kubectl delete pod -l app.kubernetes.io/name=clickhouse -n langfuse --ignore-not-found
        sleep 30
      done

      # Verify ClickHouse Service is reachable on port 9000 (TCP, used by migrations)
      # Must test from outside the CH pod — same network path langfuse-web uses.
      echo "Verifying ClickHouse Service is reachable on port 9000..."
      for i in $(seq 1 30); do
        if kubectl run ch-check --rm -i -n langfuse --image=busybox --restart=Never -- \
          sh -c "nc -z langfuse-clickhouse 9000" 2>/dev/null; then
          echo "ClickHouse Service port 9000 is reachable."
          break
        fi
        kubectl delete pod ch-check -n langfuse --ignore-not-found 2>/dev/null
        if [ "$i" = "30" ]; then
          echo "ERROR: ClickHouse Service not reachable after 5 minutes"
          exit 1
        fi
        echo "Attempt $i/30: ClickHouse Service not reachable yet, waiting 10s..."
        sleep 10
      done

      echo "Waiting for PostgreSQL to become ready..."
      kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n langfuse --timeout=300s

      # Verify PG is actually accepting connections, not just "pod ready".
      # Prisma migrations will fail fast (P1001) if PG isn't answering yet.
      echo "Verifying PostgreSQL is accepting connections..."
      for i in $(seq 1 30); do
        if kubectl exec -n langfuse langfuse-postgresql-0 -- pg_isready -U postgres 2>&1 | grep -q "accepting connections"; then
          echo "PostgreSQL is accepting connections."
          break
        fi
        if [ "$i" = "30" ]; then
          echo "ERROR: PostgreSQL not accepting connections after 5 minutes"
          exit 1
        fi
        echo "Attempt $i/30: PG not accepting yet, waiting 10s..."
        sleep 10
      done

      echo "Waiting for Redis to become ready..."
      kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=redis -n langfuse --timeout=300s

      echo "All infra pods ready. Scaling up langfuse-web (runs DB migrations)..."
      kubectl scale deploy -n langfuse langfuse-web --replicas=1

      # Wait for web to finish migrations and become ready.
      # Probes are configured with ~20 min of tolerance so migrations on a
      # cold ClickHouse won't get killed mid-run.
      echo "Waiting for langfuse-web rollout to complete (up to 20 min)..."
      if ! kubectl rollout status deploy/langfuse-web -n langfuse --timeout=20m; then
        echo "langfuse-web did not become ready. Attempting dirty-migration recovery..."

        # Dirty state recovery: clear the dirty flag in ClickHouse and restart web.
        # Harmless if there are no dirty rows.
        CH_PW=$(kubectl get secret -n langfuse langfuse-clickhouse -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo "clickhouse-workshop-2025")
        kubectl exec -n langfuse langfuse-clickhouse-shard0-0 -- \
          clickhouse-client --user default --password "$CH_PW" \
          --query "ALTER TABLE schema_migrations UPDATE dirty = 0 WHERE dirty = 1" 2>&1 || true

        echo "Deleting crashed web pod to force restart..."
        kubectl delete pod -n langfuse -l app=web --ignore-not-found --wait=false

        echo "Retrying langfuse-web rollout (up to 15 min)..."
        kubectl rollout status deploy/langfuse-web -n langfuse --timeout=15m
      fi

      echo "langfuse-web ready. Scaling up langfuse-worker..."
      kubectl scale deploy -n langfuse langfuse-worker --replicas=1

      echo "Waiting for langfuse-worker rollout to complete (up to 10 min)..."
      kubectl rollout status deploy/langfuse-worker -n langfuse --timeout=10m

      echo "Langfuse is fully running."
    EOT
  }

  depends_on = [helm_release.langfuse]
}


################################################################################
# Pre-seed the LLM-as-a-Judge connection
#
# Langfuse has no public API for LLM Connections — they live in the Postgres
# `llm_api_keys` table with the secret encrypted at rest (AES-256-GCM, format
# `iv:ciphertext:authTag` hex, keyed by ENCRYPTION_KEY). Both the LiteLLM key
# and the encryption key are known at apply time, so we seed the row here and
# the workshop's "Connect the judge model" step becomes a verification step
# instead of manual UI clicks.
#
# The plaintext LiteLLM key never enters Terraform state or logs: it is piped
# over stdin into a Node one-liner that runs *inside* langfuse-web, which reads
# ENCRYPTION_KEY from its own env and emits only the encrypted blob. The row is
# then upserted into Postgres (unique on project_id+provider, so re-applies are
# idempotent).
################################################################################

resource "null_resource" "langfuse_judge_connection" {
  triggers = {
    litellm_key    = local.litellm_master_key
    encryption_key = local.langfuse_encryption_key
    provider_name  = "litellm-judge"
    custom_models  = "claude-sonnet-4-5"
    base_url       = "http://litellm.litellm.svc.cluster.local:4000/v1"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      LITELLM_KEY = local.litellm_master_key
    }
    # A convenience pre-seed must never gate a ~30-min EKS provision. If any step
    # here fails (Langfuse schema drift across chart bumps, a transient kubectl
    # exec race, or empty encryption output), warn and continue rather than
    # tainting the resource and rolling back a fully-working cluster. The 750 lab
    # documents the manual UI fallback ("Connect the judge model").
    on_failure = continue
    command    = <<-EOT
      set -euo pipefail
      # set -e surfaces a failed step as a non-zero exit, which the provisioner's
      # on_failure = continue then catches — so a seed failure warns, never fails the apply.
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}

      echo "Seeding the judge LLM connection (readiness-gated, with retry)..."
      PG=langfuse-postgresql-0

      # langfuse_wait_and_enable waits for the web rollout, but the seed can still
      # race the Langfuse init that creates the 'customer-agent' project row and the
      # LLM tables. Seeding before that exists is the transient failure that leaves
      # the judge connection missing "forever". So loop until BOTH the project row
      # exists AND the upsert succeeds, re-fetching the Running web pod each attempt
      # (so a mid-bring-up restart doesn't wedge us). ~5 min budget; on_failure =
      # continue is still the final safety net.
      SEEDED=false
      DBURL=""
      for attempt in $(seq 1 30); do
        WEB=$(kubectl get pod -n langfuse -l app=web --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -z "$WEB" ]; then echo "attempt $attempt/30: langfuse-web not Running yet, waiting 10s..."; sleep 10; continue; fi

        # Assemble the DB URL from the web pod's env (the chart exposes the parts,
        # DATABASE_HOST/PORT/NAME/USERNAME/PASSWORD, not a single DATABASE_URL).
        DBURL=$(kubectl exec -n langfuse "$WEB" -- sh -c \
          'printf "postgresql://%s:%s@%s:%s/%s" "$DATABASE_USERNAME" "$DATABASE_PASSWORD" "$DATABASE_HOST" "$${DATABASE_PORT:-5432}" "$DATABASE_NAME"' 2>/dev/null || true)
        if [ -z "$DBURL" ]; then echo "attempt $attempt/30: DB URL not available yet, waiting 10s..."; sleep 10; continue; fi

        # Readiness gate: the customer-agent project row must exist (proves the
        # migrations AND the Langfuse init-project step actually ran).
        if [ "$(kubectl exec -n langfuse "$PG" -- psql "$DBURL" -tAc \
              "select 1 from projects where id='customer-agent' limit 1" 2>/dev/null || true)" != "1" ]; then
          echo "attempt $attempt/30: customer-agent project row not present yet, waiting 10s..."; sleep 10; continue
        fi

        # Encrypt the LiteLLM key INSIDE langfuse-web: Node's crypto + the pod's
        # own ENCRYPTION_KEY. Secret arrives on stdin; only the encrypted blob
        # (iv:ciphertext:authTag hex) is printed. Matches Langfuse's encrypt().
        ENC=$(printf '%s' "$LITELLM_KEY" | kubectl exec -i -n langfuse "$WEB" -- node -e '
          const c = require("crypto");
          const key = Buffer.from(process.env.ENCRYPTION_KEY, "hex");
          let d = "";
          process.stdin.on("data", x => d += x);
          process.stdin.on("end", () => {
            const iv = c.randomBytes(12);
            const ci = c.createCipheriv("aes-256-gcm", key, iv);
            let e = ci.update(d, "utf8", "hex");
            e += ci.final("hex");
            process.stdout.write(iv.toString("hex") + ":" + e + ":" + ci.getAuthTag().toString("hex"));
          });
        ' 2>/dev/null || true)
        if [ -z "$ENC" ]; then echo "attempt $attempt/30: empty encryption output, waiting 10s..."; sleep 10; continue; fi

        # Masked display value (Langfuse shows only a suffix in the UI).
        DISP="sk-...$${LITELLM_KEY: -4}"

        # Upsert the connection. On success we're done; otherwise retry the loop.
        if kubectl exec -i -n langfuse "$PG" -- psql "$DBURL" -v ON_ERROR_STOP=1 <<SQL
INSERT INTO llm_api_keys
  (id, project_id, provider, adapter, display_secret_key, secret_key,
   base_url, custom_models, with_default_models, extra_header_keys,
   created_at, updated_at)
VALUES
  (gen_random_uuid()::text, 'customer-agent', 'litellm-judge', 'openai',
   '$DISP', '$ENC',
   'http://litellm.litellm.svc.cluster.local:4000/v1',
   ARRAY['claude-sonnet-4-5'], false, ARRAY[]::text[],
   now(), now())
ON CONFLICT (project_id, provider) DO UPDATE SET
  adapter             = EXCLUDED.adapter,
  display_secret_key  = EXCLUDED.display_secret_key,
  secret_key          = EXCLUDED.secret_key,
  base_url            = EXCLUDED.base_url,
  custom_models       = EXCLUDED.custom_models,
  with_default_models = EXCLUDED.with_default_models,
  updated_at          = now();
SQL
        then
          echo "Judge LLM connection seeded (litellm-judge / claude-sonnet-4-5), attempt $attempt."
          SEEDED=true
          break
        fi
        echo "attempt $attempt/30: llm_api_keys upsert failed, waiting 10s..."; sleep 10
      done

      if [ "$SEEDED" != "true" ]; then
        echo "WARN: judge-connection seed did not succeed after ~5 min. Set it in the UI — see lab 750." >&2
        exit 0
      fi

      # Pre-seed the DEFAULT eval model so evaluators created in the UI don't
      # prompt "No default model set". Points at the connection above (FK
      # llm_api_key_id, resolved by subquery since its id is generated). One
      # default per project, so the unique key is project_id.
      #
      # This targets default_llm_models — the newer table whose schema/constraints
      # vary most across Langfuse versions ("relation does not exist" / "no unique
      # or exclusion constraint matching the ON CONFLICT"). Run it as a SEPARATE,
      # best-effort step: on any error it degrades to a warning (set the default
      # in the UI, see lab 750) instead of failing the whole apply.
      echo "Pre-seeding the default eval model (best-effort)..."
      if ! kubectl exec -i -n langfuse "$PG" -- psql "$DBURL" -v ON_ERROR_STOP=1 <<SQL
INSERT INTO default_llm_models
  (id, project_id, llm_api_key_id, provider, adapter, model, model_params,
   created_at, updated_at)
SELECT
  gen_random_uuid()::text, 'customer-agent', k.id, 'litellm-judge', 'openai',
  'claude-sonnet-4-5', '{}'::jsonb, now(), now()
FROM llm_api_keys k
WHERE k.project_id = 'customer-agent' AND k.provider = 'litellm-judge'
ON CONFLICT (project_id) DO UPDATE SET
  llm_api_key_id = EXCLUDED.llm_api_key_id,
  provider       = EXCLUDED.provider,
  adapter        = EXCLUDED.adapter,
  model          = EXCLUDED.model,
  updated_at     = now();
SQL
      then
        echo "WARN: could not pre-seed default_llm_models (table/constraint may differ across Langfuse versions). Set the default eval model in the UI — see lab 750." >&2
      fi

      echo "Judge LLM connection seeded (litellm-judge / claude-sonnet-4-5)."
    EOT
  }

  depends_on = [
    null_resource.langfuse_wait_and_enable,
    helm_release.litellm,
  ]
}


################################################################################
# Agent Configuration ConfigMap
################################################################################

resource "kubernetes_config_map_v1" "agent_config" {
  metadata {
    name      = "agent-config"
    namespace = "default"
  }

  data = {
    LITELLM_BASE_URL    = "http://litellm.litellm.svc.cluster.local:4000/v1"
    LITELLM_API_KEY     = local.litellm_master_key
    LANGFUSE_PUBLIC_KEY = "pk-lf-workshop"
    LANGFUSE_SECRET_KEY = "sk-lf-workshop"
    LANGFUSE_BASE_URL   = "http://langfuse-web.langfuse.svc.cluster.local:3000"
    MILVUS_URI          = "http://milvus.milvus.svc.cluster.local:19530"
    NEO4J_URI           = "neo4j://neo4j.neo4j.svc.cluster.local:7687"
    NEO4J_PASSWORD      = random_password.neo4j.result
  }

  depends_on = [module.eks]
}
