provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# Exclude Local Zones / Wavelength Zones (opt-in zones); EKS control plane and
# NAT gateways only support standard regional AZs. Without this filter, an
# account with Local Zones opted in (e.g. us-west-2-lax-*) can land subnets in
# an unsupported zone.
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# tflint-ignore: terraform_unused_declarations
variable "eks_cluster_id" {
  description = "EKS cluster name"
  type        = string
}
variable "aws_region" {
  description = "AWS Region"
  type        = string
}

locals {
  name   = var.eks_cluster_id
  region = var.aws_region

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name                = local.name
  kubernetes_version  = var.cluster_version
  endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  # EKS Auto Mode
  compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  # EKS Community Addons via Add-on API
  addons = {
    metrics-server = {
      most_recent = true
    }
    kube-state-metrics = {
      most_recent = true
    }
    prometheus-node-exporter = {
      most_recent = true
    }
  }

  tags = local.tags
}

resource "time_sleep" "wait_60_seconds" {
  create_duration = "60s"

  depends_on = [module.eks]
}
