# The operator role: what `./up cloud` assumes for day-to-day runs (start, stop,
# --build, log tail) so everyday use no longer needs root/admin credentials.
#
# It is deliberately scoped to ONLY the runtime AWS calls `./up cloud` makes —
# it has NO infrastructure/Terraform permissions. `terraform apply` and every
# other change to this module keep running under separate admin credentials;
# this role can't create, modify, or delete any of the resources here.
#
# Every statement is locked to var.region with an aws:RequestedRegion condition,
# except iam:PassRole (a non-regional service). Resources are pinned to exact
# ARNs wherever the API supports resource-level scoping; "*" appears only on the
# Describe/List and registry-level calls that don't.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  operator_account   = data.aws_caller_identity.current.account_id
  operator_partition = data.aws_partition.current.partition

  # No resource attribute gives the task-def family glob or per-task ARNs, so
  # build them; everything else is referenced off its resource below.
  operator_task_arn_glob     = "arn:${local.operator_partition}:ecs:${var.region}:${local.operator_account}:task/agent-container/*"
  operator_task_def_arn_glob = "arn:${local.operator_partition}:ecs:${var.region}:${local.operator_account}:task-definition/agent-container:*"

  # Empty list -> trust the account root, which hands the real assume decision
  # to the caller's identity-based policies (see var.operator_trusted_principals).
  operator_principals = length(var.operator_trusted_principals) > 0 ? var.operator_trusted_principals : [
    "arn:${local.operator_partition}:iam::${local.operator_account}:root"
  ]
}

data "aws_iam_policy_document" "operator_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.operator_principals
    }

    dynamic "condition" {
      for_each = var.operator_require_mfa ? [1] : []
      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }
  }
}

resource "aws_iam_role" "operator" {
  name               = "agent-container-operator"
  description        = "Assumed by ./up cloud for runtime task control. No infrastructure permissions."
  assume_role_policy = data.aws_iam_policy_document.operator_assume.json

  tags = { Name = "agent-container-operator" }
}

data "aws_iam_policy_document" "operator" {
  # --- ECS: find, launch, stop, inspect the standalone task ---------------
  statement {
    sid       = "EcsListTasks"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.agent.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "EcsDescribeTasks"
    actions   = ["ecs:DescribeTasks"]
    resources = [local.operator_task_arn_glob]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "EcsRunTask"
    actions   = ["ecs:RunTask"]
    resources = [local.operator_task_def_arn_glob]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.agent.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "EcsStopTask"
    actions   = ["ecs:StopTask"]
    resources = [local.operator_task_arn_glob]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.agent.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # --- PassRole: RunTask hands these two roles to ECS (non-regional) ------
  statement {
    sid     = "PassTaskRoles"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.execution.arn,
      aws_iam_role.task.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # --- EC2: resolve the task ENI's public IP, reconcile the SSH rule -----
  statement {
    sid = "Ec2Describe"
    actions = [
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
    ]
    resources = ["*"] # Describe calls don't take resource scoping.

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid = "Ec2SshRule"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = [aws_security_group.ssh.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # --- SSM: read/update the authorized_keys parameter -------------------
  statement {
    sid = "SsmAuthorizedKeys"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
    ]
    resources = [aws_ssm_parameter.authorized_keys.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # --- CloudWatch Logs: `aws logs tail` the container for debugging -----
  statement {
    sid = "LogsRead"
    actions = [
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
      "logs:StartLiveTail",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.agent.arn}:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "LogsDescribeGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # --- ECR: `./up cloud --build` pushes the image ----------------------
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # Registry-level; no resource-level form exists.

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [aws_ecr_repository.agent.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
}

resource "aws_iam_role_policy" "operator" {
  name   = "runtime"
  role   = aws_iam_role.operator.id
  policy = data.aws_iam_policy_document.operator.json
}
