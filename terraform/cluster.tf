# =============================================================================
# RKE2 CLUSTER NODES — Server and Agent EC2 instances
# All nodes are in the private subnet (no public IP).
# Bootstrap is fully automated via user-data.
# =============================================================================

locals {
  # The first server initialises the cluster; additional servers and all agents
  # join via the internal NLB.
  internal_nlb_join_endpoint = aws_lb.internal.dns_name
}

# ---- Server / Control-Plane nodes ----
resource "aws_instance" "server" {
  count = var.server_count

  ami                         = var.aws_ami
  instance_type               = var.server_instance_type
  key_name                    = aws_key_pair.main.key_name
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  associate_public_ip_address = false

  ebs_block_device {
    device_name           = "/dev/sda1"
    volume_size           = var.server_volume_size_gb
    volume_type           = "gp3"
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/rke2-server-userdata.sh.tpl", {
    is_first_server      = count.index == 0
    registry_ip          = aws_instance.registry.private_ip
    registry_username    = var.registry_username
    registry_password    = var.registry_password
    rke2_token           = random_password.rke2_token.result
    rke2_version         = var.rke2_version
    internal_nlb_dns     = local.internal_nlb_join_endpoint
    rancher_hostname     = var.rancher_hostname
    ssh_public_key       = tls_private_key.ssh.public_key_openssh
    ssh_user             = var.aws_ssh_user
  })

  tags = {
    Name   = "${var.prefix}-server-${count.index}"
    Role   = "server"
    Prefix = var.prefix
    Index  = count.index
  }

  # Ensures registry is created before cluster nodes — they depend on registry IP
  depends_on = [aws_instance.registry]
}

# ---- Agent / Worker nodes ----
resource "aws_instance" "agent" {
  count = var.agent_count

  ami                         = var.aws_ami
  instance_type               = var.agent_instance_type
  key_name                    = aws_key_pair.main.key_name
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  associate_public_ip_address = false

  ebs_block_device {
    device_name           = "/dev/sda1"
    volume_size           = var.agent_volume_size_gb
    volume_type           = "gp3"
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/rke2-agent-userdata.sh.tpl", {
    registry_ip       = aws_instance.registry.private_ip
    registry_username = var.registry_username
    registry_password = var.registry_password
    rke2_token        = random_password.rke2_token.result
    rke2_version      = var.rke2_version
    internal_nlb_dns  = local.internal_nlb_join_endpoint
    ssh_public_key    = tls_private_key.ssh.public_key_openssh
    ssh_user          = var.aws_ssh_user
  })

  tags = {
    Name   = "${var.prefix}-agent-${count.index}"
    Role   = "agent"
    Prefix = var.prefix
    Index  = count.index
  }

  depends_on = [aws_instance.registry]
}

# =============================================================================
# NLB TARGET GROUP ATTACHMENTS — mirrors the pattern from the old corral code
# =============================================================================

# ---- External NLB: attach servers on 80/443/6443/9345 ----
resource "aws_lb_target_group_attachment" "ext_80_server" {
  count            = var.server_count
  target_group_arn = aws_lb_target_group.ext_80.arn
  target_id        = aws_instance.server[count.index].id
  port             = 80
}

resource "aws_lb_target_group_attachment" "ext_443_server" {
  count            = var.server_count
  target_group_arn = aws_lb_target_group.ext_443.arn
  target_id        = aws_instance.server[count.index].id
  port             = 443
}

resource "aws_lb_target_group_attachment" "ext_6443_server" {
  count            = var.server_count
  target_group_arn = aws_lb_target_group.ext_6443.arn
  target_id        = aws_instance.server[count.index].id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "ext_9345_server" {
  count            = var.server_count
  target_group_arn = aws_lb_target_group.ext_9345.arn
  target_id        = aws_instance.server[count.index].id
  port             = 9345
}

# ---- External NLB: attach agents on 80/443 (ingress traffic) ----
resource "aws_lb_target_group_attachment" "ext_80_agent" {
  count            = var.agent_count
  target_group_arn = aws_lb_target_group.ext_80.arn
  target_id        = aws_instance.agent[count.index].id
  port             = 80
}

resource "aws_lb_target_group_attachment" "ext_443_agent" {
  count            = var.agent_count
  target_group_arn = aws_lb_target_group.ext_443.arn
  target_id        = aws_instance.agent[count.index].id
  port             = 443
}

resource "aws_lb_target_group_attachment" "ext_6443_agent" {
  count            = var.agent_count
  target_group_arn = aws_lb_target_group.ext_6443.arn
  target_id        = aws_instance.agent[count.index].id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "ext_9345_agent" {
  count            = var.agent_count
  target_group_arn = aws_lb_target_group.ext_9345.arn
  target_id        = aws_instance.agent[count.index].id
  port             = 9345
}

# ---- Internal NLB: servers only (cluster join endpoint) ----
resource "aws_lb_target_group_attachment" "int_80_server" {
  count            = var.server_count
  target_group_arn = aws_lb_target_group.int_80.arn
  target_id        = aws_instance.server[count.index].id
  port             = 80
}

resource "aws_lb_target_group_attachment" "int_443_server" {
  count            = var.server_count
  target_group_arn = aws_lb_target_group.int_443.arn
  target_id        = aws_instance.server[count.index].id
  port             = 443
}

resource "aws_lb_target_group_attachment" "int_6443_server" {
  count            = var.server_count
  target_group_arn = aws_lb_target_group.int_6443.arn
  target_id        = aws_instance.server[count.index].id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "int_9345_server" {
  count            = var.server_count
  target_group_arn = aws_lb_target_group.int_9345.arn
  target_id        = aws_instance.server[count.index].id
  port             = 9345
}

# ---- Internal NLB: agents ----
resource "aws_lb_target_group_attachment" "int_80_agent" {
  count            = var.agent_count
  target_group_arn = aws_lb_target_group.int_80.arn
  target_id        = aws_instance.agent[count.index].id
  port             = 80
}

resource "aws_lb_target_group_attachment" "int_443_agent" {
  count            = var.agent_count
  target_group_arn = aws_lb_target_group.int_443.arn
  target_id        = aws_instance.agent[count.index].id
  port             = 443
}
