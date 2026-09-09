# agent-container on AWS Fargate: a single standalone task (not an ECS Service)
# that `./up cloud` launches on demand and that stops itself when idle, so it
# costs nothing while nobody's using it. Persistent state (the whole
# /home/agent) lives on EFS; the task's auto-assigned public IP changes each
# start, so `./up cloud` resolves it and writes an SSH config fragment (the
# persisted EFS host keys keep the host key stable); the task's port-22 ingress
# is owned by `./up cloud`, not Terraform.

provider "aws" {
  # Pinned to var.region (default us-east-2). See variables.tf on deploying
  # elsewhere. Credentials come from the ambient AWS config/env/SSO.
  region = var.region
}

# ---------------------------------------------------------------------------
# Networking: pick a public subnet and pin its AZ. Either an explicit
# var.subnet_id, or the default VPC's default subnet when that's empty.
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  count   = var.subnet_id == "" ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.subnet_id == "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  # try() swallows the index-out-of-range that the count=0 branch would
  # otherwise raise when var.subnet_id is set.
  default_subnet_id = try(tolist(data.aws_subnets.default[0].ids)[0], "")
  subnet_id         = var.subnet_id != "" ? var.subnet_id : local.default_subnet_id
}

# The subnet we actually use — resolved so we get its vpc_id and AZ regardless
# of which branch above produced the id.
data "aws_subnet" "selected" {
  id = local.subnet_id
}

# ---------------------------------------------------------------------------
# Security groups. Two SGs are attached to the task: the task SG carries
# egress, the ssh SG carries the single port-22 ingress that `./up cloud`
# rewrites to your current IP on every start. Splitting them keeps Terraform
# out of the business of tracking a rule that changes with your network.
# ---------------------------------------------------------------------------
resource "aws_security_group" "task" {
  name        = "agent-container-task"
  description = "agent-container Fargate task: egress only, no ingress."
  vpc_id      = data.aws_subnet.selected.vpc_id

  egress {
    description = "All outbound."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "agent-container-task" }
}

resource "aws_security_group" "ssh" {
  name        = "agent-container-ssh"
  description = "agent-container SSH ingress; the tcp/22 rule is managed by ./up cloud."
  vpc_id      = data.aws_subnet.selected.vpc_id

  # Deliberately no ingress/egress here. `./up cloud` owns the one tcp/22
  # ingress rule (revoking and re-authorizing it for your current /32 on each
  # start); egress comes from the task SG. ignore_changes keeps a later
  # `terraform apply` from revoking whatever rule `./up cloud` last set.
  lifecycle {
    ignore_changes = [ingress]
  }

  tags = { Name = "agent-container-ssh" }
}

resource "aws_security_group" "efs" {
  name        = "agent-container-efs"
  description = "agent-container EFS: NFS 2049 from the task SG only."
  vpc_id      = data.aws_subnet.selected.vpc_id

  ingress {
    description     = "NFS from the task."
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.task.id]
  }

  tags = { Name = "agent-container-efs" }
}

# ---------------------------------------------------------------------------
# Image registry. `./up cloud --build` builds arm64 and pushes :latest here.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "agent" {
  name                 = "agent-container"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ---------------------------------------------------------------------------
# Persistence. One EFS filesystem, mounted at /home/agent via an access point
# that squashes everything to the agent user (uid/gid 1001). This replaces the
# agent_home Docker volume for the cloud path — dotfiles, herdr, auth tokens,
# project checkouts, and the persisted sshd host keys all survive task exits.
# ---------------------------------------------------------------------------
resource "aws_efs_file_system" "home" {
  creation_token = "agent-container-home"
  encrypted      = true

  tags = { Name = "agent-container-home" }
}

resource "aws_efs_access_point" "home" {
  file_system_id = aws_efs_file_system.home.id

  posix_user {
    uid = 1001
    gid = 1001
  }

  root_directory {
    path = "/agent-home"
    creation_info {
      owner_uid   = 1001
      owner_gid   = 1001
      permissions = "0755"
    }
  }

  tags = { Name = "agent-container-home" }
}

