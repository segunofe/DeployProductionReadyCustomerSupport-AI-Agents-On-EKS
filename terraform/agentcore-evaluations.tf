################################################################################
# AgentCore Evaluations (Integrated Infrastructure track — lab 700)
#
# The integrated agents trace to Langfuse. AgentCore Evaluations, however,
# scores traces it reads from AgentCore Observability (CloudWatch / X-Ray). The
# eval-lab agent therefore DUAL-EXPORTS its OTel spans: to Langfuse (as every
# other module does) and, via a SigV4 OTLP exporter, to the X-Ray endpoint that
# backs AgentCore Observability.
#
# This file provisions the AWS side of that:
#   1. the CloudWatch log group the agent's spans are associated with
#   2. IAM for the agent pod: emit spans (xray write) + run evaluations
#   3. an evaluation execution role that AgentCore Evaluations assumes
#   4. one-time, account-level CloudWatch Transaction Search enablement, without
#      which spans sent to the OTLP endpoint are not queryable by evaluations
################################################################################

locals {
  # Mirrors the AgentCore "agents hosted outside AgentCore" convention:
  #   /aws/bedrock-agentcore/runtimes/<agent-id>
  agentcore_eval_log_group = "/aws/bedrock-agentcore/runtimes/customer-agent-eval"
}

################################################################################
# 1. Log group for the eval agent's traces
################################################################################

resource "aws_cloudwatch_log_group" "agentcore_eval" {
  name              = local.agentcore_eval_log_group
  retention_in_days = 30
  tags              = local.tags
}

################################################################################
# 2. Extend the agent pod role
#
# The agent pod (SA `agent`, see agentcore.tf) needs to (a) emit OTel spans to
# X-Ray, and (b) drive AgentCore Evaluations from the workshop terminal via the
# same Pod Identity credentials. Evaluations run the judge model through
# Bedrock, so InvokeModel is included, and creating an evaluation config that
# uses the execution role requires iam:PassRole on that role.
################################################################################

data "aws_iam_policy_document" "agent_pod_evaluations" {
  # Emit OTel spans to the X-Ray OTLP endpoint (AgentCore Observability).
  # These actions do not support resource-level scoping.
  statement {
    sid    = "XRaySpanIngestion"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutSpans",
      "xray:PutSpansForIndexing",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }

  # Read traces back when running on-demand / online evaluations.
  statement {
    sid    = "XRayTraceRead"
    effect = "Allow"
    actions = [
      "xray:BatchGetTraces",
      "xray:GetTraceSummaries",
      "xray:StartTraceRetrieval",
      "xray:ListRetrievedTraces",
      "xray:GetRetrievedTracesGraph",
    ]
    resources = ["*"]
  }

  # Read the CloudWatch log group the spans land in (Transaction Search stores
  # spans as structured logs).
  statement {
    sid    = "EvalLogRead"
    effect = "Allow"
    actions = [
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:GetQueryResults",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = [
      aws_cloudwatch_log_group.agentcore_eval.arn,
      "${aws_cloudwatch_log_group.agentcore_eval.arn}:*",
      "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:aws/spans:*",
      # The AgentCore Evaluations toolkit also probes the per-endpoint runtime
      # log group (derived as <agent-id>-DEFAULT) before falling back to
      # aws/spans. Grant the runtimes/* prefix so that probe doesn't throw
      # AccessDenied on every run.
      "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
    ]
  }

  # Create and run evaluators / evaluation configs.
  statement {
    sid    = "AgentCoreEvaluations"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:CreateEvaluator",
      "bedrock-agentcore:GetEvaluator",
      "bedrock-agentcore:ListEvaluators",
      "bedrock-agentcore:DeleteEvaluator",
      "bedrock-agentcore:Evaluate",
      "bedrock-agentcore:GetBatchEvaluation",
      "bedrock-agentcore:ListBatchEvaluations",
      "bedrock-agentcore:CreateOnlineEvaluationConfig",
      "bedrock-agentcore:GetOnlineEvaluationConfig",
      "bedrock-agentcore:ListOnlineEvaluationConfigs",
      "bedrock-agentcore:DeleteOnlineEvaluationConfig",
    ]
    resources = ["*"]
  }

  # The judge model runs on Bedrock. Cross-region inference profiles fan out to
  # regional model ARNs, so both the profile and the underlying models are
  # allowed (mirrors the LiteLLM pod's broad InvokeModel grant).
  statement {
    sid    = "EvaluatorModelInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["*"]
  }

  # AWS Marketplace subscription actions for the Anthropic (Claude) judge model.
  # Same reason as the LiteLLM pod role (see litellm.tf): Claude is a Marketplace
  # model that must be subscribed on first invoke, which requires
  # aws-marketplace:Subscribe / ViewSubscriptions on the CALLER. On-demand
  # AgentCore evaluations run under these pod credentials, so without this the
  # cs_accuracy judge 403s with "not authorized to perform the required AWS
  # Marketplace actions" — exactly like the self-managed judge did.
  statement {
    sid    = "EvaluatorMarketplaceSubscribe"
    effect = "Allow"
    actions = [
      "aws-marketplace:Subscribe",
      "aws-marketplace:ViewSubscriptions",
      "aws-marketplace:Unsubscribe",
    ]
    resources = ["*"]
  }

  # Creating an online evaluation config hands the execution role to the
  # service (dependent action iam:PassRole).
  statement {
    sid       = "PassEvalExecutionRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.agentcore_eval_execution.arn]
  }
}

