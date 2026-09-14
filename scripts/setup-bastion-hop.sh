#!/usr/bin/env bash
# Enables the classic bastion hop: after `ssh management`, plain `ssh backend`
# and `ssh mon` work from the management host itself.
#
# It copies the admin private key to management (~/.ssh/8byte, mode 600) and
# writes a ~/.ssh/config there with the two private hosts. Re-run after the
# management instance is rebuilt (user-data does not do this on purpose: the
# private key is not something Terraform should carry).
#
# Usage: scripts/setup-bastion-hop.sh            (from the repo root)
# Requires: terraform on PATH, an applied terraform/ root, key at ~/.ssh/8byte
#           (or KEY=path/to/key), laptop-side ssh config from setup-ssh.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${KEY:-$HOME/.ssh/8byte}"
[ -f "$KEY" ] || { echo "private key not found: $KEY" >&2; exit 1; }

cd "$REPO_ROOT/terraform"
backend_ip="$(terraform output -raw backend_private_ip)"
mon_ip="$(terraform output -raw mon_private_ip)"
cd "$REPO_ROOT"

echo "Copying key to management and writing ~/.ssh/config there ..."
ssh management 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
scp -q "$KEY" management:~/.ssh/8byte
ssh management "chmod 600 ~/.ssh/8byte && cat > ~/.ssh/config <<EOF
# written by scripts/setup-bastion-hop.sh
Host backend
  HostName $backend_ip
  User backend
  IdentityFile ~/.ssh/8byte
  StrictHostKeyChecking accept-new

Host mon
  HostName $mon_ip
  User mon
  IdentityFile ~/.ssh/8byte
  StrictHostKeyChecking accept-new
EOF
chmod 600 ~/.ssh/config"

echo "Testing the hop ..."
ssh management 'ssh -o BatchMode=yes backend hostname && ssh -o BatchMode=yes mon hostname'
echo "Done. From management: 'ssh backend' / 'ssh mon'."
