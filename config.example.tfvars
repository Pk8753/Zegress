# =============================================================================
# ZEGRESS : ZERO EGRESS SETUP FOR SECURE AI
# Rancher Air-Gap AWS Deployment — Configuration Template
# 
# **IMPORTANT**: Copy this file to `config.tfvars` and fill in YOUR values.
# DO NOT commit config.tfvars to git — it contains sensitive credentials.
# 
# How to use:
#   1. cp config.example.tfvars config.tfvars
#   2. Edit config.tfvars with your AWS credentials and settings
#   3. config.tfvars is automatically ignored by .gitignore
#   4. Run: ./deploy.sh
# =============================================================================

# ---- AWS CREDENTIALS (Required) ----
# Get these from: AWS Console → IAM → Users → Your User → Security Credentials
# Create an IAM user with permissions to: EC2, VPC, NLB, Route53, IAM (for tags)
aws_access_key = "YOUR_AWS_ACCESS_KEY_ID"      # Your AWS Access Key ID (e.g. AKIA...)
aws_secret_key = "YOUR_AWS_SECRET_ACCESS_KEY"  # Keep secret!
aws_region     = "ap-south-1"                   # AWS region where resources will be created

# ---- NETWORKING (Required) ----
# Enable Route53 resources and records.
# Set to false for NLB-only access mode (no Route53 dependency).
enable_route53 = false

# Route53 hosted zone must already exist in your AWS account when enable_route53=true
create_route53_zone = false                     # Set to false to use existing zone

aws_route53_zone = "example.com"                # Your existing Route53 hosted zone
rancher_hostname = "rancher.example.com"        # Used when enable_route53=true

# Parent zone delegation (for child zones)
enable_parent_zone_delegation = false
parent_route53_zone           = "example.com"

# Use external NLB DNS as Rancher hostname. Keep true for NLB-only mode.
use_nlb_dns_hostname = true

# ---- AMI AND SSH (Required) ----
# Ubuntu 22.04 LTS AMI by region
#   us-east-1  → ami-0c7217cdde317cfec
#   us-west-2  → ami-03f65b8614a860c29
#   eu-west-1  → ami-0d2a4a5d69e46ea0b
#   ap-south-1 → ami-0326c8c1e2d6bf78c
aws_ami      = "ami-0326c8c1e2d6bf78c"
aws_ssh_user = "ubuntu"                        # ubuntu | ec2-user | centos

# ---- INSTANCE TYPES (Adjust as needed) ----
# Minimum: c6i.2xlarge (8 vCPU) for Rancher
registry_instance_type = "c6i.2xlarge"
server_instance_type   = "c6i.2xlarge"
agent_instance_type    = "c6i.2xlarge"

# ---- NODE COUNTS ----
server_count = 1                                # 1 for dev | 3+ for production HA
agent_count  = 0                                # 0 for single-node | 1+ for multi-node

# ---- STORAGE (GB) ----
registry_volume_size_gb = 200                   # Must be ≥ 200 GB (stores all images)
server_volume_size_gb   = 50                    # Must be ≥ 50 GB
agent_volume_size_gb    = 50                    # Only used when agent_count > 0

# ---- RANCHER VERSIONS (Required) ----
rancher_version      = "2.14.2"
rke2_version         = "v1.35.2+rke2r1"
helm_version         = "v3.15.0"
cert_manager_version = "v1.14.3"

# ---- RANCHER CREDENTIALS (Required) ----
# Change this to a strong password for initial admin setup
rancher_bootstrap_password = "ChangeMeSecurePassword123!"

# ---- PRIVATE REGISTRY CREDENTIALS (Required) ----
registry_username = "admin"
registry_password = "ChangeMeRegistryPassword123!"

# ---- TLS MODE (Required) ----
# Choose ONE of: rancher-self-signed | lets-encrypt | secret
tls_mode = "rancher-self-signed"

# If using Let's Encrypt:
# tls_mode = "lets-encrypt"
# lets_encrypt_email = "admin@example.com"

# If using custom certificate:
# tls_mode = "secret"
# tls_cert_path = "/path/to/fullchain.pem"
# tls_key_path  = "/path/to/privkey.pem"
# tls_ca_path   = "/path/to/ca.pem"

# ---- RANCHER EDITION ----
# Rancher Prime (SUSE): stgregistry.suse.com/rancher/rancher:v2.x.x
# Community: docker.io/rancher/rancher:v2.x.x
rancher_source_registry = "docker.io"          # docker.io or stgregistry.suse.com

# ---- NAMING PREFIX (Required) ----
# Used to name all AWS resources (VPC, EC2, NLB, etc.)
prefix = "zegress"

# ---- DEPLOYMENT METADATA ----
environment = "development"                     # For resource tagging
owner       = "your-email@example.com"          # For resource tagging

# ---- DOWNSTREAM CLUSTER (Optional) ----
# Enable create-downstream.sh workflow
enable_downstream_cluster     = false
downstream_cluster_name       = "downstream-airgap"
downstream_kubernetes_version = "v1.35.2+rke2r1"
downstream_instance_type      = "c6i.2xlarge"
downstream_root_size_gb       = 50

# Optional override. If empty, create-downstream.sh uses management rancher_url output.
rancher_api_url               = ""

# Required for downstream create workflow (Rancher API token)
rancher_token_key             = ""
