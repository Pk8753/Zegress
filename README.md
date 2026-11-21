# Zegress : Zero Egress Setup for secure AI
## Rancher Air-Gap Deployment on AWS

### Build secure, private AI applications where your data never leaves your walls.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║   ███████╗███████╗ ██████╗ ██████╗ ███████╗███████╗███████╗                  ║
║   ╚══███╔╝██╔════╝██╔════╝ ██╔══██╗██╔════╝██╔════╝██╔════╝                  ║
║     ███╔╝ █████╗  ██║  ███╗██████╔╝█████╗  ███████╗███████╗                  ║
║    ███╔╝  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ╚════██║╚════██║                  ║
║   ███████╗███████╗╚██████╔╝██║  ██║███████╗███████║███████║                  ║
║   ╚══════╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝                  ║
║                                                                              ║
║             ZEGRESS — ZERO EGRESS AIR-GAP SETUP FOR SECURE AI                ║
║                        One command. Fully automated.                         ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

---

## Why This Project Exists

AI is transforming every industry, but for organizations that handle **highly sensitive data**, sending information to public cloud services or third-party APIs is often not an option. Patient records, classified material, citizen data, financial transactions — this information has to stay **in-house**.

Setting up an air-gapped Kubernetes platform by hand is slow and painful: mirroring hundreds of container images, wiring up a private registry, configuring a cluster that has no internet access, and installing a management layer on top. It can take days or weeks of specialized effort before a team can even begin deploying their own application.

