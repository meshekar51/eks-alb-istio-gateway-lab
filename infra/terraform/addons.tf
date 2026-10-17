###############################################################################
# EKS managed add-ons (versions = EKS default for the cluster version)
###############################################################################

# Before compute: nodes should come up with the managed CNI + Pod Identity agent.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# After compute: these need schedulable nodes to become ACTIVE.
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.lab]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.lab]
}
