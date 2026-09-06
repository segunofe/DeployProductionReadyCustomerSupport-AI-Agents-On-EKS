################################################################################
# Bedrock AgentCore Browser + Code Interpreter (Integrated Infrastructure track)
#
# Both use PUBLIC network mode — the simplest option for a workshop. VPC mode
# is available if customers need egress pinned to their network, but the added
# subnet/SG wiring doesn't pay for itself in a learning context.
#
# PUBLIC mode does not require an execution role, so neither resource references
# one. Agent pods get access to these tools via the pod IAM role defined in
# agentcore.tf (extended with an inline policy below).
################################################################################

resource "aws_bedrockagentcore_browser" "workshop" {
  name        = replace("${local.name}_browser", "-", "_")
  description = "Managed headless browser for integrated-track agents"

  network_configuration {
    network_mode = "PUBLIC"
  }

  tags = local.tags
}

resource "aws_bedrockagentcore_code_interpreter" "workshop" {
  name        = replace("${local.name}_code_interp", "-", "_")
  description = "Managed code interpreter sandbox for integrated-track agents"

  network_configuration {
    network_mode = "PUBLIC"
  }

  tags = local.tags
}

################################################################################
# IAM — extend the agent pod role with session control for browser + code
# interpreter. Scoped to the two resource ARNs above; list/describe actions
# that don't support resource-level permissions are granted separately with "*".
################################################################################

data "aws_iam_policy_document" "agent_pod_tools" {
  statement {
    sid    = "AgentCoreBrowserSessions"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:StartBrowserSession",
      "bedrock-agentcore:StopBrowserSession",
      "bedrock-agentcore:GetBrowserSession",
      "bedrock-agentcore:UpdateBrowserStream",
      "bedrock-agentcore:ConnectBrowserAutomationStream",
    ]
    resources = [aws_bedrockagentcore_browser.workshop.browser_arn]
  }

  statement {
    sid    = "AgentCoreCodeInterpreterSessions"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:StartCodeInterpreterSession",
      "bedrock-agentcore:StopCodeInterpreterSession",
      "bedrock-agentcore:GetCodeInterpreterSession",
      "bedrock-agentcore:InvokeCodeInterpreter",
    ]
    resources = [aws_bedrockagentcore_code_interpreter.workshop.code_interpreter_arn]
  }

  statement {
    sid    = "AgentCoreToolListing"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:ListBrowserSessions",
      "bedrock-agentcore:ListCodeInterpreterSessions",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "agent_pod_tools" {
  name   = "agent-pod-agentcore-tools"
  role   = aws_iam_role.agent_pod.id
  policy = data.aws_iam_policy_document.agent_pod_tools.json
}

################################################################################
# Surface tool IDs to agent pods via a dedicated ConfigMap in the `agents`
# namespace. Kept separate from the memory ConfigMap so the tools module can
# be discussed (and toggled) independently in the content walkthrough.
################################################################################

resource "kubernetes_config_map_v1" "agent_tools" {
  metadata {
    name      = "agent-tools"
    namespace = kubernetes_namespace_v1.agents.metadata[0].name
  }

  data = {
    AGENTCORE_BROWSER_ID          = aws_bedrockagentcore_browser.workshop.browser_id
    AGENTCORE_BROWSER_ARN         = aws_bedrockagentcore_browser.workshop.browser_arn
    AGENTCORE_CODE_INTERPRETER_ID = aws_bedrockagentcore_code_interpreter.workshop.code_interpreter_id
    AGENTCORE_CODE_INTERPRETER_ARN = aws_bedrockagentcore_code_interpreter.workshop.code_interpreter_arn
  }
}
