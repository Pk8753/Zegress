# =============================================================================
# REGISTRY / BASTION NODE
# Public EC2 instance that:
#   1. Runs a private Docker registry (port 5000) for container images
#   2. Serves RKE2 binaries via nginx (port 8080) to air-gapped cluster nodes
#   3. Acts as SSH bastion for cluster nodes (no public IPs)
#   4. Has internet access to pull images from Docker Hub
# =============================================================================

resource "aws_instance" "registry" {
  ami                         = var.aws_ami
  instance_type               = var.registry_instance_type
  key_name                    = aws_key_pair.main.key_name
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.registry.id]
  associate_public_ip_address = true

  ebs_block_device {
    device_name           = "/dev/sda1"
    volume_size           = var.registry_volume_size_gb
    volume_type           = "gp3"
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/registry-userdata.sh.tpl", {
    registry_username    = var.registry_username
    registry_password    = var.registry_password
    rke2_version         = var.rke2_version
    helm_version         = var.helm_version
    cert_manager_version = var.cert_manager_version
    rancher_version      = var.rancher_version
    ssh_public_key       = tls_private_key.ssh.public_key_openssh
    ssh_user             = var.aws_ssh_user
  })

  tags = {
    Name   = "${var.prefix}-registry"
    Role   = "registry"
    Prefix = var.prefix
  }
}

# Route53 A record → registry public IP (for SSH access from admin machine)
resource "aws_route53_record" "registry" {
  count   = var.enable_route53 ? 1 : 0
  zone_id = var.create_route53_zone ? aws_route53_zone.main[0].zone_id : data.aws_route53_zone.existing[0].zone_id
  name    = "${var.prefix}-registry.${var.aws_route53_zone}"
  type    = "A"
  ttl     = "60"
  records = [aws_instance.registry.public_ip]
}
