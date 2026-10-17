###############################################################################
# EKS control plane (API auth mode, public+private endpoint, public locked to bastion)
###############################################################################

data "aws_iam_policy_document" "eks_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_trust.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Created explicitly so `terraform destroy` removes it and so it has a short retention.
# The audit log answers "who changed this?" during the messy-lab exercises.
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 3
}

resource "aws_eks_cluster" "lab" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.admin_cidrs
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Avoid surprise extended-support charges on a lab cluster.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.eks,
    aws_route_table_association.private,
  ]
}

# Optional extra admins (e.g. the role you use in the AWS console).
resource "aws_eks_access_entry" "admins" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admins" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = each.value
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admins]
}
