###############################################################################
# Route 53 public zone (must already exist) + ACM wildcard certificate
# ACM certs used by an ALB must live in the SAME REGION as the ALB.
###############################################################################

data "aws_route53_zone" "public" {
  name         = var.hosted_zone
  private_zone = false
}

resource "aws_acm_certificate" "lab" {
  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"
  key_algorithm             = "RSA_2048"

  tags = { Name = "${var.cluster_name}-wildcard" }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.domain == var.hosted_zone || endswith(var.domain, ".${var.hosted_zone}")
      error_message = "domain (${var.domain}) must be inside hosted_zone (${var.hosted_zone})."
    }
  }
}

# Apex and wildcard produce the SAME validation CNAME; allow_overwrite makes that safe.
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.lab.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.public.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "lab" {
  certificate_arn         = aws_acm_certificate.lab.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]

  timeouts {
    create = "30m"
  }
}
