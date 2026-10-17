###############################################################################
# Dedicated lab VPC: 2 public subnets (ALB + NAT) and 2 private subnets (nodes)
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"

  # use1-az3 cannot host EKS control-plane ENIs (UnsupportedAvailabilityZoneException).
  # AZ *names* are shuffled per account, so we exclude by AZ *ID*.
  exclude_zone_ids = ["use1-az3"]

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # 10.80.0.0/24, 10.80.1.0/24, ...   (ALB + NAT; small on purpose)
  public_subnet_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  # 10.80.16.0/20, 10.80.32.0/20, ... (nodes + pods; VPC CNI gives every pod a VPC IP)
  private_subnet_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 1)]

  cluster_tag = "kubernetes.io/cluster/${var.cluster_name}"
}

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.lab.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-public-${local.azs[count.index]}"
    # AWS Load Balancer Controller subnet auto-discovery for internet-facing ALBs.
    # If ANY subnet carries this role tag, ONLY role-tagged subnets are candidates.
    "kubernetes.io/role/elb" = "1"
    (local.cluster_tag)      = "shared"
    "lab.tier"               = "public"
  }
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.lab.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.private_subnet_cidrs[count.index]

  tags = {
    Name                              = "${var.cluster_name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
    (local.cluster_tag)               = "shared"
    "lab.tier"                        = "private"
  }
}

# Single NAT gateway to keep the lab cheap (not AZ-resilient - fine for a lab).
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nat" }

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.cluster_name}-nat" }

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.cluster_name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${var.cluster_name}-private" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.lab.id
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
