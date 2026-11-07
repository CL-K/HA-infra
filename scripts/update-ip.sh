#!/bin/bash
set -e

# Usage: ./scripts/update-ip.sh [-y|--yes]
#   (no option) : displays the Terraform plan and asks for confirmation
#   -y, --yes   : applies without confirmation (useful for automation)
AUTO_APPROVE=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_APPROVE="-auto-approve" ;;
    *) echo "Unknown option: $arg"; echo "Usage: $0 [-y|--yes]"; exit 1 ;;
  esac
done

# The script lives in scripts/, the Terraform code in ../terraform
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
cd "$TERRAFORM_DIR"

# Idempotent: fast if already initialized, repairs or installs otherwise
# (missing providers, changed version, updated lock file, etc.)
terraform init -input=false

MY_IP=$(curl -s -4 https://ifconfig.me)

if [ -z "$MY_IP" ]; then
  echo "Error: unable to retrieve the public IP"
  exit 1
fi

echo "Detected IP: $MY_IP"
echo "allowed_ssh_cidr = \"${MY_IP}/32\"" > terraform.tfvars

# Without -y: Terraform displays the plan and asks you to type "yes"
terraform apply $AUTO_APPROVE
