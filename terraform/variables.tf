# Region the whole stack lands in. The `./up cloud` script's boto3 calls honor
# AWS_REGION directly; Terraform doesn't read env vars for defaults, so to
# deploy somewhere other than us-east-2 set TF_VAR_region (and keep AWS_REGION
# matching it so `./up cloud` targets the same place).
variable "region" {
  description = "AWS region for the agent-container stack."
  type        = string
  default     = "us-east-2"
}

# Which subnet the task and EFS mount target live in. Left empty, a data source
# resolves the default VPC's default subnet and pins its AZ. Override via
# TF_VAR_subnet_id (which `./up` forwards from AGENT_SUBNET_ID) to place it in a
# specific public subnet — it must have a route to an internet gateway, since
# the task runs with assignPublicIp=ENABLED and no NAT.
variable "subnet_id" {
  description = "Public subnet for the task and EFS mount target. Empty = default VPC's default subnet."
  type        = string
  default     = ""
}

# Who may assume the operator role (see operator.tf). Left empty, the trust
# policy falls back to the account root ARN, which delegates the actual
# assume-role decision to identity-based policies on the caller side — a safe
# default that lets you pick the real principal (an IAM user, an Identity
# Center permission-set role) later without a Terraform change. Set this to one
# or more principal ARNs to lock the trust down to exactly them.
variable "operator_trusted_principals" {
  description = "Principal ARNs allowed to assume agent-container-operator. Empty = trust the account root."
  type        = list(string)
  default     = []
}

# Require MFA on the operator role's assume-role call. Off for now — MFA is
# part of a later account-hardening pass; flip it on once the trusted principal
# is a real MFA-carrying identity.
variable "operator_require_mfa" {
  description = "Add an aws:MultiFactorAuthPresent=true condition to the operator role's trust policy."
  type        = bool
  default     = false
}

# The ~/.aws/config profile `./up cloud` should select. Rendered into .up.toml
# for the script to read; Terraform itself doesn't consume it. Empty -> `./up
# cloud` falls back to an "agent-container" profile if one exists, else ambient
# credentials.
variable "aws_profile" {
  description = "AWS profile name for ./up cloud to select (rendered into .up.toml)."
  type        = string
  default     = ""
}

# Fargate task size. 1 vCPU / 4 GB is a valid Fargate combination and enough
# headroom for a coding agent plus a build or two.
variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = string
  default     = "1024"
}

variable "task_memory" {
  description = "Fargate task memory (MiB)."
  type        = string
  default     = "4096"
}
