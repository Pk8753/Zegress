# =============================================================================
# SECURITY GROUPS
# =============================================================================

# ---- Registry / Bastion Node ----
# Has a public IP. Accepts SSH from admin, exposes registry + artifact server
# to VPC, and has unrestricted outbound (for pulling images from Docker Hub).
resource "aws_security_group" "registry" {
  name        = "${var.prefix}-registry-sg"
  description = "Rancher air-gap registry and bastion node"
  vpc_id      = aws_vpc.main.id

  # SSH from anywhere (restrict to your IP range in production)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Docker registry on port 5000 — cluster nodes pull images here
  ingress {
    description = "Docker registry (internal)"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # Artifact HTTP server on port 8080 — cluster nodes download RKE2 binaries here
  ingress {
    description = "Artifact HTTP server (internal)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # Allow all outbound — registry needs internet to pull images, download binaries
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name   = "${var.prefix}-registry-sg"
    Prefix = var.prefix
  }
}

# ---- RKE2 Cluster Nodes (servers + agents) ----
# No public IPs. Accessed only via registry bastion.
resource "aws_security_group" "cluster" {
  name        = "${var.prefix}-cluster-sg"
  description = "Rancher air-gap RKE2 cluster nodes"
  vpc_id      = aws_vpc.main.id

  # SSH from registry/bastion only
  ingress {
    description     = "SSH via bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.registry.id]
  }

  # All traffic within the cluster SG (node-to-node)
  ingress {
    description = "Intra-cluster traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Rancher UI — HTTP (will redirect to HTTPS)
  ingress {
    description = "HTTP (Rancher UI redirect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Rancher UI — HTTPS
  ingress {
    description = "HTTPS (Rancher UI)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API server — from VPC only (kubectl access)
  ingress {
    description = "Kubernetes API (internal)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # RKE2 supervisor API — nodes join via internal NLB on this port
  ingress {
    description = "RKE2 supervisor API (internal)"
    from_port   = 9345
    to_port     = 9345
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # All outbound — nodes pull images from private registry, talk to each other
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name   = "${var.prefix}-cluster-sg"
    Prefix = var.prefix
  }
}
