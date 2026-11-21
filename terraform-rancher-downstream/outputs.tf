output "downstream_cluster_name" {
  value = var.downstream_cluster_name
}

output "downstream_security_group_id" {
  value = aws_security_group.downstream.id
}

output "downstream_server_private_ips" {
  value = aws_instance.downstream_server[*].private_ip
}

output "downstream_agent_private_ips" {
  value = aws_instance.downstream_agent[*].private_ip
}

output "downstream_first_server_private_ip" {
  value = var.downstream_server_count > 0 ? aws_instance.downstream_server[0].private_ip : ""
}

output "rancher_server_url" {
  value = var.rancher_server_url
}

output "registry_private_ip" {
  value = var.registry_private_ip
}
