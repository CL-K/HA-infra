#!/bin/bash
# ============================================================
# update-hosts.sh
#
# Retrieves the masters' public IPs from `terraform output`
# and injects them into hosts in place of the placeholders
# <MASTER1_PUBLIC_IP>, <MASTER2_PUBLIC_IP>, <MASTER3_PUBLIC_IP>.
#
# Prerequisites:
#   - `terraform apply` must have been run beforehand
#   - jq installed (apt install jq / brew install jq)
#
# Usage (from any folder, the script locates itself):
#   ./scripts/update-hosts.sh                          -> terraform_dir=../terraform hosts_file=../ansible/hosts (default)
#   ./scripts/update-hosts.sh path/hosts                -> explicit hosts_file, default terraform_dir
#   ./scripts/update-hosts.sh path/terraform path/hosts -> both explicit
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
DEFAULT_HOSTS_FILE="$SCRIPT_DIR/../ansible/hosts"

if [ $# -eq 1 ]; then
  # Only one argument provided: assume it is the hosts file
  TERRAFORM_DIR="$DEFAULT_TERRAFORM_DIR"
  HOSTS_FILE="$1"
else
  TERRAFORM_DIR="${1:-$DEFAULT_TERRAFORM_DIR}"
  HOSTS_FILE="${2:-$DEFAULT_HOSTS_FILE}"
fi

if ! command -v jq &> /dev/null; then
  echo "Error: jq is not installed. Install it with 'apt install jq' or 'brew install jq'." >&2
  exit 1
fi

if [ ! -f "$HOSTS_FILE" ]; then
  echo "Error: inventory file not found: $HOSTS_FILE" >&2
  exit 1
fi

echo "Reading Terraform outputs in: $TERRAFORM_DIR"
MASTERS_JSON=$(terraform -chdir="$TERRAFORM_DIR" output -json masters)

# Retrieve the public IPs sorted by key (master-1, master-2, master-3)
MASTER1_IP=$(echo "$MASTERS_JSON" | jq -r '.["master-1"].public_ip')
MASTER2_IP=$(echo "$MASTERS_JSON" | jq -r '.["master-2"].public_ip')
MASTER3_IP=$(echo "$MASTERS_JSON" | jq -r '.["master-3"].public_ip')

for name in MASTER1_IP MASTER2_IP MASTER3_IP; do
  val="${!name}"
  if [ -z "$val" ] || [ "$val" == "null" ]; then
    echo "Error: unable to retrieve $name from 'terraform output masters'." >&2
    echo "Check that 'terraform apply' has been run and that the 'masters' output exists." >&2
    exit 1
  fi
done

echo "master1 -> $MASTER1_IP"
echo "master2 -> $MASTER2_IP"
echo "master3 -> $MASTER3_IP"

# Backup before modification
cp "$HOSTS_FILE" "${HOSTS_FILE}.bak"
echo "Backup created: ${HOSTS_FILE}.bak"

# Replace the placeholders (all occurrences, including the one
# in the ProxyJump of [worker:vars])
sed -i.tmp \
  -e "s/<MASTER1_PUBLIC_IP>/${MASTER1_IP}/g" \
  -e "s/<MASTER2_PUBLIC_IP>/${MASTER2_IP}/g" \
  -e "s/<MASTER3_PUBLIC_IP>/${MASTER3_IP}/g" \
  "$HOSTS_FILE"
rm -f "${HOSTS_FILE}.tmp"

echo "Inventory updated: $HOSTS_FILE"
