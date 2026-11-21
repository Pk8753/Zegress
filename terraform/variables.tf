# =============================================================================
# VARIABLES — all inputs come from config.tfvars at the root level
# =============================================================================

# ---- AWS Region ----
variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "aws_access_key" {
  description = "AWS access key ID (optional; can also be provided via environment variables)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS secret access key (optional; can also be provided via environment variables)"
  type        = string
  default     = ""
  sensitive   = true
}

# ---- Networking ----
variable "enable_route53" {
  description = "Enable Route53 resources and DNS records. Set false to use only NLB DNS endpoints."
  type        = bool
  default     = true
}

variable "aws_route53_zone" {
  description = "Route53 hosted zone name (e.g. mycompany.com) when enable_route53=true"
  type        = string
  default     = ""
}

variable "create_route53_zone" {
  description = "Whether to create a new Route53 hosted zone (true) or use existing (false)"
  type        = bool
  default     = true
}

variable "enable_parent_zone_delegation" {
  description = "Create NS delegation in a parent Route53 zone (e.g. delegate qa-test.rancher.space from rancher.space)"
  type        = bool
  default     = false
}

variable "parent_route53_zone" {
  description = "Parent Route53 zone name used for delegation (required when enable_parent_zone_delegation=true)"
  type        = string
  default     = ""
}

# ---- Compute ----
variable "aws_ami" {
  description = "AMI ID (Ubuntu 22.04 recommended)"
  type        = string
}

variable "aws_ssh_user" {
  description = "SSH username for AMI (ubuntu / ec2-user / centos)"
  type        = string
  default     = "ubuntu"
}

variable "registry_instance_type" {
  description = "Instance type for registry/bastion node"
  type        = string
  default     = "c6i.2xlarge"
}

variable "server_instance_type" {
  description = "Instance type for RKE2 server nodes"
  type        = string
  default     = "c6i.2xlarge"
}

variable "agent_instance_type" {
  description = "Instance type for RKE2 agent nodes"
  type        = string
  default     = "c6i.2xlarge"
}

variable "server_count" {
  description = "Number of RKE2 server/control-plane nodes (1 = dev, 3 = HA)"
  type        = number
  default     = 1
}

variable "agent_count" {
  description = "Number of RKE2 agent/worker nodes"
  type        = number
  default     = 0
}

# ---- Storage ----
variable "registry_volume_size_gb" {
  description = "EBS volume size for registry node (GB)"
  type        = number
  default     = 200

  validation {
    condition     = var.registry_volume_size_gb >= 200
    error_message = "registry_volume_size_gb must be at least 200 GB."
  }
}

variable "server_volume_size_gb" {
  description = "EBS volume size for server nodes (GB)"
  type        = number
  default     = 50

  validation {
    condition     = var.server_volume_size_gb >= 50
    error_message = "server_volume_size_gb must be at least 50 GB."
  }
}

variable "agent_volume_size_gb" {
  description = "EBS volume size for agent nodes (GB)"
  type        = number
  default     = 50

  validation {
    condition     = var.agent_volume_size_gb >= 50
    error_message = "agent_volume_size_gb must be at least 50 GB."
  }
}

# ---- Version Pins ----
variable "rancher_version" {
  description = "Rancher version (e.g. 2.9.0)"
  type        = string
}

variable "rke2_version" {
  description = "RKE2 version (e.g. v1.30.2+rke2r1)"
  type        = string
}

variable "helm_version" {
  description = "Helm CLI version (e.g. v3.15.0)"
  type        = string
  default     = "v3.15.0"
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version (e.g. v1.14.3)"
  type        = string
  default     = "v1.14.3"
}

# ---- Rancher ----
variable "rancher_hostname" {
  description = "Preferred Rancher hostname for Helm install. When enable_route53=false, external NLB DNS will be used for access."
  type        = string
}

variable "rancher_bootstrap_password" {
  description = "Initial admin password for Rancher (change after first login)"
  type        = string
  sensitive   = true
}

# ---- Registry ----
variable "registry_username" {
  description = "Username for the private Docker registry"
  type        = string
  default     = "admin"
}

variable "registry_password" {
  description = "Password for the private Docker registry"
  type        = string
  sensitive   = true
}

# ---- TLS ----
variable "tls_mode" {
  description = "TLS mode: rancher-self-signed | lets-encrypt | secret"
  type        = string
  default     = "rancher-self-signed"

  validation {
    condition     = contains(["rancher-self-signed", "lets-encrypt", "secret"], var.tls_mode)
    error_message = "tls_mode must be one of: rancher-self-signed, lets-encrypt, secret"
  }
}

variable "lets_encrypt_email" {
  description = "Email for Let's Encrypt (required when tls_mode = lets-encrypt)"
  type        = string
  default     = ""
}

variable "tls_cert_path" {
  description = "Local path to TLS cert PEM (required when tls_mode = secret)"
  type        = string
  default     = ""
}

variable "tls_key_path" {
  description = "Local path to TLS key PEM (required when tls_mode = secret)"
  type        = string
  default     = ""
}

variable "tls_ca_path" {
  description = "Local path to TLS CA PEM (optional, for tls_mode = secret)"
  type        = string
  default     = ""
}

# ---- Naming ----
variable "prefix" {
  description = "Resource name prefix (used for all AWS resource names)"
  type        = string
  default     = "zegress"
}
