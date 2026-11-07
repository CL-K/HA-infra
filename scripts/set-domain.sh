#!/bin/bash
# ============================================================
# set-domain.sh
#
# Replaces the placeholder domain "domain.com" with the domain
# given as a parameter in all the project files that
# use it (Ansible playbooks + README).
#
# Files concerned:
#   - ansible/playbooks/install-argocd.yml       (argocd_hostname)
#   - ansible/playbooks/install-monitoring.yml   (Grafana Ingress host)
#   - ansible/playbooks/guestbook.yml            (argocd_hostname)
#   - ansible/playbooks/install-cert-manager.yml (default email, docs)
#   - ansible/site.yml                            (doc comment)
#   - README.md                                   (docs)
#
# Usage (from any folder, the script locates itself):
#   ./scripts/set-domain.sh mydomain.com
#
# A .bak backup is created next to each modified file.
# ============================================================
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <domain>" >&2
  echo "Example: $0 mydomain.com" >&2
  exit 1
fi

NEW_DOMAIN="$1"
OLD_DOMAIN="domain.com"

# Simple domain format validation (label.label...)
if ! [[ "$NEW_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
  echo "Error: '$NEW_DOMAIN' does not look like a valid domain (e.g. mydomain.com)." >&2
  exit 1
fi

# The script lives in scripts/, the project root is the parent folder
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FILES=(
  "$PROJECT_ROOT/ansible/playbooks/install-argocd.yml"
  "$PROJECT_ROOT/ansible/playbooks/install-monitoring.yml"
  "$PROJECT_ROOT/ansible/playbooks/guestbook.yml"
  "$PROJECT_ROOT/ansible/playbooks/install-cert-manager.yml"
  "$PROJECT_ROOT/ansible/site.yml"
  "$PROJECT_ROOT/README.md"
)

echo "Target domain: $NEW_DOMAIN (replaces '$OLD_DOMAIN')"
echo

CHANGED=0
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "Warning: file not found, skipped: $f" >&2
    continue
  fi

  if ! grep -q "$OLD_DOMAIN" "$f"; then
    echo "  (nothing to replace in ${f#$PROJECT_ROOT/})"
    continue
  fi

  cp "$f" "${f}.bak"
  sed -i.tmp "s/${OLD_DOMAIN}/${NEW_DOMAIN}/g" "$f"
  rm -f "${f}.tmp"
  echo "  modified: ${f#$PROJECT_ROOT/}  (backup: ${f#$PROJECT_ROOT/}.bak)"
  CHANGED=$((CHANGED + 1))
done

echo
if [ "$CHANGED" -eq 0 ]; then
  echo "No files modified (already up to date, or placeholder '$OLD_DOMAIN' absent)."
else
  echo "$CHANGED file(s) updated with the domain '$NEW_DOMAIN'."
  echo
  echo "Next step: point the following DNS records to the public IP of"
  echo "master1 (terraform output master1_public_ip) before running"
  echo "the cert-manager step:"
  echo "  - argocd.${NEW_DOMAIN}"
  echo "  - monitoring.${NEW_DOMAIN}"
fi
