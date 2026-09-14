#!/usr/bin/env bash
# The bastion only accepts SSH from `admin_cidr` (a /32). When your public IP
# changes (new network, ISP re-assignment) `ssh management` times out. This
# rewrites admin_cidr in terraform/envs/dev.tfvars to your current IP and
# applies just the security-group rule (in-place, nothing is rebuilt).
#
# Usage: scripts/update-admin-cidr.sh [ip-or-cidr]   (default: detect via checkip.amazonaws.com)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="${TFVARS:-$REPO_ROOT/terraform/envs/dev.tfvars}"

command -v terraform >/dev/null || { echo "terraform not found" >&2; exit 1; }
[ -f "$TFVARS" ] || { echo "$TFVARS not found" >&2; exit 1; }

cidr="${1:-$(curl -fsS https://checkip.amazonaws.com)}"
[[ "$cidr" == */* ]] || cidr="$cidr/32"
[[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || { echo "not an IPv4 CIDR: $cidr" >&2; exit 1; }

current="$(sed -n 's/^admin_cidr[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$TFVARS")"
if [ "$current" = "$cidr" ]; then
  echo "admin_cidr is already $cidr; nothing to do"
  exit 0
fi

sed -i "s#^admin_cidr[[:space:]]*=.*#admin_cidr       = \"$cidr\"#" "$TFVARS"
echo "admin_cidr: $current -> $cidr"

cd "$REPO_ROOT/terraform"
# Every rule keyed on admin_cidr: SSH + Jenkins on management, Grafana +
# Prometheus on the ALB.
terraform apply -input=false -auto-approve -var-file="$TFVARS" \
  -target=module.security.aws_vpc_security_group_ingress_rule.management_ssh \
  -target=module.security.aws_vpc_security_group_ingress_rule.management_jenkins \
  -target=module.security.aws_vpc_security_group_ingress_rule.alb_admin
echo "done — SSH, Jenkins, Grafana and Prometheus admit $cidr again"