resource "aws_efs_mount_target" "home" {
  file_system_id  = aws_efs_file_system.home.id
  subnet_id       = local.subnet_id
  security_groups = [aws_security_group.efs.id]
}

# ---------------------------------------------------------------------------
# ECS cluster + logs.
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "agent" {
  name = "agent-container"
}

resource "aws_cloudwatch_log_group" "agent" {
  name              = "/ecs/agent-container"
  retention_in_days = 14
}

# ---------------------------------------------------------------------------
# The authorized_keys secret. Terraform creates the parameter with a
# placeholder and ignores its value forever after — put your real public key in
# it out-of-band once (see README / the ssm put-parameter one-liner in setup),
# so the key never lands in Terraform state or the repo. Injected into the
# container as $AUTHORIZED_KEYS via the task definition's `secrets`.
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "authorized_keys" {
  name        = "/agent-container/authorized_keys"
  description = "SSH public key(s) authorized to log in as agent. Set the real value out-of-band."
  type        = "String"
  value       = "ssh-ed25519 REPLACE_ME put-your-real-public-key-here"

  lifecycle {
    ignore_changes = [value]
  }

  tags = { Name = "agent-container" }
}

# ---------------------------------------------------------------------------
# IAM. Execution role pulls the image and the SSM secret; task role is empty.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "agent-container-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The managed policy above doesn't cover reading a specific SSM parameter for
# the `secrets` injection — grant just this one. (The parameter is a plain
# String, so no kms:Decrypt is needed; if you switch it to SecureString with a
# customer-managed key, add a kms:Decrypt statement for that key here.)
data "aws_iam_policy_document" "execution_ssm" {
  statement {
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.authorized_keys.arn]
  }
}

resource "aws_iam_role_policy" "execution_ssm" {
  name   = "read-authorized-keys"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_ssm.json
}

resource "aws_iam_role" "task" {
  name               = "agent-container-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  # Intentionally empty: no policies attached. Whatever AWS/GitHub/etc. access
  # the agent needs comes from credentials you set up inside the container, not
  # from the task role. EFS mount uses IAM auth but the filesystem has no
  # restricting policy, so no elasticfilesystem:* permission is required here.
}

# ---------------------------------------------------------------------------
# Task definition. One arm64 container, port 22, EFS at /home/agent, idle
# monitor and persisted host keys turned on via env, authorized_keys via SSM.
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "agent" {
  family                   = "agent-container"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  volume {
    name = "home"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.home.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.home.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "agent"
      image     = "${aws_ecr_repository.agent.repository_url}:latest"
      essential = true

      portMappings = [
        { containerPort = 22, protocol = "tcp" }
      ]

      # initProcessEnabled gives the container a real init (reaps zombies) and
      # is also what ECS Exec needs if you ever want to `aws ecs execute-command`
      # into the task for debugging.
      linuxParameters = {
        initProcessEnabled = true
      }

      mountPoints = [
        { sourceVolume = "home", containerPath = "/home/agent" }
      ]

      environment = [
        # entrypoint.sh switches to the cloud path on these: run the idle
        # monitor as PID 1's foreground process, and persist sshd host keys on
        # EFS so known_hosts stays stable across task restarts.
        { name = "IDLE_MONITOR", value = "1" },
        { name = "SSHD_HOST_KEY_DIR", value = "/home/agent/.ssh/host_keys" }
      ]

      secrets = [
        { name = "AUTHORIZED_KEYS", valueFrom = aws_ssm_parameter.authorized_keys.arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.agent.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "agent"
        }
      }
    }
  ])
}

# The SSH target is the task's own auto-assigned public IP (assignPublicIp =
# ENABLED above). It changes on every start, so there's no stable-address
# resource here: `./up cloud` resolves the current IP and writes it into a
# generated SSH config fragment. The persisted EFS host keys keep the
# `agent-container` host alias's key stable across restarts. (An Elastic IP
# won't work — Fargate task ENIs are service-managed and reject
# AssociateAddress with AuthFailure, even as account root.)
