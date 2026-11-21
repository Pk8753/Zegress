# =============================================================================
# OUTPUTS — consumed by deploy.sh after terraform apply
# =============================================================================

output "registry_public_ip" {
  description = "Public IP of the registry/bastion node (SSH target)"
  value       = aws_instance.registry.public_ip
}

output "registry_private_ip" {
  description = "Private IP of the registry node (used in registries.yaml on cluster nodes)"
  value       = aws_instance.registry.private_ip
}

output "registry_fqdn" {
  description = "Registry DNS name"
  value       = var.enable_route53 ? aws_route53_record.registry[0].fqdn : ""
}

output "registry_endpoint" {
  description = "Docker registry endpoint used by cluster nodes"
  value       = "${aws_instance.registry.private_ip}:5000"
}

output "server_private_ips" {
  description = "Private IPs of RKE2 server nodes"
  value       = aws_instance.server[*].private_ip
}

output "agent_private_ips" {
  description = "Private IPs of RKE2 agent nodes"
  value       = aws_instance.agent[*].private_ip
}

output "external_nlb_dns" {
  description = "External NLB DNS name"
  value       = aws_lb.external.dns_name
}

output "internal_nlb_dns" {
  description = "Internal NLB DNS name (RKE2 cluster join endpoint)"
  value       = aws_lb.internal.dns_name
}

output "rancher_url" {
  description = "Rancher UI URL"
  value       = var.enable_route53 ? "https://${aws_route53_record.rancher[0].fqdn}" : "https://${aws_lb.external.dns_name}"
}

output "rancher_hostname" {
  description = "Rancher hostname (for Helm install)"
  value       = var.enable_route53 ? var.rancher_hostname : aws_lb.external.dns_name
}

output "ssh_user" {
  description = "SSH username for the AMI"
  value       = var.aws_ssh_user
}

output "ssh_private_key_path" {
  description = "Path to generated SSH private key"
  value       = local_sensitive_file.ssh_private_key.filename
}

output "first_server_private_ip" {
  description = "Private IP of the first RKE2 server (kubeconfig fetch target)"
  value       = var.server_count > 0 ? aws_instance.server[0].private_ip : ""
}

output "prefix" {
  description = "Resource name prefix"
  value       = var.prefix
}
