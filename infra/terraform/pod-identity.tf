###############################################################################
# EKS Pod Identity: AWS Load Balancer Controller + ExternalDNS
# (No OIDC provider / IRSA needed. The association is matched on namespace + SA name,
#  and credentials are injected only into pods CREATED after the association exists.)
###############################################################################

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------- LBC v3.6.0
resource "aws_iam_policy" "lbc" {
  name        = "${var.cluster_name}-aws-load-balancer-controller"
  description = "Upstream AWS Load Balancer Controller v3.6.0 policy (docs/install/iam_policy.json)"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-v3.6.0.json")
}

resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = aws_eks_cluster.lab.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}

# ---------------------------------------------------------------- ExternalDNS
data "aws_iam_policy_document" "external_dns" {
  statement {
    sid    = "ManageLabZoneRecords"
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResources",
    ]
    resources = [data.aws_route53_zone.public.arn]
  }

  statement {
    sid       = "DiscoverZones"
    effect    = "Allow"
    actions   = ["route53:ListHostedZones"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "external_dns" {
  name   = "${var.cluster_name}-external-dns"
  policy = data.aws_iam_policy_document.external_dns.json
}

resource "aws_iam_role" "external_dns" {
  name               = "${var.cluster_name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns.arn
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = aws_eks_cluster.lab.name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}
