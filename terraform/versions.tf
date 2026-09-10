# Provider/version pins. The AWS provider reads AWS credentials the usual way
# (env, shared config, SSO) — nothing region-specific is hardcoded here; see
# provider "aws" in main.tf, which honors var.region (default us-east-2).
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    # Renders .up.toml on the local filesystem (see config.tf).
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
  }
}
