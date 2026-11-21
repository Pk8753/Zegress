variable "downstream_cluster_name" {
  description = "Logical name for downstream EC2 nodes"
  type        = string
}

variable "aws_access_key" {
  description = "AWS access key"
  type        = string
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS secret key"
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region for Rancher node driver"
  type        = string
}

variable "aws_ami" {
  description = "AMI for downstream nodes"
  type        = string
}

variable "aws_vpc_id" {
  description = "VPC ID for downstream nodes"
  type        = string
}

variable "aws_subnet_id" {
  description = "Subnet ID for downstream nodes"
  type        = string
}

variable "registry_security_group_id" {
  description = "Security group ID of registry/bastion node (to allow SSH to downstream nodes from registry)"
  type        = string
}

variable "aws_ssh_user" {
  description = "SSH user for downstream nodes"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key" {
  description = "Public SSH key to inject into downstream nodes"
  type        = string
}

variable "downstream_server_count" {
  description = "Number of downstream server nodes"
  type        = number
  default     = 1
}

variable "downstream_agent_count" {
  description = "Number of downstream agent nodes"
  type        = number
  default     = 1
}

variable "downstream_instance_type" {
  description = "Instance type for downstream nodes"
  type        = string
}

variable "downstream_root_size_gb" {
  description = "Root disk size in GB for downstream nodes"
  type        = number
  default     = 50
}

variable "registry_private_ip" {
  description = "Private IP of management registry node"
  type        = string
}

variable "rancher_server_url" {
  description = "Rancher server URL used for system-agent install command"
  type        = string
}
