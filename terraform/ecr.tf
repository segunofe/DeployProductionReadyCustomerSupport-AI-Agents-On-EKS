################################################################################
# ECR repositories
#
# Consolidates the "aws ecr create-repository" commands previously in:
#   - content/20-.../200-strands-agents      → customer-agent
#   - content/20-.../600-agent-tools-mcp     → mcp-server
#   - content/20-.../700-multi-agent-a2a     → order-agent, product-agent,
#                                              orchestrator-agent
#
# force_delete = true so destroy / cleanup succeed after participants push
# images.
################################################################################

locals {
  ecr_repositories = toset([
    "customer-agent",
    "mcp-server",
    "order-agent",
    "product-agent",
    "orchestrator-agent",
  ])
}

resource "aws_ecr_repository" "this" {
  for_each = local.ecr_repositories

  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = local.tags
}
