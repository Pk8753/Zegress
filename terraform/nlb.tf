# =============================================================================
# LOAD BALANCERS
# Based on the original corral code patterns with the following NLBs:
#   External NLB — internet-facing; ports 80, 443, 6443, 9345
#   Internal NLB — private; same ports; used for RKE2 cluster join
# =============================================================================

# ---- External NLB (internet-facing) ----
resource "aws_lb" "external" {
  name               = "${var.prefix}-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.public.id]

  tags = {
    Name   = "${var.prefix}-nlb"
    Prefix = var.prefix
  }
}

# ---- Internal NLB (private, for RKE2 cluster join) ----
resource "aws_lb" "internal" {
  name               = "${var.prefix}-internal-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = [aws_subnet.private.id]

  tags = {
    Name   = "${var.prefix}-internal-nlb"
    Prefix = var.prefix
  }
}

# =============================================================================
# TARGET GROUPS — External
# Health check on port 80 /ping, same pattern as the original code
# =============================================================================

resource "aws_lb_target_group" "ext_80" {
  name     = "${var.prefix}-tg-80"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  tags = { Name = "${var.prefix}-tg-80", Prefix = var.prefix }
}

resource "aws_lb_target_group" "ext_443" {
  name     = "${var.prefix}-tg-443"
  port     = 443
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  tags = { Name = "${var.prefix}-tg-443", Prefix = var.prefix }
}

resource "aws_lb_target_group" "ext_6443" {
  name     = "${var.prefix}-tg-6443"
  port     = 6443
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  tags = { Name = "${var.prefix}-tg-6443", Prefix = var.prefix }
}

resource "aws_lb_target_group" "ext_9345" {
  name     = "${var.prefix}-tg-9345"
  port     = 9345
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  tags = { Name = "${var.prefix}-tg-9345", Prefix = var.prefix }
}

# =============================================================================
# TARGET GROUPS — Internal
# =============================================================================

resource "aws_lb_target_group" "int_80" {
  name     = "${var.prefix}-int-tg-80"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  tags = { Name = "${var.prefix}-int-tg-80", Prefix = var.prefix }
}

resource "aws_lb_target_group" "int_443" {
  name     = "${var.prefix}-int-tg-443"
  port     = 443
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  tags = { Name = "${var.prefix}-int-tg-443", Prefix = var.prefix }
}

resource "aws_lb_target_group" "int_6443" {
  name     = "${var.prefix}-int-tg-6443"
  port     = 6443
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  tags = { Name = "${var.prefix}-int-tg-6443", Prefix = var.prefix }
}

resource "aws_lb_target_group" "int_9345" {
  name     = "${var.prefix}-int-tg-9345"
  port     = 9345
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  tags = { Name = "${var.prefix}-int-tg-9345", Prefix = var.prefix }
}

# =============================================================================
# LISTENERS — External NLB
# =============================================================================

resource "aws_lb_listener" "ext_80" {
  load_balancer_arn = aws_lb.external.arn
  port              = 80
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ext_80.arn
  }
}

resource "aws_lb_listener" "ext_443" {
  load_balancer_arn = aws_lb.external.arn
  port              = 443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ext_443.arn
  }
}

resource "aws_lb_listener" "ext_6443" {
  load_balancer_arn = aws_lb.external.arn
  port              = 6443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ext_6443.arn
  }
}

resource "aws_lb_listener" "ext_9345" {
  load_balancer_arn = aws_lb.external.arn
  port              = 9345
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ext_9345.arn
  }
}

# =============================================================================
# LISTENERS — Internal NLB
# =============================================================================

resource "aws_lb_listener" "int_80" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.int_80.arn
  }
}

resource "aws_lb_listener" "int_443" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.int_443.arn
  }
}

resource "aws_lb_listener" "int_6443" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 6443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.int_6443.arn
  }
}

resource "aws_lb_listener" "int_9345" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 9345
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.int_9345.arn
  }
}
