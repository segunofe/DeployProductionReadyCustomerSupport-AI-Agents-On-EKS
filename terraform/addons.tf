
################################################################################
# EKS Blueprints Addons
################################################################################

module "eks_blueprints_addons" {
  depends_on = [time_sleep.wait_60_seconds]
  source     = "aws-ia/eks-blueprints-addons/aws"
  version    = "1.23.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  tags = local.tags
}

resource "time_sleep" "wait_90_seconds" {
  create_duration = "90s"

  depends_on = [module.eks_blueprints_addons]
}

################################################################################
# EKS Auto Mode - IngressClass & StorageClass
################################################################################

resource "kubernetes_ingress_class_v1" "alb" {
  metadata {
    name = "alb"
    annotations = {
      "ingressclass.kubernetes.io/is-default-class" = "true"
    }
  }

  spec {
    controller = "eks.amazonaws.com/alb"
  }

  depends_on = [time_sleep.wait_60_seconds]
}

resource "kubernetes_storage_class_v1" "auto_ebs_sc" {
  metadata {
    name = "auto-ebs-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.eks.amazonaws.com"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [time_sleep.wait_60_seconds]
}


################################################################################
# Milvus - Vector Database
################################################################################

resource "helm_release" "milvus" {
  name             = "milvus"
  repository       = "https://zilliztech.github.io/milvus-helm"
  chart            = "milvus"
  namespace        = "milvus"
  create_namespace = true
  wait             = false
  timeout          = 600

  values = [yamlencode({
    cluster = { enabled = false }

    standalone = {
      resources = {
        requests = { cpu = "500m", memory = "2Gi" }
        limits   = { memory = "4Gi" }
      }
      persistence = {
        enabled      = true
        persistentVolumeClaim = {
          storageClass = "auto-ebs-sc"
          size         = "10Gi"
        }
      }
    }

    etcd = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/etcd"
        tag        = "3.5.21-debian-12-r0"
      }
      replicaCount = 1
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
      persistence = {
        enabled      = true
        storageClass = "auto-ebs-sc"
        size         = "10Gi"
      }
    }

    minio = {
      enabled = true
      mode    = "standalone"
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
      persistence = {
        enabled      = true
        storageClass = "auto-ebs-sc"
        size         = "10Gi"
      }
    }

    pulsarv3 = { enabled = false }
    pulsar   = { enabled = false }
    kafka    = { enabled = false }
  })]

  depends_on = [
    kubernetes_storage_class_v1.auto_ebs_sc,
    time_sleep.wait_60_seconds,
  ]
}
