provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key != "" ? var.aws_access_key : null
  secret_key = var.aws_secret_key != "" ? var.aws_secret_key : null
}

# Random suffix keeps resource names unique across deployments
resource "random_id" "suffix" {
  byte_length = 4
}

# Random token for RKE2 cluster join — shared across all nodes via user-data
resource "random_password" "rke2_token" {
  length  = 64
  special = false
}

# Generate an RSA key pair — private key is written to disk by local_sensitive_file
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "main" {
  key_name   = "${var.prefix}-${random_id.suffix.hex}"
  public_key = tls_private_key.ssh.public_key_openssh

  tags = {
    Name   = "${var.prefix}-keypair"
    Prefix = var.prefix
  }
}

# Write the private key locally so deploy.sh can SSH to nodes
resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.root}/../ssh-key.pem"
  file_permission = "0600"
}
