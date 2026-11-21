# =============================================================================
# DNS — Route53 records
# =============================================================================

locals {
  child_zone_name = trimsuffix(var.aws_route53_zone, ".")
}

data "aws_route53_zone" "parent" {
  count = var.enable_route53 && var.enable_parent_zone_delegation ? 1 : 0
  name  = var.parent_route53_zone
}

# Optional permanent fix: delegate child zone from parent zone.
resource "aws_route53_record" "child_zone_ns_delegation" {
  count   = var.enable_route53 && var.enable_parent_zone_delegation ? 1 : 0
  zone_id = data.aws_route53_zone.parent[0].zone_id
  name    = local.child_zone_name
  type    = "NS"
  ttl     = 300
  records = var.create_route53_zone ? aws_route53_zone.main[0].name_servers : data.aws_route53_zone.existing[0].name_servers
}

# Rancher hostname → external NLB (CNAME)
resource "aws_route53_record" "rancher" {
  count   = var.enable_route53 ? 1 : 0
  zone_id = var.create_route53_zone ? aws_route53_zone.main[0].zone_id : data.aws_route53_zone.existing[0].zone_id
  name    = var.rancher_hostname
  type    = "CNAME"
  ttl     = "60"
  records = [aws_lb.external.dns_name]
}

# Internal cluster endpoint → internal NLB (CNAME)
resource "aws_route53_record" "rancher_internal" {
  count   = var.enable_route53 ? 1 : 0
  zone_id = var.create_route53_zone ? aws_route53_zone.main[0].zone_id : data.aws_route53_zone.existing[0].zone_id
  name    = "${var.prefix}-internal.${var.aws_route53_zone}"
  type    = "CNAME"
  ttl     = "60"
  records = [aws_lb.internal.dns_name]
}
