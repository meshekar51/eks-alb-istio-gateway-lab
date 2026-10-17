terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state on the bastion by default (state lives in infra/terraform/terraform.tfstate).
  # If the bastion may be terminated before `make destroy`, copy backend.tf.example to
  # backend.tf and use an S3 backend instead - orphaned state = orphaned (billing) resources.
}
