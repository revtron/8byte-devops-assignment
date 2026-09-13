# Jenkins (Part 2 — CI/CD)

Jenkins LTS runs on the **management** host and is configured entirely from
this directory. There is no click-ops: if it is not in `jenkins.yaml`,
`plugins.txt` or the root `Jenkinsfile`, it does not exist.

| File | Purpose |
|---|---|
| `jenkins.yaml` | JCasC: admin user, authorization, global env vars, credentials, the `todo` multibranch job (Job DSL) |
| `plugins.txt` | plugin list installed with `jenkins-plugin-cli` at bootstrap |
| `../Jenkinsfile` | the pipeline (14 stages, see below) |
| `../scripts/bootstrap/management.sh` | installs Java 17, Jenkins, Node 20, Trivy, plugins; writes JCasC + systemd env; starts Jenkins |
| `../scripts/ssm-deploy.sh` | used by the pipeline: SSM Run Command to the backend + wait |
| `../scripts/deploy.sh` | runs **on the backend** as `/opt/todo/deploy.sh <env> <tag>` |
| `../scripts/smoke-test.sh` | post-deploy health + CRUD check against the ALB |

## How Jenkins is configured (JCasC)

1. Terraform user-data clones the repo to `/opt/8byte/repo` and runs
   `scripts/bootstrap/management.sh`.
2. The script installs the packages, then `jenkins-plugin-cli --plugin-file
   jenkins/plugins.txt --war /usr/share/java/jenkins.war` into
   `/var/lib/jenkins/plugins`.
3. `jenkins/jenkins.yaml` is copied to `/var/lib/jenkins/casc/jenkins.yaml`.
4. Secrets are read from AWS Secrets Manager with the instance role
   (`8byte/jenkins` → admin password, `8byte/dockerhub` → registry
   credentials, `8byte/github` → PAT) and, together with the values from
   `/etc/8byte/env` (`DOCKERHUB_REPO`, `BACKEND_INSTANCE_ID`, `SNS_TOPIC_ARN`,
   `ALB_DNS`, `AWS_REGION`, `GITHUB_REPO` split into `GITHUB_OWNER` /
   `GITHUB_REPO_NAME`), written as `Environment=` lines into
   `/etc/systemd/system/jenkins.service.d/override.conf` (mode 0600). The same
   drop-in sets `CASC_JENKINS_CONFIG` and disables the setup wizard.
5. `systemctl enable --now jenkins`. On boot JCasC resolves every `${VAR}` in
   `jenkins.yaml` from that environment. Nothing secret is in git or in the
   YAML on disk.

What `jenkins.yaml` defines:

- local security realm with one user `admin`; authorization "logged-in users
  can do anything", anonymous read off;
- 2 executors on the controller (single-node demo — builds run on the
  controller, which has Docker, Node 20, Trivy and the AWS CLI);
- global environment variables consumed by the `Jenkinsfile`;
- credentials `dockerhub` (username/password → Docker Hub token) and
  `github-token` (username = repo owner, password = PAT);
- the `todo` multibranch pipeline job (Job DSL).

To change anything: edit the file in git, then on the box re-run the
bootstrap script (`sudo bash /opt/8byte/repo/scripts/bootstrap/management.sh`
after `git -C /opt/8byte/repo pull`) or copy the file and use
*Manage Jenkins → Configuration as Code → Reload*.

## Logging in

Jenkins listens on `127.0.0.1:8080` only; the management security group
allows nothing but SSH from your IP. Use the tunnel that
`scripts/setup-ssh.*` configures (`LocalForward 8080 localhost:8080`):

```
management            # alias for: ssh management
# then open http://localhost:8080
```

User: `admin`. Password:

```
aws secretsmanager get-secret-value --secret-id 8byte/jenkins \
  --query SecretString --output text | jq -r .admin_password
```

## How the multibranch job picks up pushes

- The job scans `github.com/<owner>/<repo>` every **1 minute**
  (`periodicFolderTrigger { interval('1m') }`) using the `github-token`
  credential. New branches and PRs get their own sub-job; deleted ones are
  pruned (last 10 kept). Origin branches and PR merge heads are built; fork
  PRs are not (untrusted code would run on the controller).
- A push therefore starts a build within ~60 s. The GitHub Branch Source
  plugin reports the result back as a **commit status** (pending → success /
  failure) on the commit and the PR, using the same PAT. The PAT needs the
  `repo` scope (private repo) or `public_repo` + `repo:status`.
- No inbound webhook is configured on purpose: Jenkins has no public
  endpoint. See "Webhook upgrade path" below.

## Pipeline

Stages (spec §6.2): Checkout → Install & Lint → Unit tests → Integration
tests (throw-away `postgres:16-alpine` sidecar) → Dependency scan (`npm
audit`, advisory; `trivy fs` HIGH/CRITICAL gate) → Terraform check (only
when `terraform/**` changed) → then on `main` only: Build image → Image scan
(`trivy image`, CRITICAL gate) → Push image (`<sha>` + `latest`) → Deploy
staging → Smoke test staging → **Approve production** → Deploy production →
Smoke test production.

Deploys go through SSM Run Command (`scripts/ssm-deploy.sh`), which runs
`/opt/todo/deploy.sh <env> <sha>` on the backend host; the same image tag is
promoted from staging to prod, never rebuilt. `deploy.sh` prints the
previously running tag so a rollback is `sudo /opt/todo/deploy.sh prod
<previous-tag>` from the backend box (or a re-run of an older build's deploy
via SSM).

On failure the pipeline publishes to the SNS topic (`Jenkins FAILED: <job>
#<n>` with the build URL and the failing stage; the topic's email
subscription delivers it). Trivy reports are archived on every build; JUnit
results are recorded after the unit and integration stages.

### The approval step

`Approve production` is a declarative `input` stage: the build pauses with
"Promote `<sha>` to production?" and a **Deploy** button. Anyone logged in
can approve (authorization strategy is deliberately simple). The prompt
times out after 30 minutes and the build is then marked aborted — nothing
reaches prod without a click. While waiting, the stage holds an executor;
with two executors and one job this is acceptable for the demo.

## Webhook upgrade path

Polling every minute costs one GitHub API call per minute and adds up to 60 s
latency. To move to push-driven builds:

1. Give Jenkins an HTTPS endpoint reachable by GitHub — either a public
   listener on the ALB (`/github-webhook/` only, behind an allow-list of
   GitHub's IP ranges) or a small relay (e.g. an API Gateway + Lambda that
   forwards to the private endpoint, or a GitHub App with Jenkins' `github`
   plugin).
2. Set `unclassified.location.url` in `jenkins.yaml` to that public URL and
   let the GitHub plugin register the hook (`unclassified.gitHubPluginConfig`
   with *manage hooks* on), or create the repo webhook manually pointing at
   `https://<jenkins>/github-webhook/`.
3. Keep the periodic scan as a safety net but raise the interval (e.g. `1h`).

## Things to know

- Builds run on the controller (`agent any`, single node). Integration
  tests use container name/port derived from `EXECUTOR_NUMBER`, so two
  branches building at once do not collide.
- `npm audit` is non-blocking by design; `trivy fs` on the lockfile is the
  gate. Both outputs are in the build log; Trivy reports are archived.
- The Terraform stage runs `hashicorp/terraform:1.9` in Docker and is skipped
  on a branch's first build (empty change set).
- Plugins are installed as `latest` against the installed LTS update centre;
  pin versions in `plugins.txt` once a known-good set is established.
