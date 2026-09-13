#!/usr/bin/env bash
# Install node_exporter as a systemd service on an Amazon Linux 2023 host.
# Shared helper: called by scripts/bootstrap/backend.sh and scripts/bootstrap/mon.sh.
# No arguments. Reads /etc/8byte/env (for logging only). Idempotent.
set -euo pipefail

NODE_EXPORTER_VERSION="1.8.2"
ARCH="linux-amd64"
BIN="/usr/local/bin/node_exporter"
UNIT="/etc/systemd/system/node_exporter.service"
TARBALL="node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz"
URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${TARBALL}"

log() { echo "[install-node-exporter] $(date -u +%FT%TZ) $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "must run as root" >&2
  exit 1
fi

# shellcheck disable=SC1091
[[ -f /etc/8byte/env ]] && source /etc/8byte/env
log "role=${ROLE:-unknown} version=${NODE_EXPORTER_VERSION}"

# --- user -------------------------------------------------------------------
if ! id -u node_exporter >/dev/null 2>&1; then
  log "creating system user node_exporter"
  useradd --system --no-create-home --shell /sbin/nologin node_exporter
fi

# --- binary -----------------------------------------------------------------
installed_version=""
if [[ -x "$BIN" ]]; then
  installed_version="$("$BIN" --version 2>&1 | awk '/^node_exporter, version/ {print $3}' || true)"
fi
if [[ "$installed_version" == "$NODE_EXPORTER_VERSION" ]]; then
  log "node_exporter ${NODE_EXPORTER_VERSION} already installed"
else
  log "downloading ${URL}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 5 --retry-delay 3 -o "${tmp}/${TARBALL}" "$URL"
  tar -xzf "${tmp}/${TARBALL}" -C "$tmp"
  install -m 0755 -o root -g root "${tmp}/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" "$BIN"
  log "installed ${BIN}"
fi

# --- systemd unit -----------------------------------------------------------
unit_content="$(cat <<UNIT
[Unit]
Description=Prometheus node_exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=${BIN} \\
  --web.listen-address=:9100 \\
  --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker/.+)(\$|/) \\
  --collector.netclass.ignored-devices=^(veth.*|br-.*|docker.*)\$ \\
  --collector.netdev.device-exclude=^(veth.*|br-.*|docker.*)\$
Restart=always
RestartSec=5
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
)"

changed=0
if [[ ! -f "$UNIT" ]] || [[ "$(cat "$UNIT")" != "$unit_content" ]]; then
  log "writing ${UNIT}"
  printf '%s\n' "$unit_content" > "$UNIT"
  changed=1
fi

systemctl daemon-reload
systemctl enable node_exporter >/dev/null 2>&1
if [[ $changed -eq 1 ]] || [[ "$installed_version" != "$NODE_EXPORTER_VERSION" ]] || ! systemctl is-active --quiet node_exporter; then
  log "(re)starting node_exporter"
  systemctl restart node_exporter
else
  log "node_exporter already running; nothing to do"
fi

# --- verify -----------------------------------------------------------------
for _ in $(seq 1 10); do
  if curl -fsS -o /dev/null http://127.0.0.1:9100/metrics; then
    log "node_exporter is serving metrics on :9100"
    exit 0
  fi
  sleep 1
done
log "ERROR: node_exporter did not respond on :9100"
systemctl status node_exporter --no-pager || true
exit 1
