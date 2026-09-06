################################################################################
# Neo4j - Knowledge Graph Database
#
# Backs the self-managed Knowledge Graph lab (content/20-.../800-knowledge-graph).
# Community edition, single pod, EBS-backed. Deployed like Milvus: participants
# find it running and focus on the agent + graph, not the install.
#
# The `neo4j` LoadBalancer service exposes HTTP (7474, the Neo4j Browser UI)
# and Bolt (7687) through an internet-facing NLB restricted to
# allowed_ingress_cidrs, so participants can see the graph visually.
# In-cluster clients (the agent, the seed job) use the ClusterIP service:
# neo4j://neo4j.neo4j.svc.cluster.local:7687
################################################################################

resource "random_password" "neo4j" {
  length  = 20
  special = false
}

resource "helm_release" "neo4j" {
  name             = "neo4j"
  repository       = "https://helm.neo4j.com/neo4j"
  chart            = "neo4j"
  namespace        = "neo4j"
  create_namespace = true
  wait             = false
  timeout          = 600

  values = [yamlencode({
    neo4j = {
      name     = "neo4j"
      edition  = "community"
      password = random_password.neo4j.result
      resources = {
        cpu    = "500m"
        memory = "2Gi"
      }
    }

    volumes = {
      data = {
        mode = "dynamic"
        dynamic = {
          storageClassName = "auto-ebs-sc"
          accessModes      = ["ReadWriteOnce"]
          requests         = { storage = "10Gi" }
        }
      }
    }

    services = {
      neo4j = {
        enabled = true
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        }
        spec = {
          type = "LoadBalancer"
          # EKS Auto Mode's built-in controller watches this class; extra spec
          # keys pass through the chart's extraSpec helper untouched.
          loadBalancerClass        = "eks.amazonaws.com/nlb"
          loadBalancerSourceRanges = var.allowed_ingress_cidrs
        }
      }
    }
  })]

  depends_on = [
    kubernetes_storage_class_v1.auto_ebs_sc,
    time_sleep.wait_60_seconds,
  ]
}
