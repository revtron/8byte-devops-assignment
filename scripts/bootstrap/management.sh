#!/usr/bin/env bash
# Management host bootstrap (Amazon Linux 2023): Jenkins LTS configured by JCasC.
#
# Called by the Terraform user-data after the generic part (role user, docker,
# git, jq, awscli, /etc/8byte/env, repo clone to /opt/8byte/repo). Idempotent —
# re-run to pick up a new jenkins/jenkins.yaml or jenkins/plugins.txt:
#     sudo bash /opt/8byte/repo/scripts/bootstrap/management.sh
#
# Installs: Java 17 (Corretto), Jenkins LTS, Node 20, Trivy, Jenkins plugins;
# writes the JCasC file and a systemd override that exports the secrets and
# environment JCasC references; starts Jenkins on 127.0.0.1:8080 (reach it via
# the SSH tunnel: `ssh management` forwards 8080).
set -euo pipefail

log() { printf '[bootstrap management] %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

ENV_FILE=/etc/8byte/env
[[ -r "$ENV_FILE" ]] || { echo "error: $ENV_FILE missing" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

REPO_DIR=/opt/8byte/repo
JENKINS_HOME=/var/lib/jenkins
JENKINS_WAR=/usr/share/java/jenkins.war
CASC_DIR="$JENKINS_HOME/casc"
PLUGIN_MANAGER_JAR=/opt/8byte/jenkins-plugin-manager.jar
PLUGIN_MANAGER_FALLBACK_VERSION=2.13.2

AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
for v in GITHUB_REPO DOCKERHUB_REPO BACKEND_INSTANCE_ID SNS_TOPIC_ARN ALB_DNS; do
  [[ -n "${!v:-}" ]] || { echo "error: $v missing from $ENV_FILE" >&2; exit 1; }
done
DOCKERHUB_SECRET_ID="${DOCKERHUB_SECRET_ID:-8byte/dockerhub}"
GITHUB_SECRET_ID="${GITHUB_SECRET_ID:-8byte/github}"
JENKINS_SECRET_ID="${JENKINS_SECRET_ID:-8byte/jenkins}"

# owner/repo -> owner, repo (JCasC job DSL needs them separately)
GITHUB_OWNER="${GITHUB_REPO%%/*}"
GITHUB_REPO_NAME="${GITHUB_REPO#*/}"
GITHUB_REPO_NAME="${GITHUB_REPO_NAME%.git}"

# --- Java 17 --------------------------------------------------------------------
if ! rpm -q java-17-amazon-corretto-headless >/dev/null 2>&1; then
  log "installing Java 17 (Corretto)"
  dnf install -y -q java-17-amazon-corretto-headless fontconfig
fi

# --- Jenkins LTS ----------------------------------------------------------------
if [[ ! -f /etc/yum.repos.d/jenkins.repo ]]; then
  log "adding Jenkins LTS repo"
  curl -fsSL -o /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
  rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
fi
if ! rpm -q jenkins >/dev/null 2>&1; then
  log "installing Jenkins LTS"
  dnf install -y -q jenkins
fi
log "jenkins $(rpm -q --qf '%{VERSION}' jenkins) installed"

# --- Node 20 (AL2023 native package) --------------------------------------------
# nodejs20 ships /usr/bin/node-20 (+ npm-20, npx-20); wire them up as the
# default `node`/`npm`/`npx` through alternatives.
if ! (command -v node >/dev/null 2>&1 && node --version | grep -q '^v20\.'); then
  log "installing Node 20"
  dnf install -y -q nodejs20
  dnf install -y -q nodejs20-npm >/dev/null 2>&1 || true   # subpackage name differs across releases
  for tool in node npm npx; do
    if [[ -x "/usr/bin/${tool}-20" ]]; then
      alternatives --install "/usr/bin/${tool}" "$tool" "/usr/bin/${tool}-20" 20 >/dev/null 2>&1 || true
      alternatives --set "$tool" "/usr/bin/${tool}-20" >/dev/null 2>&1 \
        || ln -sfn "/usr/bin/${tool}-20" "/usr/bin/${tool}"
    fi
  done
  node --version | grep -q '^v20\.' || { echo "error: node 20 not on PATH after install" >&2; exit 1; }
  command -v npm >/dev/null 2>&1 || { echo "error: npm not on PATH after install" >&2; exit 1; }
fi
log "node $(node --version), npm $(npm --version)"

# --- Trivy ------------------------------------------------------------------------
# The Trivy repo has no AL2023 path; the EL9 build works, so pin releasever=9.
if [[ ! -f /etc/yum.repos.d/trivy.repo ]]; then
  log "adding Trivy repo (EL9 build)"
  cat > /etc/yum.repos.d/trivy.repo <<'EOF'
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/9/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://aquasecurity.github.io/trivy-repo/rpm/public.key
EOF
fi
if ! command -v trivy >/dev/null 2>&1; then
  log "installing Trivy"
  dnf install -y -q trivy
fi
log "trivy $(trivy --version | head -1)"

# --- jenkins user: docker access --------------------------------------------------
if ! id -nG jenkins | tr ' ' '\n' | grep -qx docker; then
  log "adding jenkins to the docker group"
  usermod -aG docker jenkins
fi

# --- plugins (Plugin Installation Manager Tool = jenkins-plugin-cli) ----------------
install -d -m 0755 /opt/8byte
if [[ ! -f "$PLUGIN_MANAGER_JAR" ]]; then
  log "downloading jenkins-plugin-manager"
  url="$(curl -fsSL https://api.github.com/repos/jenkinsci/plugin-installation-manager-tool/releases/latest \
        | jq -r '.assets[] | select(.name | test("^jenkins-plugin-manager-.*\\.jar$")) | .browser_download_url' \
        | head -1 || true)"
  if [[ -z "$url" ]]; then
    url="https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${PLUGIN_MANAGER_FALLBACK_VERSION}/jenkins-plugin-manager-${PLUGIN_MANAGER_FALLBACK_VERSION}.jar"
  fi
  curl -fsSL -o "$PLUGIN_MANAGER_JAR" "$url"
fi
cat > /usr/local/bin/jenkins-plugin-cli <<EOF
#!/usr/bin/env bash
exec java -jar "$PLUGIN_MANAGER_JAR" "\$@"
EOF
chmod 0755 /usr/local/bin/jenkins-plugin-cli

# Never write into the plugin dir while Jenkins runs (re-run case).
if systemctl is-active --quiet jenkins; then
  log "stopping jenkins to update plugins/config"
  systemctl stop jenkins
fi

install -d -m 0755 -o jenkins -g jenkins "$JENKINS_HOME/plugins"
log "installing plugins from jenkins/plugins.txt"
jenkins-plugin-cli \
  --plugin-file "$REPO_DIR/jenkins/plugins.txt" \
  --war "$JENKINS_WAR" \
  --plugin-download-directory "$JENKINS_HOME/plugins" \
  --verbose
chown -R jenkins:jenkins "$JENKINS_HOME/plugins"

# --- JCasC file -----------------------------------------------------------------------
install -d -m 0750 -o jenkins -g jenkins "$CASC_DIR"
install -m 0640 -o jenkins -g jenkins "$REPO_DIR/jenkins/jenkins.yaml" "$CASC_DIR/jenkins.yaml"
log "installed $CASC_DIR/jenkins.yaml"

# --- secrets -> systemd environment ------------------------------------------------------
get_secret() { aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$1" --query SecretString --output text; }
log "fetching secrets $DOCKERHUB_SECRET_ID, $GITHUB_SECRET_ID, $JENKINS_SECRET_ID"
DOCKERHUB_JSON="$(get_secret "$DOCKERHUB_SECRET_ID" 2>/dev/null || echo '{}')"
GITHUB_JSON="$(get_secret "$GITHUB_SECRET_ID" 2>/dev/null || echo '{}')"
JENKINS_JSON="$(get_secret "$JENKINS_SECRET_ID")"
DOCKERHUB_USERNAME="$(jq -r '.username // empty' <<<"$DOCKERHUB_JSON")"
DOCKERHUB_TOKEN="$(jq -r '.token // empty' <<<"$DOCKERHUB_JSON")"
GITHUB_TOKEN="$(jq -r '.token // empty' <<<"$GITHUB_JSON")"
JENKINS_ADMIN_PASSWORD="$(jq -r '.admin_password // empty' <<<"$JENKINS_JSON")"
[[ -n "$JENKINS_ADMIN_PASSWORD" ]] || { echo "error: $JENKINS_SECRET_ID has no admin_password (Terraform generates it; re-run the bootstrap)" >&2; exit 1; }
[[ -n "$DOCKERHUB_USERNAME" && -n "$DOCKERHUB_TOKEN" ]] || log "WARNING: $DOCKERHUB_SECRET_ID incomplete — image push will fail until scripts/put-secrets.sh is run, then re-run this bootstrap"
[[ -n "$GITHUB_TOKEN" ]] || log "WARNING: $GITHUB_SECRET_ID has no token — GitHub scanning/commit statuses will be unauthenticated until scripts/put-secrets.sh is run, then re-run this bootstrap"

# systemd Environment= value: quoted, with % (specifier), \ and " escaped.
sd_env() {
  local v="$2" bs='\'
  v="${v//"$bs"/"$bs$bs"}"   # \ -> \\
  v="${v//'%'/%%}"           # % -> %%  (systemd specifier)
  v="${v//'"'/$bs'"'}"       # " -> \"
  printf 'Environment="%s=%s"\n' "$1" "$v"
}

OVERRIDE_DIR=/etc/systemd/system/jenkins.service.d
install -d -m 0755 "$OVERRIDE_DIR"
umask 077
{
  echo "# generated by scripts/bootstrap/management.sh — do not edit, re-run the script"
  echo "[Service]"
  sd_env JAVA_OPTS "-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
  sd_env JENKINS_LISTEN_ADDRESS "127.0.0.1"
  sd_env JENKINS_PORT "8080"
  sd_env CASC_JENKINS_CONFIG "$CASC_DIR/jenkins.yaml"
  sd_env JENKINS_ADMIN_PASSWORD "$JENKINS_ADMIN_PASSWORD"
  sd_env DOCKERHUB_USERNAME "$DOCKERHUB_USERNAME"
  sd_env DOCKERHUB_TOKEN "$DOCKERHUB_TOKEN"
  sd_env GITHUB_OWNER "$GITHUB_OWNER"
  sd_env GITHUB_REPO_NAME "$GITHUB_REPO_NAME"
  sd_env GITHUB_TOKEN "$GITHUB_TOKEN"
  sd_env DOCKERHUB_REPO "$DOCKERHUB_REPO"
  sd_env BACKEND_INSTANCE_ID "$BACKEND_INSTANCE_ID"
  sd_env SNS_TOPIC_ARN "$SNS_TOPIC_ARN"
  sd_env ALB_DNS "$ALB_DNS"
  sd_env AWS_REGION "$AWS_REGION"
} > "$OVERRIDE_DIR/override.conf"
chmod 0600 "$OVERRIDE_DIR/override.conf"
umask 022
log "wrote $OVERRIDE_DIR/override.conf"

# --- start ---------------------------------------------------------------------
systemctl daemon-reload
systemctl enable jenkins
systemctl restart jenkins   # single start; on re-runs this applies the new env/plugins

log "waiting for Jenkins on http://localhost:8080 (up to 5 min)"
for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8080/login || true)"
  if [[ "$code" == "200" || "$code" == "403" ]]; then
    log "Jenkins is up (HTTP $code) after ~$((i * 5))s"
    log "done — tunnel with 'ssh management', open http://localhost:8080, user admin, password from secret $JENKINS_SECRET_ID"
    exit 0
  fi
  sleep 5
done
echo "error: Jenkins did not answer within 5 minutes; see journalctl -u jenkins" >&2
exit 1
