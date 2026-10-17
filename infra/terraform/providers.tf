provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.cluster_name
      Environment = "disposable-lab"
      ManagedBy   = "terraform"
      Repo        = "eks-alb-istio-gateway-lab"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
