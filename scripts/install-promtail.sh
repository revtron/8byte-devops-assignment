#!/usr/bin/env bash
# Install promtail as a systemd service on an Amazon Linux 2023 host and point
# it at Loki on the mon host. Shared helper: called by scripts/bootstrap/backend.sh
# and scripts/bootstrap/mon.sh. No arguments. Idempotent.
#
# Reads /etc/8byte/env for ROLE and MON_PRIVATE_IP, renders
#   /opt/8byte/repo/monitoring/promtail/promtail-config.yml.tpl
# to /etc/promtail/config.yml with envsubst (HOSTNAME_LABEL = ROLE).
# promtail runs as root: it needs /var/run/docker.sock and /var/log/*.
set -euo pipefail

PROMTAIL_VERSION="3.1.1"
ARCH="linux-amd64"
BIN="/usr/local/bin/promtail"
UNIT="/etc/systemd/system/promtail.service"
CONFIG_DIR="/etc/promtail"
CONFIG="${CONFIG_DIR}/config.yml"
TEMPLATE="/opt/8byte/repo/monitoring/promtail/promtail-config.yml.tpl"
POSITIONS_DIR="/var/lib/promtail"
ZIP="promtail-${ARCH}.zip"
URL="https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/${ZIP}"

log() { echo "[install-promtail] $(date -u +%FT%TZ) $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "must run as root" >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/8byte/env
: "${ROLE:?ROLE missing from /etc/8byte/env}"
: "${MON_PRIVATE_IP:?MON_PRIVATE_IP missing from /etc/8byte/env}"
[[ -f "$TEMPLATE" ]] || { echo "template not found: $TEMPLATE" >&2; exit 1; }
log "role=${ROLE} mon=${MON_PRIVATE_IP} version=${PROMTAIL_VERSION}"

# --- prerequisites (unzip + envsubst from gettext) --------------------------
missing=()
command -v unzip >/dev/null 2>&1 || missing+=(unzip)
command -v envsubst >/dev/null 2>&1 || missing+=(gettext)
if [[ ${#missing[@]} -gt 0 ]]; then
  log "installing ${missing[*]}"
  dnf install -y -q "${missing[@]}"
fi

# --- binary -----------------------------------------------------------------
installed_version=""
if [[ -x "$BIN" ]]; then
  installed_version="$("$BIN" --version 2>&1 | awk '/^promtail, version/ {print $3}' || true)"
fi
if [[ "$installed_version" == "$PROMTAIL_VERSION" ]]; then
  log "promtail ${PROMTAIL_VERSION} already installed"
else
  log "downloading ${URL}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 5 --retry-delay 3 -o "${tmp}/${ZIP}" "$URL"
  unzip -q -o "${tmp}/${ZIP}" -d "$tmp"
  install -m 0755 -o root -g root "${tmp}/promtail-${ARCH}" "$BIN"
  log "installed ${BIN}"
fi

# --- config -----------------------------------------------------------------
mkdir -p "$CONFIG_DIR" "$POSITIONS_DIR"
# Only the two placeholders are substituted; promtail's own {{ }} templates are untouched.
rendered="$(HOSTNAME_LABEL="$ROLE" MON_PRIVATE_IP="$MON_PRIVATE_IP" envsubst '${MON_PRIVATE_IP} ${HOSTNAME_LABEL}' < "$TEMPLATE")"
config_changed=0
if [[ ! -f "$CONFIG" ]] || [[ "$(cat "$CONFIG")" != "$rendered" ]]; then
  log "writing ${CONFIG}"
  printf '%s\n' "$rendered" > "$CONFIG"
  chmod 0640 "$CONFIG"
  config_changed=1
fi

# --- systemd unit -----------------------------------------------------------
unit_content="$(cat <<UNIT
[Unit]
Description=Grafana promtail (ships logs to Loki on mon)
Documentation=https://grafana.com/docs/loki/latest/send-data/promtail/
After=network-online.target docker.service
Wants=network-online.target

[Service]
# root: needs /var/run/docker.sock for docker_sd and /var/log/secure etc.
User=root
Type=simple
ExecStart=${BIN} -config.file=${CONFIG}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
)"

unit_changed=0
if [[ ! -f "$UNIT" ]] || [[ "$(cat "$UNIT")" != "$unit_content" ]]; then
  log "writing ${UNIT}"
  printf '%s\n' "$unit_content" > "$UNIT"
  unit_changed=1
fi

systemctl daemon-reload
systemctl enable promtail >/dev/null 2>&1
if [[ $unit_changed -eq 1 ]] || [[ $config_changed -eq 1 ]] || [[ "$installed_version" != "$PROMTAIL_VERSION" ]] || ! systemctl is-active --quiet promtail; then
  log "(re)starting promtail"
  systemctl restart promtail
else
  log "promtail already running with current config; nothing to do"
fi

# --- verify -----------------------------------------------------------------
for _ in $(seq 1 10); do
  if curl -fsS -o /dev/null http://127.0.0.1:9080/ready; then
    log "promtail is ready on :9080 (pushing to http://${MON_PRIVATE_IP}:3100)"
    exit 0
  fi
  sleep 1
done
log "WARNING: promtail did not report ready on :9080 yet (it keeps retrying Loki in the background)"
systemctl status promtail --no-pager || true
exit 0
