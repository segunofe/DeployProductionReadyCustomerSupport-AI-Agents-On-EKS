
################################################################################
# Inferentia NodePool
################################################################################

resource "null_resource" "inferentia_nodepool" {
  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}
      kubectl apply -f - <<'YAML'
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: inferentia
      spec:
        template:
          spec:
            requirements:
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["on-demand"]
              - key: kubernetes.io/arch
                operator: In
                values: ["amd64"]
              - key: eks.amazonaws.com/instance-family
                operator: In
                values: ["inf2"]
            nodeClassRef:
              group: eks.amazonaws.com
              kind: NodeClass
              name: default
            taints:
              - key: aws.amazon.com/neuron
                effect: NoSchedule
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmpty
          consolidateAfter: 300s
      YAML
    EOT
  }

  depends_on = [time_sleep.wait_60_seconds]
}

################################################################################
# vLLM Namespace
################################################################################

resource "kubernetes_namespace_v1" "vllm" {
  metadata {
    name = "vllm"
  }
  depends_on = [module.eks]
}

################################################################################
# vLLM on Inferentia - Deployment
################################################################################

resource "kubernetes_deployment_v1" "vllm_neuron" {
  metadata {
    name      = "qwen2-5-3b-neuron"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }

  wait_for_rollout = false

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = "qwen2-5-3b-neuron"
      }
    }

    template {
      metadata {
        labels = {
          app = "qwen2-5-3b-neuron"
        }
      }

      spec {
        automount_service_account_token = false

        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        node_selector = {
          "node.kubernetes.io/instance-type" = "inf2.xlarge"
        }

        toleration {
          key      = "aws.amazon.com/neuron"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name              = "vllm"
          image             = "public.ecr.aws/s2m9v9j0/vllm-neuron:qwen2.5-3b-optimum-neuron"
          image_pull_policy = "IfNotPresent"

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["NET_RAW"]
            }
            seccomp_profile {
              type = "RuntimeDefault"
            }
          }

          command = ["vllm", "serve"]
          args = [
            "/root/.cache/neuron/Qwen/Qwen2.5-3B-Instruct",
            "--served-model-name=qwen2-5-3b-neuron",
            "--trust-remote-code",
            "--enable-auto-tool-choice",
            "--tool-call-parser=hermes",
            "--tensor-parallel-size=2",
            "--max-num-seqs=1",
            "--max-model-len=8192",
          ]

          env {
            name  = "HF_HOME"
            value = "/root/.cache/huggingface"
          }
          env {
            name  = "HF_HUB_CACHE"
            value = "/root/.cache/huggingface/hub"
          }
          env {
            name  = "NEURON_RT_NUM_CORES"
            value = "2"
          }
          env {
            name  = "NEURON_RT_VISIBLE_CORES"
            value = "0-1"
          }

          port {
            name           = "http"
            container_port = 8000
          }

          resources {
            requests = {
              cpu                        = "3"
              memory                     = "12Gi"
              "aws.amazon.com/neuroncore" = "2"
            }
            limits = {
              "aws.amazon.com/neuroncore" = "2"
            }
          }

          startup_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 60
            failure_threshold     = 120
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            period_seconds  = 10
            timeout_seconds = 5
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 1800
            period_seconds        = 30
            timeout_seconds       = 10
          }
        }
      }
    }
  }

  depends_on = [null_resource.inferentia_nodepool]
}

################################################################################
# vLLM on Inferentia - Service
################################################################################

resource "kubernetes_service_v1" "vllm_neuron" {
  metadata {
    name      = "qwen2-5-3b-neuron"
    namespace = kubernetes_namespace_v1.vllm.metadata[0].name
  }

  spec {
    type = "ClusterIP"

    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }

    selector = {
      app = "qwen2-5-3b-neuron"
    }
  }

  depends_on = [kubernetes_deployment_v1.vllm_neuron]
}
