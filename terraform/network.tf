# =============================================================================
# VPC AND NETWORKING INFRASTRUCTURE
# Auto-created during deployment with consistent prefix for easy identification
# =============================================================================

# ---- VPC ----
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name   = "${var.prefix}-vpc"
    Prefix = var.prefix
  }
}

# ---- Internet Gateway (for public subnet to reach internet) ----
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name   = "${var.prefix}-igw"
    Prefix = var.prefix
  }
}

# ---- Public Subnet (for registry/bastion node) ----
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name   = "${var.prefix}-public-subnet"
    Prefix = var.prefix
  }
}

# ---- Private Subnet (for RKE2 cluster nodes) ----
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name   = "${var.prefix}-private-subnet"
    Prefix = var.prefix
  }
}

# ---- Route Table for Public Subnet ----
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block      = "0.0.0.0/0"
    gateway_id      = aws_internet_gateway.main.id
  }

  tags = {
    Name   = "${var.prefix}-public-rt"
    Prefix = var.prefix
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---- Availability Zones Data Source ----
data "aws_availability_zones" "available" {
  state = "available"
}

# ---- Route53 Zone (create if create_route53_zone = true, else use existing) ----
resource "aws_route53_zone" "main" {
  count = var.enable_route53 && var.create_route53_zone ? 1 : 0
  name  = var.aws_route53_zone

  tags = {
    Name   = "${var.prefix}-zone"
    Prefix = var.prefix
  }
}

# ---- Data source: lookup existing Route53 zone ----
data "aws_route53_zone" "existing" {
  count = var.enable_route53 && !var.create_route53_zone ? 1 : 0
  name  = var.aws_route53_zone
}

# ---- Output the created resource IDs ----
output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC ID (auto-created)"
}

output "public_subnet_id" {
  value       = aws_subnet.public.id
  description = "Public subnet ID (auto-created)"
}

output "private_subnet_id" {
  value       = aws_subnet.private.id
  description = "Private subnet ID (auto-created)"
}

output "route53_zone_id" {
  value       = var.enable_route53 ? (var.create_route53_zone ? aws_route53_zone.main[0].zone_id : data.aws_route53_zone.existing[0].zone_id) : null
  description = "Route53 zone ID (created or existing)"
}

output "route53_zone_name_servers" {
  value       = var.enable_route53 ? (var.create_route53_zone ? aws_route53_zone.main[0].name_servers : data.aws_route53_zone.existing[0].name_servers) : []
  description = "Route53 zone name servers"
}
