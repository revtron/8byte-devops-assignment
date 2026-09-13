#!/usr/bin/env bash
# Writes the user-supplied secret values into the Secrets Manager containers
# created by Terraform (8byte/dockerhub, 8byte/github, 8byte/jenkins).
# Values come from env vars, or are prompted silently if unset. Nothing is
# echoed. Honours AWS_PROFILE / AWS_REGION like any aws cli call.
#
# Usage:
#   DOCKERHUB_USERNAME=.. DOCKERHUB_TOKEN=.. GITHUB_TOKEN=.. JENKINS_ADMIN_PASSWORD=.. \
#     scripts/put-secrets.sh
#   scripts/put-secrets.sh          # prompts for whatever is missing
set -euo pipefail

PROJECT="${PROJECT:-8byte}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-south-1}}"

command -v aws >/dev/null || { echo "aws cli not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

# prompt_if_unset <VAR> <label> [optional]: silent prompt when the env var is
# unset; empty is rejected unless the third argument is "optional".
prompt_if_unset() {
  local var="$1" label="$2" mode="${3:-required}"
  if [ -z "${!var:-}" ]; then
    read -r -s -p "$label: " "$var"
    printf '\n' >&2
    export "$var"
  fi
  if [ "$mode" != optional ] && [ -z "${!var}" ]; then
    echo "$var must not be empty" >&2
    exit 1
  fi
}

prompt_if_unset DOCKERHUB_USERNAME "Docker Hub username"
prompt_if_unset DOCKERHUB_TOKEN "Docker Hub access token"
prompt_if_unset GITHUB_TOKEN "GitHub PAT (repo scope; leave empty for a public repo)" optional
prompt_if_unset JENKINS_ADMIN_PASSWORD "Jenkins admin password"

# put <secret name> <json>
put() {
  local name="$1" json="$2"
  aws secretsmanager put-secret-value \
    --region "$REGION" \
    --secret-id "$name" \
    --secret-string "$json" \
    --output text --query 'VersionId' >/dev/null
  echo "wrote $name"
}

put "$PROJECT/dockerhub" "$(jq -nc --arg u "$DOCKERHUB_USERNAME" --arg t "$DOCKERHUB_TOKEN" '{username: $u, token: $t}')"
put "$PROJECT/github" "$(jq -nc --arg t "$GITHUB_TOKEN" '{token: $t}')"
put "$PROJECT/jenkins" "$(jq -nc --arg p "$JENKINS_ADMIN_PASSWORD" '{admin_password: $p}')"

echo "All secrets written to Secrets Manager in $REGION (profile: ${AWS_PROFILE:-default})."