**This framework removes that barrier.** With a single command, it provisions a production-grade [Rancher](https://rancher.com/) Kubernetes cluster in a fully air-gapped environment, so your team can skip the infrastructure struggle and go straight to building and deploying secure, AI-based applications.

### Who is this for?

Anyone who needs to build or run applications — especially AI-powered ones — on sensitive data and information, including:

| Sector | Example Use Cases |
|--------|-------------------|
| 🏥 **Healthcare** | Clinical decision support, medical record summarization, diagnostic assistants — with patient data kept private |
| 🛡️ **Military & Defense** | Secure intelligence analysis, mission planning tools, internal knowledge assistants on isolated networks |
| 🏛️ **Government** | Citizen-service automation, document processing, policy analysis without exposing records externally |
| 🏦 **Banking & Finance** | Fraud detection, risk analysis, internal AI copilots — with financial data never leaving your infrastructure |
| 🔬 **Research, Legal & Enterprise** | Any team handling confidential, regulated, or proprietary data |

### What you get

- ⚡ **Faster air-gap setup** — go from zero to a ready Rancher cluster in roughly 25–35 minutes instead of days of manual work
- 🔒 **Data stays in-house** — cluster nodes have no public internet access; all images are served from your own private registry
- 🤖 **A ready platform for your AI apps** — deploy your own AI workloads, models, and services on top of the cluster, inside an air-gapped or local network
- 🔁 **Resumable & repeatable** — if anything fails, re-run and it picks up where it left off
- 🧩 **Infrastructure as code** — everything is defined in Terraform, so deployments are consistent and auditable
- 🛠️ **Single config file** — one file to edit, one command to run

---

## Built for the Modern Secure AI Stack

Once Zegress completes, you have an enterprise-grade Kubernetes control plane ready to host your entire offline AI ecosystem:

| Layer | Open-Source & Private AI Tools Supported |
| :--- | :--- |
| **Inference Engines** | [vLLM](https://github.com/vllm-project/vllm), [Ollama](https://ollama.ai/), [TGI (Text Generation Inference)](https://github.com/huggingface/text-generation-inference), [LocalAI](https://localai.io/), [NVIDIA Triton](https://developer.nvidia.com/triton-inference-server) |
| **Vector Databases** | [Milvus](https://milvus.io/), [Qdrant](https://qdrant.tech/), [Chroma](https://www.trychroma.com/), [Weaviate](https://weaviate.io/), [pgvector](https://github.com/pgvector/pgvector) |
| **Private RAG & UI** | [Open WebUI](https://github.com/open-webui/open-webui), [Flowise](https://flowiseai.com/), [Dify](https://dify.ai/), [LangChain](https://www.langchain.com/), [LlamaIndex](https://www.llamaindex.ai/) |
| **Models Hosted** | DeepSeek-R1, Llama 3 / 3.3, Mistral, Qwen 2.5, Phi-3, Whisper, embedding models |

---

## Description

A **fully automated, resumable** deployment framework that provisions and configures a production-grade [Rancher](https://rancher.com/) cluster on AWS in an **air-gapped** (no internet on cluster nodes) environment.

All container images are pulled from the internet on a **registry node** and served to cluster nodes through a **private Docker registry** — the cluster nodes never need a public internet connection. Once the platform is up, you can deploy your own applications into the cluster and keep your data entirely within your network.

### What gets deployed

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS (Your Region)                    │
│                                                             │
│  ┌──────────────┐    ┌─────────────────────────────────┐    │
│  │   Internet   │    │         Private Subnet          │    │
│  │    (NLB)     │───▶│  ┌────────────┐  ┌───────────┐  │    │
│  │  Port 80/443 │    │  │ RKE2 Server│  │ RKE2 Agent│  │    │
│  └──────────────┘    │  │  (Rancher) │  │  (Worker) │  │    │ 
│                      │  └────────────┘  └───────────┘  │    │
│  ┌──────────────┐    │         ▲               ▲       │    │
│  │  Public      │    │         │  Images from  │       │    │
│  │  Subnet      │    │  ┌──────┴───────────────┘────┐  │    │
│  │ ┌──────────┐ │    │  │  Private Registry         │  │    │
│  │ │ Registry │ │    │  │  (localhost:5000)         │  │    │
│  │ │ (Bastion)│─┼───▶│  └───────────────────────────┘  │    │
│  │ └──────────┘ │    └─────────────────────────────────┘    │
│  └──────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
```

### Deployment Timeline

| Time | What's Happening |
|------|-----------------|
| `0–5 min` | Terraform provisions VPC, subnets, EC2 instances, NLB (and Route53 only when enabled) |
| `5–10 min` | Registry node bootstraps: installs Docker, pulls RKE2 artifacts |
| `10–20 min` | 100-150 bootstrap images pushed to private registry; RKE2 cluster forms |
| `20–25 min` | cert-manager + Rancher installed via Helm |
| `25–35 min` | Rancher UI is accessible |
| `35–120 min` | 609 remaining images loaded in the background |

---

## Prerequisites

Install the following tools on your **local machine** before running:

| Tool | Min Version | Install |
|------|------------|---------|
| `terraform` | ≥ 1.5 | https://developer.hashicorp.com/terraform/install |
| `aws` CLI | ≥ 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| `ssh` / `scp` | any | Built-in on macOS/Linux |
| `curl` | any | Built-in on macOS/Linux |
| `jq` | ≥ 1.6 | `brew install jq` / `apt install jq` |

### AWS Requirements

- An AWS account with permissions to create: VPC, EC2, NLB, IAM (for tags), and optionally Route53
- Route53 hosted zone is required only when `enable_route53 = true`
- An **EC2 Key Pair** — place the `.pem` file at `ssh-key.pem` in the project root

---

## Setup & Configuration

### Step 1 — Clone / copy project

```bash
git clone <repo-url> rancher-air-gap
cd rancher-air-gap
```

### Step 2 — Place your SSH key

```bash
# Copy your EC2 key pair private key to the project root
cp ~/Downloads/my-key.pem ./ssh-key.pem
chmod 400 ssh-key.pem
```

### Step 3 — Edit `config.tfvars`

This is the **only file you need to edit**. It lives at:

```
rancher-air-gap/
└── config.tfvars   ← EDIT THIS FILE
```

---

## Required Configuration — `config.tfvars`

All deployment parameters are controlled from a single file: `config.tfvars`.

### AWS Credentials  *(Required)*

```hcl
aws_access_key = "AKIA..."              # Your AWS access key ID
aws_secret_key = "xxxx..."              # Your AWS secret access key
aws_region     = "ap-south-1"          # AWS region to deploy in
```

> 💡 Alternatively, set env vars `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` — the script picks them up automatically.

---

### DNS & Networking

```hcl
enable_route53 = false                   # Recommended for air-gap NLB-only access
use_nlb_dns_hostname = true              # Use external NLB DNS as Rancher URL/hostname

# Only required when enable_route53 = true
aws_route53_zone  = "test.example.com"  # Your Route53 hosted zone name
rancher_hostname  = "rancher.test.example.com"

# Set true only if your parent zone (e.g. example.com) is in the SAME AWS account
enable_parent_zone_delegation = false
```

---

### AMI & SSH  *(Required)*

```hcl
aws_ami      = "ami-0326c8c1e2d6bf78c"   # Ubuntu 22.04 LTS (region-specific)
aws_ssh_user = "ubuntu"                  # ubuntu | ec2-user | centos
```

> Common Ubuntu 22.04 AMIs:
> - `us-east-1` → `ami-0c7217cdde317cfec`
> - `us-west-2` → `ami-03f65b8614a860c29`
> - `ap-south-1` → `ami-0326c8c1e2d6bf78c`

---

### Instance & Storage Sizes  *(Adjust as needed)*

```hcl
registry_instance_type  = "c6i.2xlarge"   # 8 vCPU — registry/bastion (always 1)
server_instance_type    = "c6i.2xlarge"   # 8 vCPU minimum for RKE2 server
agent_instance_type     = "c6i.2xlarge"   # 8 vCPU minimum for RKE2 agents

server_count = 1    # 1 = dev/single-node | 3 = production HA
agent_count  = 0    # 0 = server also acts as worker (only 2 EC2 total)
                    # Set > 0 to add dedicated worker nodes

registry_volume_size_gb = 200   # Must be ≥ 200 GB (stores all images)
server_volume_size_gb   = 50    # Must be ≥ 50 GB
agent_volume_size_gb    = 50    # Must be ≥ 50 GB (only used when agent_count > 0)
```

> **How many EC2 instances will be created?**
>
> | Configuration | EC2 Instances |
> |--------------|--------------|
> | `server_count=1, agent_count=0` | **2** → registry + server (server acts as worker) |
> | `server_count=1, agent_count=2` | **4** → registry + 1 server + 2 agents |
> | `server_count=3, agent_count=3` | **7** → registry + 3 servers + 3 agents |
>
> `agent_instance_type` and `agent_volume_size_gb` are only used when `agent_count > 0`.

---

### Rancher & Versions  *(Required)*

```hcl
rancher_version      = "2.14.2"
rke2_version         = "v1.35.2+rke2r1"
helm_version         = "v3.15.0"
cert_manager_version = "v1.14.3"
```

---

### Rancher Credentials  *(Required)*

```hcl
rancher_bootstrap_password = "YourStrongPassword!"   # Change after first login!
```

---

### Private Registry Credentials  *(Required)*

```hcl
registry_username = "admin"
registry_password = "Registry"
```

---

### TLS Mode  *(Choose one)*

```hcl
tls_mode = "rancher-self-signed"   # Easiest — Rancher creates its own CA

# OR:
tls_mode = "lets-encrypt"
lets_encrypt_email = "admin@example.com"   # Required for Let's Encrypt

# OR:
tls_mode = "secret"
tls_cert_path = "/path/to/fullchain.pem"   # Required for custom cert
tls_key_path  = "/path/to/privkey.pem"
tls_ca_path   = "/path/to/ca.pem"
```

---

### Naming Prefix  *(Required)*

```hcl
prefix = "my-rancher"   # Used for all AWS resource names and tags
```

---

## Deploy

```bash
./deploy.sh
```

That's it. The script is **fully resumable** — if it fails at any step, just re-run and it picks up where it left off.

### What happens at each step

```
STEP 1/6 — Terraform: provision AWS infrastructure
STEP 2/6 — Wait for registry node SSH to become available
STEP 3/6 — Wait for registry bootstrap + upload scripts & image lists
STEP 4/6 — Push bootstrap images to private registry
STEP 5/6 — Wait for RKE2 cluster + install cert-manager + Rancher
STEP 6/6 — Wait for Rancher UI + kick off background image push
```

### Resume behaviour

| Scenario | What happens |
|----------|-------------|
| First run | All 6 steps execute |
| Re-run after step 3 failed | Steps 1–3 skip, step 3 retries |
| Re-run after full success | State file is gone — fresh run starts |

---

## What to Check After Deployment

### 1. Rancher UI

Open in browser:
```
https://<rancher_hostname>
```

When `enable_route53 = false`, Rancher URL will be the external NLB DNS name.

> If DNS is not set up, add an entry to your local `/etc/hosts`:
> ```bash
> # Get current NLB IP
> dig +short <NLB_DNS_from_output>
>
> # Add to /etc/hosts
> echo '<NLB_IP> <rancher_hostname>' | sudo tee -a /etc/hosts
> ```

Login with:
- **Username**: `admin`
- **Password**: value of `rancher_bootstrap_password` in `config.tfvars`

---

### 2. Cluster Nodes

```bash
ssh -i ssh-key.pem ubuntu@<registry_public_ip> 'kubectl get nodes'
```

Expected output:
```
NAME           STATUS   ROLES                AGE   VERSION
ip-10-0-2-xx   Ready    control-plane,etcd   5m    v1.35.x+rke2r1
```

---

### 3. Background Image Push Progress

All 609 remaining images are pushed in the background after Rancher is up.

```bash
# Follow local log (mirrors registry output)
tail -f logs/push-remaining-images.log

# Check if push is still running or done
ssh -i ssh-key.pem ubuntu@<registry_public_ip> \
  'test -f /tmp/push-remaining-images.done && cat /tmp/push-remaining-images.exitcode || echo RUNNING'
```

| Output | Meaning |
|--------|---------|
| `RUNNING` | Background push still in progress |
| `0` | All images pushed successfully |
| non-zero | ❌ Push failed — check `logs/push-remaining-images.log` |

---

### 4. Verify Summary in Push Log

```bash
grep "REQUIRED complete:" logs/push-remaining-images.log
grep "Air-gap setup is fully complete" logs/push-remaining-images.log
```

When you see:
```
REQUIRED complete: pushed=609 failed=0 total=609
=== All required images pushed. Air-gap setup is fully complete! ===
```
The air-gap setup is 100% complete.

---

## Next Step — Deploy Your Own Secure AI Application

Once the air-gap setup is complete, your private Rancher/Kubernetes platform is ready for your workloads. From here you can:

- Deploy your own AI-based applications, models, and APIs into the cluster
- Pull all container images from your **private registry** instead of the public internet
- Keep sensitive data — patient records, financial data, government or defense information — entirely inside your own network
- Manage, monitor, and scale your workloads through the Rancher UI

---

## Project Structure

```
rancher-air-gap/
│
├── config.tfvars              ← YOUR ONLY CONFIG FILE — edit this
├── deploy.sh                  ← Main deployment script (run this)
├── destroy.sh                 ← Tear down everything
├── ssh-key.pem                ← Your EC2 key pair (you provide this)
│
├── data/
│   ├── rancher-images.txt     ← Master image list (from Rancher releases)
│   ├── bootstrap-images.txt   ← Auto-generated: critical images (push first)
│   └── required-images.txt    ← Auto-generated: remaining images (background)
│
├── scripts/
│   ├── utils.sh               ← Shared logging + SSH helpers
│   ├── bootstrap-images-push.sh ← Push bootstrap images to registry
│   ├── install-rancher.sh     ← Install cert-manager + Rancher via Helm
│   └── push-remaining-images.sh ← Background image push
│
├── terraform/                 ← All AWS infrastructure as code
│   ├── main.tf
│   ├── variables.tf
│   ├── network.tf             ← VPC, subnets, IGW, NAT
│   ├── cluster.tf             ← EC2 instances (registry, server, agents)
│   ├── nlb.tf                 ← Network Load Balancer
│   ├── dns.tf                 ← Route53 records
│   ├── outputs.tf             ← Terraform outputs used by deploy.sh
│   └── config.tfvars          ← (DO NOT EDIT — use root config.tfvars)
│
└── logs/                      ← All deployment logs land here
    ├── terraform-apply.log
    ├── bootstrap-images-push.log
    ├── install-rancher.log
    └── push-remaining-images.log
```

---

## Destroy Everything

When you're done and want to tear down all AWS resources:

```bash
./destroy.sh
```

> ⚠️ This deletes **all AWS resources** created by this deployment including EC2 instances, NLB, VPC, and Route53 records. Data is not recoverable.

---

## Useful Commands

```bash
# SSH to registry node
ssh -i ssh-key.pem ubuntu@<registry_public_ip>

# Watch background image push progress (local)
tail -f logs/push-remaining-images.log

# Check image push completion status
ssh -i ssh-key.pem ubuntu@<registry_public_ip> \
  'test -f /tmp/push-remaining-images.done && cat /tmp/push-remaining-images.exitcode || echo RUNNING'

# Run kubectl via registry bastion
ssh -i ssh-key.pem ubuntu@<registry_public_ip> 'kubectl get nodes'
ssh -i ssh-key.pem ubuntu@<registry_public_ip> 'kubectl get pods -A'

# Check Rancher pods
ssh -i ssh-key.pem ubuntu@<registry_public_ip> \
  'kubectl get pods -n cattle-system'

# Destroy all AWS resources
./destroy.sh
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `Rancher UI did not become available` | DNS not resolving — add `/etc/hosts` entry with NLB IP |
| `Registry bootstrap timed out` | Script auto-recovers by recreating registry instance |
| `Permission denied (ssh-key.pem)` | Run `chmod 400 ssh-key.pem` |
| `aws_region missing in config.tfvars` | Edit `config.tfvars` and set `aws_region` |
| `vCPU count too low` | Use instance types with ≥ 8 vCPU (e.g. `c6i.2xlarge`) |
| `Background push not starting` | Check `logs/push-remaining-images.log` for errors |

---

## Quick Reference Card

```
┌──────────────────────────────────────────────────────────────────┐
│  DEPLOYMENT CHECKLIST                                            │
├──────────────────────────────────────────────────────────────────┤
│  □ terraform, aws, ssh, scp, curl, jq installed                  │
│  □ ssh-key.pem placed in project root (chmod 400)                │
│  □ config.tfvars edited with your AWS credentials                │
│  □ rancher_hostname is a subdomain of your Route53 zone          │
│  □ rancher_bootstrap_password set to something secure            │
├──────────────────────────────────────────────────────────────────┤
│  DEPLOY:    ./deploy.sh                                          │
│  DESTROY:   ./destroy.sh                                         │
│  RESUME:    ./deploy.sh  (safe to re-run anytime)                │
│  LOGS:      ls logs/                                             │
│  PROGRESS:  tail -f logs/push-remaining-images.log               │
└──────────────────────────────────────────────────────────────────┘
```