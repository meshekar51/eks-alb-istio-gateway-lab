output "region" {
  value = var.region
}

output "cluster_name" {
  value = aws_eks_cluster.lab.name
}

output "cluster_version" {
  value = aws_eks_cluster.lab.version
}

output "vpc_id" {
  value = aws_vpc.lab.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "availability_zones" {
  value = local.azs
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster SG (attached to nodes). The LBC adds ALB->pod rules here."
  value       = aws_eks_cluster.lab.vpc_config[0].cluster_security_group_id
}

output "domain" {
  value = var.domain
}

output "hosted_zone" {
  value = var.hosted_zone
}

output "hosted_zone_id" {
  value = data.aws_route53_zone.public.zone_id
}

output "acm_certificate_arn" {
  description = "ISSUED wildcard certificate (only known after DNS validation succeeds)."
  value       = aws_acm_certificate_validation.lab.certificate_arn
}

output "lbc_role_arn" {
  value = aws_iam_role.lbc.arn
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.lab.name} --alias ${aws_eks_cluster.lab.name}"
}
