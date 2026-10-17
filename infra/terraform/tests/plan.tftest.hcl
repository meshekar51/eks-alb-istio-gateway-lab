# Offline plan tests with a mocked AWS provider - no credentials, no AWS calls.
#   terraform -chdir=infra/terraform init -backend=false && terraform -chdir=infra/terraform test
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az1", "use1-az2", "use1-az4"]
    }
  }
  mock_data "aws_route53_zone" {
    defaults = {
      zone_id = "Z0000000000000"
      arn     = "arn:aws:route53:::hostedzone/Z0000000000000"
    }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:111122223333:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [
        { domain_name = "lab.example.org", resource_record_name = "_x.lab.example.org.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." },
        { domain_name = "*.lab.example.org", resource_record_name = "_x.lab.example.org.", resource_record_type = "CNAME", resource_record_value = "_y.acm-validations.aws." },
      ]
    }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::111122223333:policy/mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
}

variables {
  domain      = "lab.example.org"
  hosted_zone = "example.org"
  admin_cidrs = ["203.0.113.10/32"]
}

run "golden_plan" {
  command = apply

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "expected 2 public + 2 private subnets"
  }
  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.80.0.0/24" && aws_subnet.public[1].cidr_block == "10.80.1.0/24"
    error_message = "public subnet CIDRs changed"
  }
  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.80.16.0/20" && aws_subnet.private[1].cidr_block == "10.80.32.0/20"
    error_message = "private subnet CIDRs changed"
  }
  assert {
    condition     = alltrue([for s in aws_subnet.public : s.tags["kubernetes.io/role/elb"] == "1"])
    error_message = "every public subnet needs kubernetes.io/role/elb=1 (ALB needs 2 AZs)"
  }
  assert {
    condition     = toset(aws_eks_cluster.lab.vpc_config[0].public_access_cidrs) == toset(["203.0.113.10/32"])
    error_message = "EKS public endpoint must be restricted to admin_cidrs"
  }
  assert {
    condition     = aws_eks_pod_identity_association.lbc.service_account == "aws-load-balancer-controller" && aws_eks_pod_identity_association.lbc.namespace == "kube-system"
    error_message = "LBC Pod Identity association must match the Helm service account"
  }
  assert {
    condition     = aws_eks_pod_identity_association.external_dns.service_account == "external-dns" && aws_eks_pod_identity_association.external_dns.namespace == "external-dns"
    error_message = "ExternalDNS Pod Identity association must match the Helm service account"
  }
  assert {
    condition     = length(aws_route53_record.acm_validation) == 2
    error_message = "one validation record per certificate name (apex + wildcard)"
  }
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required on nodes"
  }
}

run "rejects_placeholder_domain" {
  command = plan
  variables {
    domain = "lab.example.com"
  }
  expect_failures = [var.domain]
}

run "rejects_domain_outside_zone" {
  command = plan
  variables {
    domain = "lab.other.org"
  }
  expect_failures = [aws_acm_certificate.lab]
}

run "rejects_world_open_api" {
  command = plan
  variables {
    admin_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.admin_cidrs]
}
