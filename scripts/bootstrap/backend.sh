#!/usr/bin/env bash
# Backend host bootstrap (Amazon Linux 2023). Called by the Terraform user-data
# after the generic part (role user, docker, git, jq, /etc/8byte/env, repo clone
# to /opt/8byte/repo). Idempotent: safe to re-run with
#     sudo bash /opt/8byte/repo/scripts/bootstrap/backend.sh
#
# Does:
#   1. node_exporter + promtail (scripts owned by the monitoring track, called
#      if present)
#   2. psql client
#   3. creates todo_prod / todo_staging on RDS if missing (creds from 8byte/db)
#   4. installs /opt/todo/deploy.sh
#   5. first deploy of prod + staging from :latest (tolerated to fail while
#      the image does not exist yet)
set -euo pipefail

log() { printf '[bootstrap backend] %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

ENV_FILE=/etc/8byte/env
[[ -r "$ENV_FILE" ]] || { echo "error: $ENV_FILE missing" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

REPO_DIR=/opt/8byte/repo
AWS_REGION="${AWS_REGION:-ap-south-1}"
DB_SECRET_ID="${DB_SECRET_ID:-8byte/db}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

# --- 1. monitoring agents (owned by the monitoring track) ----------------------
for agent in install-node-exporter.sh install-promtail.sh; do
  if [[ -f "$REPO_DIR/scripts/$agent" ]]; then
    log "running scripts/$agent"
    bash "$REPO_DIR/scripts/$agent" || log "WARNING: scripts/$agent failed (continuing)"
  else
    log "scripts/$agent not present, skipping"
  fi
done

# --- 2. psql client -----------------------------------------------------------
if ! command -v psql >/dev/null 2>&1; then
  log "installing postgresql16 client"
  dnf install -y -q postgresql16
else
  log "psql already installed: $(psql --version)"
fi

# --- 3. databases -------------------------------------------------------------
log "reading $DB_SECRET_ID"
SECRET_JSON="$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "$DB_SECRET_ID" --query SecretString --output text)"
DB_HOST="$(jq -r '.host' <<<"$SECRET_JSON")"
DB_PORT="$(jq -r '.port // 5432' <<<"$SECRET_JSON")"
DB_USER="$(jq -r '.username' <<<"$SECRET_JSON")"
DB_PASS="$(jq -r '.password' <<<"$SECRET_JSON")"
DB_PROD="$(jq -r '.dbname_prod // "todo_prod"' <<<"$SECRET_JSON")"
DB_STAGING="$(jq -r '.dbname_staging // "todo_staging"' <<<"$SECRET_JSON")"

# Connect to the maintenance DB as the master user to create the app DBs.
# Password goes through PGPASSWORD (never on the command line / in the URL).
export PGPASSWORD="$DB_PASS"
ADMIN_URL="postgres://${DB_USER}@${DB_HOST}:${DB_PORT}/postgres?sslmode=require"

log "waiting for RDS at $DB_HOST:$DB_PORT"
for i in $(seq 1 30); do
  if psql "$ADMIN_URL" -tAc 'SELECT 1' >/dev/null 2>&1; then break; fi
  if [[ "$i" -eq 30 ]]; then echo "error: cannot reach RDS" >&2; exit 1; fi
  sleep 10
done

for db in "$DB_PROD" "$DB_STAGING"; do
  if psql "$ADMIN_URL" -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    log "database $db exists"
  else
    log "creating database $db"
    psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$db\""
  fi
done
unset PGPASSWORD

# --- 4. deploy script ---------------------------------------------------------
install -d -m 0755 /opt/todo
install -m 0755 -o root -g root "$REPO_DIR/scripts/deploy.sh" /opt/todo/deploy.sh
log "installed /opt/todo/deploy.sh"

# --- 5. first deploy ----------------------------------------------------------
# On the very first boot the image usually does not exist on Docker Hub yet
# (Jenkins has not run). deploy.sh fails then; log it and carry on — the first
# Jenkins build deploys via SSM.
for env_name in prod staging; do
  if /opt/todo/deploy.sh "$env_name" latest; then
    log "deployed $env_name from :latest"
  else
    log "WARNING: initial deploy of $env_name failed (image not pushed yet?) — Jenkins will deploy it"
  fi
done

log "done"
