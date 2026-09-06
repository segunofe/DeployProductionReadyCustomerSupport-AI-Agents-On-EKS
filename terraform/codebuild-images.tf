################################################################################
# Pre-build module container images via CodeBuild
#
# Motivation: every lab has participants run essentially the same
# `docker build --push` against the customer-agent / mcp-server / *-agent ECR
# repos, just with a different module tag. From lab 2 onward that build step is
# repetitive friction. This builds all module images up front so the labs are
# turnkey (kubectl apply just pulls), while the lab content keeps the build
# step as an optional "push your own changes" exercise.
#
# Why CodeBuild (not local docker / null_resource): the Terraform host (the
# browser IDE) may not have a usable Docker daemon. CodeBuild runs the builds
# in AWS with a privileged Docker environment, so provisioning only needs the
# AWS CLI, which is already a hard dependency (see base.tf).
#
# The image/tag matrix below mirrors the `docker build --push` commands in the
# content/ markdown. Keep them in sync when modules change.
################################################################################

variable "prebuild_images" {
  description = "Build and push all module container images into ECR at provision time via CodeBuild."
  type        = bool
  default     = true
}

variable "modules_zip_s3_uri" {
  description = <<-EOT
    S3 URI (s3://bucket/key) of the published modules.zip. In the real workshop
    this is injected by the CDK Terraform Runner (TF_VAR_modules_zip_s3_uri) and
    points at the assets bucket. When empty (e.g. local `terraform apply`),
    Terraform zips ../modules and uploads it to a bucket it creates instead.
  EOT
  type        = string
  default     = ""
}

locals {
  # The directory containing all module source (Dockerfiles + app code).
  modules_dir = "${path.module}/../modules"

  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  # When a modules.zip S3 URI is supplied (workshop runner), the CodeBuild job
  # pulls it from S3. Otherwise (local dev) we zip ../modules and upload it.
  use_s3_source = var.modules_zip_s3_uri != ""

  # Final S3 URI the buildspec downloads module source from.
  modules_zip_uri = local.use_s3_source ? var.modules_zip_s3_uri : try("s3://${aws_s3_bucket.image_build_source[0].bucket}/${aws_s3_object.modules_src[0].key}", "")

  # Bucket name + ARN parsed from the URI, used to scope the CodeBuild read
  # permission for either source mode.
  modules_src_bucket     = local.use_s3_source ? split("/", replace(var.modules_zip_s3_uri, "s3://", ""))[0] : try(aws_s3_bucket.image_build_source[0].bucket, "")
  modules_src_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${local.modules_src_bucket}"

  # Image build matrix: one entry per `docker build --push` in the lab content.
  # context  = path under modules/ holding the Dockerfile + sources
  # repo     = ECR repository (must exist in ecr.tf)
  # tag      = module-specific image tag
  # dockerfile = filename when not the default "Dockerfile"
  image_builds = {
    # --- 20-self-managed -----------------------------------------------------
    "customer-agent:strands" = {
      context = "20-self-managed/200-strands-agents/customer-agent"
      repo    = "customer-agent"
      tag     = "strands"
    }
    "customer-agent:langfuse" = {
      context = "20-self-managed/300-observability-langfuse/customer-agent"
      repo    = "customer-agent"
      tag     = "langfuse"
    }
    "customer-agent:milvus" = {
      context = "20-self-managed/400-rag-milvus/customer-agent"
      repo    = "customer-agent"
      tag     = "milvus"
    }
    "customer-agent:milvus-memory" = {
      context = "20-self-managed/500-memory-milvus/customer-agent"
      repo    = "customer-agent"
      tag     = "milvus-memory"
    }
    "mcp-server:v1" = {
      context = "20-self-managed/600-agent-tools-mcp/mcp-server"
      repo    = "mcp-server"
      tag     = "v1"
    }
    "customer-agent:mcp" = {
      context = "20-self-managed/600-agent-tools-mcp/customer-agent"
      repo    = "customer-agent"
      tag     = "mcp"
    }
    "order-agent:v1" = {
      context    = "20-self-managed/700-multi-agent-a2a/a2a-agents"
      repo       = "order-agent"
      tag        = "v1"
      dockerfile = "Dockerfile.order"
    }
    "customer-agent:graph" = {
      context = "20-self-managed/800-knowledge-graph/customer-agent"
      repo    = "customer-agent"
      tag     = "graph"
    }
    "product-agent:v1" = {
      context    = "20-self-managed/700-multi-agent-a2a/a2a-agents"
      repo       = "product-agent"
      tag        = "v1"
      dockerfile = "Dockerfile.product"
    }
    "orchestrator-agent:v1" = {
      context    = "20-self-managed/700-multi-agent-a2a/a2a-agents"
      repo       = "orchestrator-agent"
      tag        = "v1"
      dockerfile = "Dockerfile.orchestrator"
    }

    # --- 30-integrated -------------------------------------------------------
    "customer-agent:bedrock" = {
      context = "30-integrated/100-strands-bedrock/customer-agent"
      repo    = "customer-agent"
      tag     = "bedrock"
    }
    "customer-agent:bedrock-langfuse" = {
      context = "30-integrated/200-observability-langfuse/customer-agent"
      repo    = "customer-agent"
      tag     = "bedrock-langfuse"
    }
    "customer-agent:agentcore-memory" = {
      context = "30-integrated/300-memory-agentcore/customer-agent"
      repo    = "customer-agent"
      tag     = "agentcore-memory"
    }
    "customer-agent:agentcore-tools" = {
      context = "30-integrated/400-managed-tools/customer-agent"
      repo    = "customer-agent"
      tag     = "agentcore-tools"
    }
    "customer-agent:agentcore-eval" = {
      context = "30-integrated/550-evaluation-agentcore/customer-agent"
      repo    = "customer-agent"
      tag     = "agentcore-eval"
    }
    # Multi-agent (integrated). Note Dockerfile.sandbox is pushed as the
    # product-agent:bedrock image (per content/30-.../500-multi-agent-a2a).
    "order-agent:bedrock" = {
      context    = "30-integrated/500-multi-agent-a2a/a2a-integrated"
      repo       = "order-agent"
      tag        = "bedrock"
      dockerfile = "Dockerfile.order"
    }
    "product-agent:bedrock" = {
      context    = "30-integrated/500-multi-agent-a2a/a2a-integrated"
      repo       = "product-agent"
      tag        = "bedrock"
      dockerfile = "Dockerfile.sandbox"
    }
    "orchestrator-agent:bedrock" = {
      context    = "30-integrated/500-multi-agent-a2a/a2a-integrated"
      repo       = "orchestrator-agent"
      tag        = "bedrock"
      dockerfile = "Dockerfile.orchestrator"
    }
  }
}

################################################################################
# Source bundle (local-dev fallback only): zip modules/ and upload to S3.
# Skipped when modules_zip_s3_uri is provided (the workshop runner path), since
# the runner has no ../modules directory next to the Terraform code.
################################################################################

resource "aws_s3_bucket" "image_build_source" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  bucket        = "${local.name}-image-build-src-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "image_build_source" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  bucket                  = aws_s3_bucket.image_build_source[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Zip the modules directory. archive_file recomputes the hash on every plan,
# so edits to module source produce a new object and re-trigger the build.
data "archive_file" "modules" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  type        = "zip"
  source_dir  = local.modules_dir
  output_path = "${path.module}/.terraform/tmp/modules-src.zip"
}

