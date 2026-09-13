#!/usr/bin/env bash
# ssm-deploy.sh <prod|staging> <tag>
#
# Runs from Jenkins on the management host. Triggers /opt/todo/deploy.sh on the
# backend instance through SSM Run Command (no SSH keys in Jenkins; the
# management instance role is allowed ssm:SendCommand on the backend instance
# only) and waits for the result.
#
# Required environment: BACKEND_INSTANCE_ID, AWS_REGION (both injected by JCasC
# as global env vars; can also be exported by hand for a manual run).
set -euo pipefail

ENV_NAME="${1:-}"
TAG="${2:-}"

if [[ -z "$ENV_NAME" || -z "$TAG" ]]; then
  echo "usage: $0 <prod|staging> <tag>" >&2
  exit 2
fi
case "$ENV_NAME" in
  prod|staging) ;;
  *) echo "error: env must be prod or staging (got '$ENV_NAME')" >&2; exit 2 ;;
esac
: "${BACKEND_INSTANCE_ID:?BACKEND_INSTANCE_ID is not set}"
: "${AWS_REGION:?AWS_REGION is not set}"

POLL_SECONDS=5
MAX_SECONDS=600   # 10 minutes, generous: image pull + 60 s health wait

echo "==> deploy $ENV_NAME $TAG on $BACKEND_INSTANCE_ID ($AWS_REGION)"
COMMAND_ID="$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$BACKEND_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "deploy $ENV_NAME $TAG" \
  --timeout-seconds "$MAX_SECONDS" \
  --parameters "commands=[\"/opt/todo/deploy.sh $ENV_NAME $TAG\"]" \
  --query Command.CommandId --output text)"
echo "==> command id: $COMMAND_ID"

STATUS="Pending"
ELAPSED=0
while :; do
  # get-command-invocation can return InvocationDoesNotExist for a second or
  # two right after send-command; treat that as still pending.
  if OUT="$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$BACKEND_INSTANCE_ID" \
        --query '{Status:Status,Out:StandardOutputContent,Err:StandardErrorContent}' \
        --output json 2>/dev/null)"; then
    STATUS="$(printf '%s' "$OUT" | jq -r .Status)"
  else
    STATUS="Pending"
  fi

  case "$STATUS" in
    Pending|InProgress|Delayed) ;;
    *) break ;;
  esac

  if (( ELAPSED >= MAX_SECONDS )); then
    echo "error: timed out after ${MAX_SECONDS}s waiting for SSM command $COMMAND_ID (last status: $STATUS)" >&2
    aws ssm cancel-command --region "$AWS_REGION" --command-id "$COMMAND_ID" >/dev/null 2>&1 || true
    exit 1
  fi
  sleep "$POLL_SECONDS"
  ELAPSED=$(( ELAPSED + POLL_SECONDS ))
done

echo "==> status: $STATUS (after ~${ELAPSED}s)"
echo "----- StandardOutputContent -----"
printf '%s\n' "$OUT" | jq -r '.Out // ""'
echo "----- StandardErrorContent -----"
printf '%s\n' "$OUT" | jq -r '.Err // ""'
echo "---------------------------------"

if [[ "$STATUS" != "Success" ]]; then
  echo "error: deploy $ENV_NAME $TAG failed with SSM status '$STATUS'" >&2
  exit 1
fi
echo "==> deploy $ENV_NAME $TAG succeeded"
