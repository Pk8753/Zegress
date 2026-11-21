provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

resource "random_id" "suffix" {
  byte_length = 3
}

resource "aws_key_pair" "downstream" {
  key_name   = "${var.downstream_cluster_name}-key-${random_id.suffix.hex}"
  public_key = var.ssh_public_key
}

resource "aws_security_group" "downstream" {
  name        = "${var.downstream_cluster_name}-sg-${random_id.suffix.hex}"
  description = "Downstream RKE2 nodes with internal node-to-node communication"
  vpc_id      = var.aws_vpc_id

  ingress {
    description     = "SSH from registry/bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.registry_security_group_id]
  }

  ingress {
    description = "All node-to-node traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.downstream_cluster_name}-sg"
  }
}

resource "aws_instance" "downstream_server" {
  count                       = var.downstream_server_count
  ami                         = var.aws_ami
  instance_type               = var.downstream_instance_type
  subnet_id                   = var.aws_subnet_id
  key_name                    = aws_key_pair.downstream.key_name
  vpc_security_group_ids      = [aws_security_group.downstream.id]
  associate_public_ip_address = false

  root_block_device {
    volume_size = var.downstream_root_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name  = "${var.downstream_cluster_name}-server-${count.index}"
    Role  = "downstream-server"
    Group = var.downstream_cluster_name
  }
}

resource "aws_instance" "downstream_agent" {
  count                       = var.downstream_agent_count
  ami                         = var.aws_ami
  instance_type               = var.downstream_instance_type
  subnet_id                   = var.aws_subnet_id
  key_name                    = aws_key_pair.downstream.key_name
  vpc_security_group_ids      = [aws_security_group.downstream.id]
  associate_public_ip_address = false

  root_block_device {
    volume_size = var.downstream_root_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name  = "${var.downstream_cluster_name}-agent-${count.index}"
    Role  = "downstream-agent"
    Group = var.downstream_cluster_name
  }
}
