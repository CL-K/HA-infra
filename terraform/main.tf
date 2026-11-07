# ============================================================
# Terraform / provider versions
# ============================================================
# The .terraform.lock.hcl file (versioned in git) pins the EXACT
# provider version; the constraint below is only a safeguard.
# 'domain = "vpc"' on aws_eip requires an AWS provider >= 5.0.
# To deliberately upgrade: terraform init -upgrade,
# then commit the new .terraform.lock.hcl.
terraform {
  required_version = ">= 1.5, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

# ============================================================
# Variables
# ============================================================
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed for SSH AND for the K3s API (port 6443) - replace with your IP: 'x.x.x.x/32'"
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  description = "Instance type (masters and workers)"
  type        = string
  default     = "m5.large"
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI (us-east-1) - check/update if the AMI is retired (end of standard support for Ubuntu 22.04: 2027)"
  type        = string
  default     = "ami-08c40ec9ead489470"
}

variable "master_count" {
  description = "Number of master nodes (must stay odd for the etcd quorum)"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "az_count" {
  description = "Number of availability zones (AZs) across which to spread masters and workers (round-robin). With the default value (3) and master_count/worker_count=3, each node of a given role is in a distinct AZ: losing one AZ leaves 2 masters (etcd quorum still a majority) and 2 active workers."
  type        = number
  default     = 3
}

variable "volume_size_master" {
  description = "Root disk size in GB for the masters (etcd is sensitive to I/O)"
  type        = number
  default     = 50
}

variable "volume_size_worker" {
  description = "Root disk size in GB for the workers"
  type        = number
  default     = 50
}

variable "key_name" {
  description = "SSH key name"
  type        = string
  default     = "my-ssh-key"
}

variable "project_name" {
  description = "Project name (used for tags)"
  type        = string
  default     = "k3s-cluster"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "192.168.0.0/16"
}

variable "subnet_cidr" {
  description = "Base CIDR for the public subnets (masters). Automatically split into one /26 per AZ (up to 4 AZs) via cidrsubnet() - must stay consistent with ansible/hosts (see the file's comments)."
  type        = string
  default     = "192.168.2.0/24"
}

variable "private_subnet_cidr" {
  description = "Base CIDR for the private subnets (workers). Automatically split into one /26 per AZ (up to 4 AZs) via cidrsubnet() - must stay consistent with ansible/hosts (see the file's comments)."
  type        = string
  default     = "192.168.3.0/24"
}

# ============================================================
# Provider
# ============================================================
provider "aws" {
  region = var.region
}

# ============================================================
# Data source: AZs available in the region
# ============================================================
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # The first az_count AZs available in the region, used
  # round-robin to spread masters and workers.
  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(var.az_count, length(data.aws_availability_zones.available.names))
  )
  az_n = length(local.azs)
}

# ============================================================
# Network (MULTI-AZ)
# ============================================================
# Real HA: one public subnet + one private subnet per AZ used
# (local.azs). Masters and workers are spread round-robin across
# these AZs (see aws_instance.master/worker below). Losing an AWS
# AZ therefore only affects a fraction of the cluster, instead of
# taking it entirely out of service.
#
# - PUBLIC subnets (masters): direct IGW + one EIP per master.
# - PRIVATE subnets (workers): no public IP, Internet egress
#   through a NAT Gateway DEDICATED PER AZ (needed for apt and curl
#   get.k3s.io run by the Ansible site.yml playbook on the
#   workers) - prevents a single NAT Gateway from itself becoming a
#   point of failure shared across AZs.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

resource "aws_subnet" "public" {
  count                   = local.az_n
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.subnet_cidr, 2, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-subnet-public-${count.index + 1}"
    Project = var.project_name
    AZ      = local.azs[count.index]
  }
}

resource "aws_subnet" "private" {
  count                   = local.az_n
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.private_subnet_cidr, 2, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name    = "${var.project_name}-subnet-private-${count.index + 1}"
    Project = var.project_name
    AZ      = local.azs[count.index]
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

# A single public route table (identical IGW route for all
# AZs) shared by all public subnets.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project_name}-rt-public"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  count          = local.az_n
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Dedicated NAT Gateway per AZ: each private subnet egresses through ITS
#     own NAT Gateway (in the public subnet of the same AZ), no
#     cross-AZ dependency for Internet egress ---
resource "aws_eip" "nat" {
  count  = local.az_n
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-nat-eip-${count.index + 1}"
    Project = var.project_name
  }
}

resource "aws_nat_gateway" "main" {
  count         = local.az_n
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id # NAT GW of AZ N lives in the public subnet of AZ N

  tags = {
    Name    = "${var.project_name}-nat-${count.index + 1}"
    Project = var.project_name
  }

  depends_on = [aws_internet_gateway.main]
}

