variable "region" {
  description = "AWS region for every lab resource (EKS, VPC, ACM certificate, ALB)."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as a name prefix and as the ExternalDNS owner id."
  type        = string
  default     = "istio-gateway-lab"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version. Istio 1.31 supports 1.32-1.37."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR of the dedicated lab VPC."
  type        = string
  default     = "10.80.0.0/16"
}

variable "az_count" {
  description = "Number of AZs. ALBs need at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3 (an ALB needs subnets in at least two AZs)."
  }
}

variable "node_instance_types" {
  description = "Managed node group instance types."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_disk_gb" {
  type    = number
  default = 40
}

variable "domain" {
  description = "Lab sub-domain. Hostnames used: shop.<domain>, api.<domain>, canary.<domain>. Example: lab.example.com"
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.domain)) && var.domain != "lab.example.com"
    error_message = "Set domain to a real sub-domain you control (e.g. lab.yourdomain.com), not the placeholder."
  }
}

variable "hosted_zone" {
  description = "Existing PUBLIC Route 53 hosted zone that contains var.domain. Example: example.com (or lab.example.com if delegated)."
  type        = string
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint (the bastion's Elastic IP /32)."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "admin_cidrs must contain valid CIDRs and must not be 0.0.0.0/0."
  }
}

variable "admin_principal_arns" {
  description = "Extra IAM role/user ARNs that get cluster-admin (e.g. your console role so the EKS console shows workloads). The identity running terraform gets admin automatically."
  type        = list(string)
  default     = []
}
