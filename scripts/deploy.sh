#!/usr/bin/env bash
# deploy.sh <prod|staging> <tag>
#
# Lives at /opt/todo/deploy.sh on the backend host (installed by
# scripts/bootstrap/backend.sh) and is invoked by Jenkins through
# `aws ssm send-command` (scripts/ssm-deploy.sh), or by hand for a rollback:
#     sudo /opt/todo/deploy.sh prod <previous-tag>
#
# Contract (see docs/CONTRACTS.md, "Deploy contract"):
#   - pulls $DOCKERHUB_REPO:<tag>
#   - replaces container todo-<env>; prod -> host port 3000, staging -> 3001,
#     container port 3000
#   - env: PORT=3000 APP_ENV=<env> APP_VERSION=<tag> DATABASE_URL=postgres://...
#   - --restart unless-stopped, label env=<env>, json-file logs 10m x 3
#   - waits for http://127.0.0.1:<port>/health == 200 within 60 s, else exit 1
#
# Configuration is read fresh on every run: /etc/8byte/env for DOCKERHUB_REPO,
# AWS_REGION, DB_SECRET_ID; Secrets Manager (8byte/db) for the DB credentials.
# Nothing secret is written to disk.
set -euo pipefail

ENV_NAME="${1:-}"
TAG="${2:-}"
if [[ -z "$ENV_NAME" || -z "$TAG" ]]; then
  echo "usage: $0 <prod|staging> <tag>" >&2
  exit 2
fi

case "$ENV_NAME" in
  prod)    HOST_PORT=3000 ;;
  staging) HOST_PORT=3001 ;;
  *) echo "error: env must be prod or staging (got '$ENV_NAME')" >&2; exit 2 ;;
esac

ENV_FILE="${TODO_ENV_FILE:-/etc/8byte/env}"   # override only for local testing
[[ -r "$ENV_FILE" ]] || { echo "error: $ENV_FILE not readable (run as root)" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${DOCKERHUB_REPO:?DOCKERHUB_REPO missing from $ENV_FILE}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
DB_SECRET_ID="${DB_SECRET_ID:-8byte/db}"
# The app image bundles the RDS CA, so full verification (require) is the
# default; DB_SSLMODE in /etc/8byte/env overrides it.
DB_SSLMODE="${DB_SSLMODE:-require}"

CONTAINER="todo-$ENV_NAME"
IMAGE="$DOCKERHUB_REPO:$TAG"
HEALTH_URL="http://127.0.0.1:$HOST_PORT/health"
HEALTH_TIMEOUT=60

log() { printf '[deploy %s] %s\n' "$ENV_NAME" "$*"; }

# --- DB credentials -> DATABASE_URL --------------------------------------------
log "reading $DB_SECRET_ID from Secrets Manager ($AWS_REGION)"
SECRET_JSON="$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "$DB_SECRET_ID" --query SecretString --output text)"

DB_HOST="$(jq -r '.host' <<<"$SECRET_JSON")"
DB_PORT="$(jq -r '.port // 5432' <<<"$SECRET_JSON")"
DB_USER="$(jq -r '.username' <<<"$SECRET_JSON")"
DB_PASS="$(jq -r '.password' <<<"$SECRET_JSON")"
DB_NAME="$(jq -r ".dbname_${ENV_NAME} // \"todo_${ENV_NAME}\"" <<<"$SECRET_JSON")"
for v in DB_HOST DB_USER DB_PASS; do
  [[ -n "${!v}" && "${!v}" != "null" ]] || { echo "error: $v missing in secret $DB_SECRET_ID" >&2; exit 1; }
done
# percent-encode user/password so a generated password with '@', '/', '#', ... is safe in a URL
DB_USER_ENC="$(jq -rn --arg v "$DB_USER" '$v|@uri')"
DB_PASS_ENC="$(jq -rn --arg v "$DB_PASS" '$v|@uri')"
DATABASE_URL="postgres://${DB_USER_ENC}:${DB_PASS_ENC}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=${DB_SSLMODE}"
log "database: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME} (sslmode=${DB_SSLMODE})"

# --- pull ---------------------------------------------------------------------
log "pulling $IMAGE"
docker pull "$IMAGE"

# --- replace container --------------------------------------------------------
PREVIOUS_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"
if [[ -n "$PREVIOUS_IMAGE" ]]; then
  log "previous image: $PREVIOUS_IMAGE  (rollback: $0 $ENV_NAME ${PREVIOUS_IMAGE##*:})"
  docker rm -f "$CONTAINER" >/dev/null
else
  log "no existing $CONTAINER container"
fi

log "starting $CONTAINER from $IMAGE on host port $HOST_PORT"
docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --label "env=$ENV_NAME" \
  --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
  -p "${HOST_PORT}:3000" \
  -e PORT=3000 \
  -e "APP_ENV=$ENV_NAME" \
  -e "APP_VERSION=$TAG" \
  -e "DATABASE_URL=$DATABASE_URL" \
  "$IMAGE" >/dev/null

# --- health wait --------------------------------------------------------------
HEALTH_BODY="$(mktemp)"
trap 'rm -f "$HEALTH_BODY"' EXIT
log "waiting up to ${HEALTH_TIMEOUT}s for $HEALTH_URL"
SECONDS=0   # bash wall clock: curl time-outs and sleeps both count against the budget
while (( SECONDS < HEALTH_TIMEOUT )); do
  code="$(curl -s -o "$HEALTH_BODY" -w '%{http_code}' --max-time 3 "$HEALTH_URL" 2>/dev/null)" || true
  code="${code:-000}"
  if [[ "$code" == "200" ]]; then
    log "healthy after ${SECONDS}s: $(cat "$HEALTH_BODY")"
    log "deployed $IMAGE as $CONTAINER"
    exit 0
  fi
  if ! docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    log "container exited early"
    break
  fi
  sleep 2
done

echo "[deploy $ENV_NAME] ERROR: $CONTAINER did not become healthy within ${HEALTH_TIMEOUT}s (last /health: ${code:-none})" >&2
echo "----- last 50 log lines of $CONTAINER -----" >&2
docker logs --tail 50 "$CONTAINER" >&2 2>&1 || true
if [[ -n "$PREVIOUS_IMAGE" ]]; then
  echo "[deploy $ENV_NAME] rollback hint: $0 $ENV_NAME ${PREVIOUS_IMAGE##*:}" >&2
fi
exit 1