# One private route table PER AZ, each pointing to the NAT
# Gateway of its own AZ.
resource "aws_route_table" "private" {
  count  = local.az_n
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name    = "${var.project_name}-rt-private-${count.index + 1}"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "private" {
  count          = local.az_n
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ============================================================
# Security Group
# ============================================================
resource "aws_security_group" "k3s" {
  name        = "${var.project_name}-sg"
  description = "Rules for the multi-AZ HA K3s cluster (SSH, HTTP, HTTPS, API server, etcd, kubelet, VXLAN)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # K3s API server (kube-apiserver) - external access for kubectl,
  # restricted to the same CIDR as SSH (allowed_ssh_cidr): avoids exposing
  # the Kubernetes API to the whole Internet. The scripts/update-ip.sh script
  # automatically sets this CIDR to the public IP of the control
  # machine on every run.
  ingress {
    description = "K3s API server (restricted to allowed_ssh_cidr)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Full internal traffic between the cluster nodes (etcd, kubelet,
  # flannel VXLAN, etc.). "self = true" covers traffic between all
  # instances attached to this SG, including across different AZs
  # (the VPC natively routes between its own subnets, whatever
  # their AZ).
  ingress {
    description = "Internal cluster traffic (etcd, kubelet, flannel, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-sg"
    Project = var.project_name
  }
}

# ============================================================
# SSH key
# ============================================================
resource "aws_key_pair" "main" {
  key_name   = var.key_name
  public_key = file("${path.module}/keys/${var.key_name}.pub")

  tags = {
    Project = var.project_name
  }
}

# ============================================================
# EC2 instances - Masters (control plane + etcd, public subnets)
#
# Round-robin distribution over local.azs: master[i] goes into the
# public subnet of index (i % az_n), in the corresponding AZ. The
# private IP is computed automatically (cidrhost) inside the
# target subnet, host 10 + N-th pass over the same AZ (to
# stay compatible with master_count > az_count without collisions).
# ============================================================
resource "aws_instance" "master" {
  count                  = var.master_count
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[count.index % local.az_n].id
  private_ip             = cidrhost(aws_subnet.public[count.index % local.az_n].cidr_block, 10 + floor(count.index / local.az_n))
  vpc_security_group_ids = [aws_security_group.k3s.id]
  key_name               = aws_key_pair.main.key_name

  # No user_data: the k3s installation is entirely handled
  # by the Ansible site.yml playbook (ansible-playbook site.yml).
  # The standard Ubuntu AMI already ships python3, required by Ansible.

  root_block_device {
    volume_size           = var.volume_size_master
    volume_type            = "gp3"
    encrypted              = true
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.project_name}-master-${count.index + 1}"
    Project = var.project_name
    Role    = "master"
    AZ      = local.azs[count.index % local.az_n]
  }
}

# ============================================================
# EC2 instances - Workers (private subnets, one per AZ, no EIP)
# Same round-robin distribution logic as the masters.
# ============================================================
resource "aws_instance" "worker" {
  count                   = var.worker_count
  ami                     = var.ami_id
  instance_type           = var.instance_type
  subnet_id               = aws_subnet.private[count.index % local.az_n].id
  private_ip              = cidrhost(aws_subnet.private[count.index % local.az_n].cidr_block, 10 + floor(count.index / local.az_n))
  vpc_security_group_ids  = [aws_security_group.k3s.id]
  key_name                = aws_key_pair.main.key_name

  # No user_data: the k3s agent join is entirely handled by
  # the Ansible site.yml playbook.

  root_block_device {
    volume_size           = var.volume_size_worker
    volume_type            = "gp3"
    encrypted              = true
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.project_name}-worker-${count.index + 1}"
    Project = var.project_name
    Role    = "worker"
    AZ      = local.azs[count.index % local.az_n]
  }

  # Workers start after the masters (the cluster must exist
  # and master1 must be up to serve as SSH bastion) and after
  # all NAT Gateways are ready (Internet egress required).
  depends_on = [aws_instance.master, aws_nat_gateway.main]
}

# ============================================================
# Elastic IP - only on the masters (API access + admin SSH)
# Workers stay on private IPs (private subnets, no EIP)
# ============================================================
resource "aws_eip" "master" {
  count    = var.master_count
  instance = aws_instance.master[count.index].id
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-master-${count.index + 1}-eip"
    Project = var.project_name
  }
}

# ============================================================
# Outputs
# ============================================================
output "masters" {
  description = "Public IPs, private IPs and AZs of the masters"
  value = {
    for idx, inst in aws_instance.master :
    "master-${idx + 1}" => {
      private_ip = inst.private_ip
      public_ip  = aws_eip.master[idx].public_ip
      az         = local.azs[idx % local.az_n]
    }
  }
}

output "workers" {
  description = "Private IPs and AZs of the workers (no public IP, private subnets)"
  value = {
    for idx, inst in aws_instance.worker :
    "worker-${idx + 1}" => {
      private_ip = inst.private_ip
      az         = local.azs[idx % local.az_n]
    }
  }
}

output "availability_zones" {
  description = "AZs used by the cluster (round-robin masters/workers)"
  value       = local.azs
}

output "master1_public_ip" {
  description = "Public IP of master1 - to put in the hosts inventory in place of <MASTER1_PUBLIC_IP>"
  value       = aws_eip.master[0].public_ip
}
