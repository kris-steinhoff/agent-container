# `./up cloud` reads these (via `terraform -chdir=terraform output -json`) to
# find the cluster, task def, SGs, subnet, and log group. Each is also
# overridable by an AGENT_* env var in the script, so you can run `./up cloud`
# without Terraform on PATH once you know the values.
output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.agent.arn
}

output "task_definition_family" {
  description = "Task definition family (run_task resolves the latest revision)."
  value       = aws_ecs_task_definition.agent.family
}

output "ecr_repository_url" {
  description = "ECR repository URL for the image (push target for --build)."
  value       = aws_ecr_repository.agent.repository_url
}

output "task_security_group_id" {
  description = "Task SG (egress) id, attached to the task."
  value       = aws_security_group.task.id
}

output "ssh_security_group_id" {
  description = "SSH SG id; ./up cloud owns its tcp/22 ingress rule."
  value       = aws_security_group.ssh.id
}

output "subnet_id" {
  description = "The public subnet the task and EFS mount target use."
  value       = local.subnet_id
}

output "log_group_name" {
  description = "CloudWatch log group for the container."
  value       = aws_cloudwatch_log_group.agent.name
}

output "efs_id" {
  description = "EFS filesystem id backing /home/agent."
  value       = aws_efs_file_system.home.id
}

output "ssm_parameter_name" {
  description = "SSM parameter holding authorized_keys — put your public key here."
  value       = aws_ssm_parameter.authorized_keys.name
}
