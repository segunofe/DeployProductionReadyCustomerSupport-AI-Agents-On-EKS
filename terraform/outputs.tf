output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "agentcore_memory_id" {
  description = "ID of the Bedrock AgentCore memory used by the integrated-infrastructure track"
  value       = aws_bedrockagentcore_memory.workshop.id
}

output "agentcore_memory_arn" {
  description = "ARN of the Bedrock AgentCore memory used by the integrated-infrastructure track"
  value       = aws_bedrockagentcore_memory.workshop.arn
}

output "agent_pod_role_arn" {
  description = "IAM role assumed by agent pods via Pod Identity (agents namespace, 'agent' service account)"
  value       = aws_iam_role.agent_pod.arn
}

output "agentcore_browser_id" {
  description = "ID of the Bedrock AgentCore managed browser used by the integrated track"
  value       = aws_bedrockagentcore_browser.workshop.browser_id
}

output "agentcore_code_interpreter_id" {
  description = "ID of the Bedrock AgentCore managed code interpreter used by the integrated track"
  value       = aws_bedrockagentcore_code_interpreter.workshop.code_interpreter_id
}

output "ecr_repository_urls" {
  description = "Map of ECR repository name to repository URL for the self-managed track"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "litellm_ingress_hint" {
  description = "Command to print the LiteLLM admin UI URL once the ALB is provisioned"
  value       = "kubectl get ingress -n litellm litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "image_prebuild_project" {
  description = "CodeBuild project that pre-builds and pushes all module images to ECR (null when prebuild_images = false)"
  value       = var.prebuild_images ? aws_codebuild_project.images[0].name : null
}