resource "aws_s3_object" "modules_src" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  bucket = aws_s3_bucket.image_build_source[0].id
  key    = "modules-src-${data.archive_file.modules[0].output_md5}.zip"
  source = data.archive_file.modules[0].output_path
  etag   = data.archive_file.modules[0].output_md5
  tags   = local.tags
}

################################################################################
# IAM role for CodeBuild: ECR push + CloudWatch Logs + read source bucket
################################################################################

data "aws_iam_policy_document" "codebuild_assume" {
  count = var.prebuild_images ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild_images" {
  count = var.prebuild_images ? 1 : 0

  name               = "${local.name}-image-prebuild"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume[0].json
  tags               = local.tags
}

data "aws_iam_policy_document" "codebuild_images" {
  count = var.prebuild_images ? 1 : 0

  # ECR auth token is account-wide (no resource scoping possible).
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push/pull scoped to the workshop repos created in ecr.tf.
  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.name}-image-prebuild*"]
  }

  statement {
    sid       = "SourceBucket"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.modules_src_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "codebuild_images" {
  count = var.prebuild_images ? 1 : 0

  name   = "image-prebuild"
  role   = aws_iam_role.codebuild_images[0].id
  policy = data.aws_iam_policy_document.codebuild_images[0].json
}

# Give the CodeBuild service role's policy time to propagate before the build
# is triggered. IAM is eventually-consistent: depends_on guarantees the policy
# is CREATED, not that CodeBuild's assumed role can USE it yet. Without this,
# the very first build on a fresh account can fail in <1s at the QUEUED phase
# with "not authorized to perform: logs:CreateLogStream" (the role can't create
# its own log stream), which surfaces as an opaque "Image pre-build FAILED"
# with empty logs. A short sleep makes the first-try apply reliable.
resource "time_sleep" "codebuild_iam_propagation" {
  count = var.prebuild_images ? 1 : 0

  depends_on      = [aws_iam_role_policy.codebuild_images]
  create_duration = "30s"
}

################################################################################
# CodeBuild project: builds + pushes every image in local.image_builds
################################################################################

resource "aws_codebuild_project" "images" {
  count = var.prebuild_images ? 1 : 0

  name         = "${local.name}-image-prebuild"
  description  = "Pre-builds all workshop module container images and pushes them to ECR."
  service_role = aws_iam_role.codebuild_images[0].arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required for Docker builds

    environment_variable {
      name  = "ECR_REGISTRY"
      value = local.ecr_registry
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = local.region
    }
    environment_variable {
      name  = "MODULES_ZIP_URI"
      value = local.modules_zip_uri
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = local.image_buildspec
  }

  tags = local.tags
}

# Buildspec generated from the image matrix. The module source is pulled from
# S3 (aws s3 cp works cross-region, unlike a native CodeBuild S3 source) and
# unzipped to /tmp/modules. Each image is then built + pushed from there.
locals {
  image_build_lines = [
    for name, b in local.image_builds :
    "docker build --push -t $ECR_REGISTRY/${b.repo}:${b.tag} -f /tmp/modules/${b.context}/${lookup(b, "dockerfile", "Dockerfile")} /tmp/modules/${b.context}"
  ]

  image_buildspec = yamlencode({
    version = "0.2"
    phases = {
      pre_build = {
        commands = [
          "echo Logging in to ECR...",
          "aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY",
          "docker buildx create --use --name workshop-builder || docker buildx use workshop-builder",
          "echo \"Fetching module source from $MODULES_ZIP_URI\"",
          "aws s3 cp \"$MODULES_ZIP_URI\" /tmp/modules.zip",
          "rm -rf /tmp/modules && mkdir -p /tmp/modules",
          "unzip -q /tmp/modules.zip -d /tmp/modules",
        ]
      }
      build = {
        commands = concat(
          ["echo Building ${length(local.image_build_lines)} images..."],
          local.image_build_lines,
        )
      }
      post_build = {
        commands = ["echo All images built and pushed."]
      }
    }
  })
}

################################################################################
# Trigger the build during apply and wait for it to finish.
#
# Re-runs whenever the module source bundle changes (the S3 key embeds the
# content hash). Depends on the ECR repos so push targets exist.
################################################################################

resource "null_resource" "build_images" {
  count = var.prebuild_images ? 1 : 0

  triggers = {
    # In S3-source mode the URI changes when a new modules.zip is published;
    # in local mode the archive hash changes when ../modules changes.
    source_ref     = local.use_s3_source ? var.modules_zip_s3_uri : data.archive_file.modules[0].output_md5
    project        = aws_codebuild_project.images[0].name
    buildspec_hash = sha1(local.image_buildspec)
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = "bash ${path.module}/scripts/run-codebuild.sh ${aws_codebuild_project.images[0].name} ${local.region}"
  }

  depends_on = [
    aws_ecr_repository.this,
    aws_codebuild_project.images,
    # Wait on the propagation delay, not the policy directly, so CodeBuild's
    # assumed role can actually use logs:CreateLogStream when the build fires.
    time_sleep.codebuild_iam_propagation,
  ]
}
