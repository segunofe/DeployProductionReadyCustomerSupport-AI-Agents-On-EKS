################################################################################
# Chainlit Chat UI
#
# Pre-built public ECR image — no per-participant docker build needed.
# Deployment + Service + ALB Ingress so participants can reach the UI from
# the browser-based IDE without port-forwarding.
################################################################################

resource "kubernetes_deployment_v1" "chainlit_ui" {
  metadata {
    name      = "chainlit-ui"
    namespace = "default"
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "chainlit-ui" }
    }

    template {
      metadata {
        labels = { app = "chainlit-ui" }
      }

      spec {
        container {
          name              = "chainlit-ui"
          image             = "public.ecr.aws/s2m9v9j0/chainlit-ui:latest"
          image_pull_policy = "Always"

          port {
            container_port = 8000
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }
      }
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_v1" "chainlit_ui" {
  metadata {
    name      = "chainlit-ui"
    namespace = "default"
  }

  spec {
    selector = { app = "chainlit-ui" }

    port {
      port        = 80
      target_port = 8000
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_ingress_v1" "chainlit_ui" {
  metadata {
    name      = "chainlit-ui"
    namespace = "default"
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
              name = kubernetes_service_v1.chainlit_ui.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_ingress_class_v1.alb]
}
