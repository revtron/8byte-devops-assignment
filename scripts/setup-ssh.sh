#!/usr/bin/env bash
# Installs the 8byte SSH config block into ~/.ssh/config and shell aliases
# (management / backend / mon) into ~/.bashrc. Safe to re-run: the managed
# blocks are replaced, not duplicated.
#
# Usage: scripts/setup-ssh.sh            (from the repo root)
# Requires: terraform on PATH, an applied terraform/ root, key at ~/.ssh/8byte.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BEGIN='# BEGIN 8byte'
END='# END 8byte'
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
RC_FILE="${EIGHTBYTE_RC_FILE:-$HOME/.bashrc}"

# replace_block <file> <content>: swap (or append) the BEGIN..END block.
# Trailing blank lines of the existing content are dropped so re-runs do not
# accumulate whitespace.
replace_block() {
  local file="$1" content="$2" tmp
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    awk -v b="$BEGIN" -v e="$END" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      skip { next }
      /^[[:space:]]*$/ { blanks = blanks $0 "\n"; next }
      { printf "%s", blanks; blanks = ""; print }
    ' "$file" > "$tmp"
  fi
  [ -s "$tmp" ] && printf '\n' >> "$tmp"
  printf '%s\n%s\n%s\n' "$BEGIN" "$content" "$END" >> "$tmp"
  cat "$tmp" > "$file" && rm -f "$tmp"
}

echo "Reading ssh_config output from terraform/ ..."
ssh_block="$(cd "$REPO_ROOT/terraform" && terraform output -raw ssh_config)"
[ -n "$ssh_block" ] || { echo "terraform output ssh_config is empty" >&2; exit 1; }

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
[ -f "$SSH_CONFIG" ] || : > "$SSH_CONFIG"
replace_block "$SSH_CONFIG" "$ssh_block"
chmod 600 "$SSH_CONFIG"
echo "Updated $SSH_CONFIG"

aliases="alias management='ssh management'
alias backend='ssh backend'
alias mon='ssh mon'"
[ -f "$RC_FILE" ] || : > "$RC_FILE"
replace_block "$RC_FILE" "$aliases"
echo "Updated $RC_FILE (aliases: management, backend, mon)"

if [ ! -f "$SSH_DIR/8byte" ]; then
  echo "NOTE: private key $SSH_DIR/8byte not found; put the key matching admin_public_key there." >&2
fi
echo "Done. Open a new shell (or 'source $RC_FILE') and run: management"
