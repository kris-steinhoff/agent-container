# .up.toml — the one config file `./up cloud` reads. `terraform apply` renders
# it from the live resource attributes so the script never shells out to
# terraform (or even needs it installed). To change config, edit
# terraform/terraform.tfvars and re-run `terraform apply` — a fast no-op for the
# infrastructure itself. .up.toml is gitignored.
resource "local_file" "up_toml" {
  filename        = "${path.module}/../.up.toml"
  file_permission = "0644"

  content = templatefile("${path.module}/up.toml.tftpl", {
    region                 = var.region
    cluster_arn            = aws_ecs_cluster.agent.arn
    task_definition_family = aws_ecs_task_definition.agent.family
    subnet_id              = local.subnet_id
    task_security_group_id = aws_security_group.task.id
    ssh_security_group_id  = aws_security_group.ssh.id
    log_group_name         = aws_cloudwatch_log_group.agent.name
    ecr_repository_url     = aws_ecr_repository.agent.repository_url
    operator_role_arn      = aws_iam_role.operator.arn
    ssm_parameter_name     = aws_ssm_parameter.authorized_keys.name
    aws_profile            = var.aws_profile
  })
}