resource "aws_iam_role_policy" "agent_pod_evaluations" {
  name   = "agent-pod-agentcore-evaluations"
  role   = aws_iam_role.agent_pod.id
  policy = data.aws_iam_policy_document.agent_pod_evaluations.json
}

################################################################################
# 3. Evaluation execution role
#
# AgentCore Evaluations assumes this role to read traces and invoke the judge
# model on your behalf (used by online evaluation configs; on-demand runs use
# the caller's own credentials, but online configs require a passed role).
################################################################################

data "aws_iam_policy_document" "agentcore_eval_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agentcore_eval_execution" {
  name               = "${local.name}-agentcore-eval-exec"
  assume_role_policy = data.aws_iam_policy_document.agentcore_eval_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "agentcore_eval_execution" {
  statement {
    sid    = "ReadTraces"
    effect = "Allow"
    actions = [
      "xray:BatchGetTraces",
      "xray:GetTraceSummaries",
      "xray:StartTraceRetrieval",
      "xray:ListRetrievedTraces",
      "xray:GetRetrievedTracesGraph",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:GetQueryResults",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "InvokeJudgeModel"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["*"]
  }

  # Marketplace subscription actions for the Anthropic judge model — same reason
  # as the agent-pod role above. AgentCore assumes THIS role for online
  # evaluation configs, and it invokes the Claude judge, so it needs to complete
  # / view the Marketplace subscription too.
  statement {
    sid    = "InvokeJudgeMarketplaceSubscribe"
    effect = "Allow"
    actions = [
      "aws-marketplace:Subscribe",
      "aws-marketplace:ViewSubscriptions",
      "aws-marketplace:Unsubscribe",
    ]
    resources = ["*"]
  }

  # Online evaluation writes per-config score results to a CloudWatch log group
  # it creates under /aws/bedrock-agentcore/evaluations/results/<config-name>-*.
  # Without these the CreateOnlineEvaluationConfig call fails with
  # "execution role does not have permissions to create log group".
  statement {
    sid    = "WriteEvalResults"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:PutRetentionPolicy",
      "logs:DescribeLogGroups",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/evaluations/*",
    ]
  }
}

resource "aws_iam_role_policy" "agentcore_eval_execution" {
  name   = "agentcore-eval-exec-inline"
  role   = aws_iam_role.agentcore_eval_execution.id
  policy = data.aws_iam_policy_document.agentcore_eval_execution.json
}

################################################################################
# 4. Enable CloudWatch Transaction Search (account-level, one-time)
#
# AgentCore Observability + Evaluations require Transaction Search: spans sent
# to the X-Ray OTLP endpoint are ingested as structured logs into the
# `aws/spans` log group, which is what evaluations query. This is an
# ACCOUNT-WIDE setting, not scoped to one resource — enabling it affects all
# X-Ray trace-segment routing in the account/region.
#
# There is no native Terraform resource for UpdateTraceSegmentDestination, so
# it is applied imperatively via the AWS CLI. The resource policy that lets the
# X-Ray service write spans to CloudWatch Logs is a CloudWatch LOGS resource
# policy (applied via `aws logs put-resource-policy`), expressible natively as
# aws_cloudwatch_log_resource_policy — NOT an X-Ray resource policy.
################################################################################

resource "aws_cloudwatch_log_resource_policy" "transaction_search" {
  policy_name = "${replace(local.name, "-", "")}TransactionSearch"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "TransactionSearchXRayAccess"
        Effect    = "Allow"
        Principal = { Service = "xray.amazonaws.com" }
        Action    = "logs:PutLogEvents"
        Resource = [
          "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:aws/spans:*",
          "arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/application-signals/data:*",
        ]
        Condition = {
          ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:xray:${local.region}:${data.aws_caller_identity.current.account_id}:*" }
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}

# Route trace segments (and OTLP spans) to CloudWatch Logs so Transaction
# Search can index them. Account-level; safe to re-run (idempotent set).
resource "null_resource" "enable_transaction_search" {
  triggers = {
    region = local.region
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      # Idempotent: UpdateTraceSegmentDestination errors with
      # InvalidRequestException if the destination is ALREADY CloudWatchLogs
      # (e.g. a prior apply, or the account already had Transaction Search on).
      # Check current state first and skip the update when it's already set.
      CURRENT=$(aws xray get-trace-segment-destination --region ${local.region} \
        --query 'Destination' --output text 2>/dev/null || echo "UNKNOWN")
      echo "Current X-Ray trace segment destination: $CURRENT"
      if [ "$CURRENT" = "CloudWatchLogs" ]; then
        echo "Transaction Search already routes to CloudWatchLogs, nothing to do."
      else
        echo "Routing X-Ray trace segments to CloudWatch Logs (Transaction Search)..."
        aws xray update-trace-segment-destination \
          --destination CloudWatchLogs \
          --region ${local.region}
        echo "Transaction Search destination set to CloudWatchLogs."
      fi
    EOT
  }

  depends_on = [aws_cloudwatch_log_resource_policy.transaction_search]
}
