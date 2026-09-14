# 8byte DevOps platform — todo app on AWS

An end-to-end, reproducible platform for a small Node/Express + PostgreSQL todo
application: Terraform-provisioned AWS infrastructure (VPC, EC2, RDS, ALB),
a 14-stage Jenkins pipeline with tests, scans, a staging deploy and a manual
production gate, Prometheus/Grafana/Loki monitoring with alerting to email,
and the documentation, secret management and backup strategy that go with it.
Everything is configured from files in this repository; nothing is set up by
hand in a console.

| Assignment part | What | Where |
|---|---|---|
| 1. Infrastructure | Terraform: VPC, subnets, NAT, 3× EC2, RDS PostgreSQL, ALB, SGs, IAM, Secrets Manager, SNS, remote state | [`terraform/`](terraform/) |
| 2. Deployment automation | Jenkins (JCasC) + declarative `Jenkinsfile`; SSM-driven deploys | [`Jenkinsfile`](Jenkinsfile), [`jenkins/`](jenkins/), [`scripts/`](scripts/) |
| 3. Monitoring & logging | Prometheus, Alertmanager, Grafana, Loki, promtail, node/postgres exporters, 3 dashboards | [`monitoring/`](monitoring/) |
| 4. Documentation | This README, [`docs/APPROACH.md`](docs/APPROACH.md), [`docs/CHALLENGES.md`](docs/CHALLENGES.md); secrets + backups below | [`docs/`](docs/) |
| The application | Express API + static frontend, unit/integration tests, Dockerfile, local compose | [`app/`](app/) |

## Architecture

```mermaid
flowchart LR
  dev[("You<br/>(admin_cidr)")]
  gh[("GitHub repo")]
  hub[("Docker Hub<br/>public image")]
  sns["SNS topic<br/>8byte-alerts → email"]
  sm["Secrets Manager<br/>8byte/db, dockerhub, github, jenkins"]

  subgraph vpc["VPC 10.0.0.0/16 (ap-south-1)"]
    subgraph pub["Public subnets 10.0.0.0/24, 10.0.1.0/24"]
      alb["ALB<br/>:80 → prod, :8080 → staging"]
      mgmt["management (t3.small, EIP)<br/>bastion + Jenkins + Docker + Trivy"]
      nat["NAT gateway"]
    end
    subgraph priv["Private subnets 10.0.10.0/24, 10.0.11.0/24"]
      be["backend (t3.micro) 10.0.10.10<br/>todo-prod :3000, todo-staging :3001<br/>node_exporter, promtail"]
      mon["mon (t3.small) 10.0.10.20<br/>Prometheus, Grafana, Loki,<br/>Alertmanager, postgres_exporter"]
      rds[("RDS PostgreSQL 16<br/>db.t4g.micro, todo_prod + todo_staging")]
    end
  end

  dev -- "SSH 22" --> mgmt
  dev -- "HTTP 80 / 8080" --> alb
  mgmt -- "SSH (ProxyJump)" --> be & mon
  mgmt -- "SSM Run Command" --> be
  alb -- "3000 / 3001" --> be
  be & mon -- "5432" --> rds
  mon -- "scrape 9100/3000/3001" --> be
  be -- "Loki push 3100" --> mon
  be & mon & mgmt -. "via NAT" .-> nat
  mgmt -- "poll every 1 min" --> gh
  mgmt -- "push image" --> hub
  be -- "pull image" --> hub
  mgmt & mon --> sns
  mgmt & be & mon -- "instance role" --> sm
```

| Host | Subnet | Size | Public IP | Runs |
|---|---|---|---|---|
| management | public a | t3.small, 30 GB gp3 | Elastic IP | sshd (bastion, user `management`), Jenkins LTS on 127.0.0.1:8080, Docker, Node 20, Trivy, AWS CLI |
| backend | private a | t3.micro, 20 GB gp3 | none | Docker: `todo-prod` (:3000) and `todo-staging` (:3001); node_exporter :9100; promtail |
| mon | private a | t3.small, 20 GB gp3 | none | docker compose: Prometheus :9090, Grafana :3000, Loki :3100, Alertmanager :9093, postgres_exporter :9187; node_exporter; promtail |

### Architecture decisions

| Decision | Why |
|---|---|
| **EC2 + Docker** (Amazon Linux 2023) rather than ECS/EKS | A real OS gives infrastructure metrics, bastion access and SSM to show; a managed scheduler would hide half of what the assignment asks to demonstrate and costs more. |
| **Three hosts, strict jump model** | `management` is the only public host (SSH from your IP only). `backend` and `mon` have no public IPs; you reach them via `ProxyJump` and reach every UI via SSH tunnels. Jenkins lives on management to save a box. |
| **Single infrastructure, logical prod/staging** | Two containers on the backend host, two ALB listeners (`:80`, `:8080`), two target groups, two databases (`todo_prod`, `todo_staging`). Real process/data/URL separation at near-zero extra cost; the Terraform root is parameterised so physical separation is a tfvars change. |
| **Jenkins on management, configured by JCasC, polling GitHub every minute** | Everything about Jenkins is in [`jenkins/jenkins.yaml`](jenkins/jenkins.yaml) and [`jenkins/plugins.txt`](jenkins/plugins.txt); a rebuilt host is identical. Polling (not webhooks) keeps Jenkins fully private with no inbound endpoint; a push still builds within 60 s and results post back as GitHub commit statuses. |
| **Deploys via `aws ssm send-command`** | No SSH keys in Jenkins. The management instance role may run `AWS-RunShellScript` on the backend instance only; every deploy is an auditable SSM invocation. |
| **Docker Hub, public repo** | No pull credentials needed on the backend; push credentials live only in Secrets Manager → Jenkins credential store. |
| **Prometheus + Grafana + Loki + Alertmanager** | Open-source, file-provisioned (dashboards and datasources as JSON/YAML in git), one stack for metrics, logs and alerts. |
| **Single NAT gateway** | Textbook egress for private subnets; per-AZ NAT is the HA upgrade. |
| **S3 + DynamoDB remote state** | Versioned, encrypted bucket plus lock table, created once by [`terraform/bootstrap/`](terraform/bootstrap/). |
| **SNS → email** for both pipeline failures and Prometheus alerts | One topic, one subscription, no Slack workspace needed. |

## Prerequisites

- Terraform ≥ 1.6 (developed with 1.10) and AWS CLI v2 with a profile that can create VPC/EC2/RDS/IAM/S3/DynamoDB/Secrets Manager/SNS resources (`export AWS_PROFILE=...`).
- `jq`, `git`, `ssh`, `curl` (Git Bash on Windows works; PowerShell for `setup-ssh.ps1`).
- An SSH key pair for the hosts:
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/8byte -C you@laptop
  ```
- A Docker Hub account and an access token with **Read & Write** scope (a read-only token logs in fine and only fails at `docker push`; `put-secrets.sh` checks the scope up front). The repository `youruser/todo` is created public on first push, or create it yourself beforehand.
- This repository pushed to GitHub, and a GitHub PAT. A public repo *can* be scanned without one, but anonymous GitHub API calls are capped at 60/hour and Jenkins throttles hard against that (branch scans and builds stall for minutes), so a token is strongly recommended: classic PAT with `public_repo` + `repo:status` (public repo) or `repo` (private) — 5000 requests/hour and commit statuses.
- Your public IP (`curl -s https://checkip.amazonaws.com`) for `admin_cidr`.
- An email address for alerts (you will get one SNS confirmation email to click).

## Setup and run

All paths are relative to the repository root. The order matters: hosts read
Secrets Manager at boot, so the secrets you supply must exist before the
hosts are created (see [`terraform/envs/dev.tfvars.example`](terraform/envs/dev.tfvars.example)).

**1. Create the state bucket and lock table (once, local state).**

```bash
cd terraform/bootstrap
terraform init
terraform apply            # prints state_bucket = 8byte-tfstate-<account-id>
cd ..
```

**2. Point the main root at that bucket and initialise it.**

```bash
cp backend.hcl.example backend.hcl        # set bucket = 8byte-tfstate-<account-id>
terraform init -backend-config=backend.hcl
```

**3. Fill in your variables.**

```bash
cp envs/dev.tfvars.example envs/dev.tfvars
# edit: admin_cidr, admin_public_key (contents of ~/.ssh/8byte.pub), alert_email,
#       dockerhub_repo, github_repo (owner/repo), git_ref (branch the hosts clone)
```

**4. Create the secret containers, then write your Docker Hub / GitHub values into them.**

```bash
terraform apply -var-file=envs/dev.tfvars -target=module.secrets
DOCKERHUB_USERNAME=youruser DOCKERHUB_TOKEN=dckr_pat_... GITHUB_TOKEN= ../scripts/put-secrets.sh
# omit the variables to be prompted silently; GITHUB_TOKEN= (empty) = anonymous scanning (60 req/h, not recommended)
```

**5. Apply everything.**

```bash
terraform apply -var-file=envs/dev.tfvars
```

**6. Install the SSH config and the `management` / `backend` / `mon` shortcuts.**

```bash
cd ..
scripts/setup-ssh.sh          # Git Bash / Linux / macOS: ~/.ssh/config + ~/.bashrc aliases
# or, in PowerShell:
.\scripts\setup-ssh.ps1       # ~/.ssh/config + functions in $PROFILE
```

This renders `terraform output -raw ssh_config` into a managed
`# BEGIN 8byte … # END 8byte` block. After that, typing `management`,
`backend` or `mon` in a new shell runs `ssh <host>`. `backend` and `mon` use
`ProxyJump management`, so SSH goes through the bastion automatically.
`management` also opens `localhost:8080 → Jenkins`, and `mon` opens
`localhost:3000 → Grafana` and `localhost:9090 → Prometheus`.

To also hop the classic way — log in to management, then `ssh backend` /
`ssh mon` from there — run once (and again after the management host is
rebuilt):

```bash
scripts/setup-bastion-hop.sh
```

It copies the private key to `management:~/.ssh/8byte` (mode 600) and writes
a `~/.ssh/config` there for the two private hosts, then tests both hops.
This is a convenience for operating from the bastion; the ProxyJump path
above works without any key on it, and Jenkins never uses SSH (deploys go
over SSM).

There is no EC2 key-pair object: the public key from `admin_public_key` is
written by user-data into `~/.ssh/authorized_keys` of a per-host user
(`management`, `backend`, `mon`). If `ssh management` **times out**, your
public IP has almost certainly changed (the bastion's security group allows
`admin_cidr` only):

```bash
scripts/update-admin-cidr.sh          # or .\scripts\update-admin-cidr.ps1
```

detects the new IP, rewrites `admin_cidr` in `envs/dev.tfvars` and applies
just the security-group rule. If instead you get *host key verification
failed*, the host was rebuilt — `ssh-keygen -R <management-eip>`.

**7. Wait for the hosts to bootstrap (~10 minutes; Jenkins and its plugins are the slow part).**

```bash
management
sudo tail -f /var/log/8byte-bootstrap.log     # same file on backend and mon
```

The script ends with Jenkins answering on `/login` (management), the two app
containers healthy (backend) and all monitoring services ready (mon). Confirm
the SNS subscription email in the meantime.

**8. Open Jenkins and run the pipeline.**

Keep the `management` SSH session open (it holds the tunnel) and browse to
<http://localhost:8080>. User `admin`; password:

```bash
aws secretsmanager get-secret-value --secret-id 8byte/jenkins \
  --query SecretString --output text | jq -r .admin_password
```

The `todo` multibranch job scans the repo within a minute and builds `main`.
Watch it go through tests, scans, image build/push and the staging deploy;
at **Approve production** click *Deploy*. The same image tag is then promoted
to prod and smoke-tested. (For an unattended run, *Build with Parameters*
with `AUTO_APPROVE_PROD` ticked skips the prompt.)

**9. Use the app.**

```bash
cd terraform
terraform output prod_url       # http://<alb-dns>
terraform output staging_url    # http://<alb-dns>:8080
../scripts/smoke-test.sh "$(terraform output -raw prod_url)"
```

**10. Open Grafana.**

```bash
mon                             # tunnel: localhost:3000 (Grafana), localhost:9090 (Prometheus)
```

<http://localhost:3000>, user `admin`, password = the Jenkins admin password
above (one admin secret for both UIs). Dashboards are in the `8byte` folder.

### Local developer loop

```bash
cd app
npm ci && npm run lint && npm run test:unit
docker compose up --build              # app on http://localhost:3000, Postgres on 5432
DATABASE_URL=postgres://todo:todo@localhost:5432/todo_dev npm run test:integration
```

## CI/CD pipeline

[`Jenkinsfile`](Jenkinsfile) is declarative and runs on the management
controller (single-node demo). Stages 1–6 run for every branch and PR; 7–14
run only on `main`.

| # | Stage | Runs on | What it does |
|---|---|---|---|
| 1 | Checkout | all | `checkout scm`, `GIT_SHA` = 12-char short SHA (the image tag) |
| 2 | Install & Lint | all | `npm ci`, `npm run lint` (ESLint) |
| 3 | Unit tests | all | `npm run test:unit` (Jest), JUnit report |
| 4 | Integration tests | all | throw-away `postgres:16-alpine` sidecar per executor, `npm run test:integration` (supertest, real SQL), JUnit report |
| 5 | Dependency scan | all | `npm audit --audit-level=high` (advisory, never blocks) + `trivy fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 --skip-dirs '**/node_modules' app/` (gate on the lockfile) |
| 6 | Terraform check | when `terraform/**` changed | `terraform fmt -check`, `init -backend=false`, `validate` in `hashicorp/terraform:1.9` |
| 7 | Build image | `main` | `docker build -t $DOCKERHUB_REPO:$GIT_SHA -t $DOCKERHUB_REPO:latest app/` |
| 8 | Image scan | `main` | `trivy image --severity CRITICAL --exit-code 1` (gate), report archived |
| 9 | Push image | `main` | `docker login` with the `dockerhub` credential (`--password-stdin`), push both tags |
| 10 | Deploy staging | `main` | [`scripts/ssm-deploy.sh staging <sha>`](scripts/ssm-deploy.sh) → SSM Run Command → `/opt/todo/deploy.sh staging <sha>` on backend |
| 11 | Smoke test staging | `main` | [`scripts/smoke-test.sh`](scripts/smoke-test.sh) against `http://$ALB_DNS:8080`: `/health` `db: ok`, POST/GET/DELETE round-trip |
| 12 | Approve production | `main` | `input` "Promote `<sha>` to production?", 30-minute timeout; skipped when the `AUTO_APPROVE_PROD` build parameter is ticked (default off) |
| 13 | Deploy production | `main` | same SSM call with `prod` and the **same tag** — the image is promoted, never rebuilt |
| 14 | Smoke test production | `main` | smoke test against `http://$ALB_DNS` |

- **Triggers:** the multibranch job polls GitHub every minute (`periodicFolderTrigger 1m`) and builds origin branches and PR heads; results are posted as commit statuses. No inbound webhook (Jenkins is private); the upgrade path is in [`jenkins/README.md`](jenkins/README.md).
- **Failure notification:** every stage records its name on failure; the pipeline-level `post { failure }` runs `aws sns publish` with the job, build URL, branch, commit and failed stage. The SNS topic's email subscription delivers it.
- **Deploy on the box:** [`scripts/deploy.sh`](scripts/deploy.sh) reads `8byte/db` from Secrets Manager, builds `DATABASE_URL` for the env (`?sslmode=require`), pulls the image, replaces `todo-<env>` with `--restart unless-stopped`, json-file logging and the `env` label, then polls `/health` for 60 s and dumps logs on failure (which fails the Jenkins stage). It prints the previously running tag.
- **Rollback:** from the backend host (`backend`), `sudo /opt/todo/deploy.sh prod <previous-tag>`; or re-run the SSM call from management with an older tag. Old images stay on the host.

## Monitoring and logging

Details in [`monitoring/README.md`](monitoring/README.md).

**Metrics** (Prometheus on mon, 15 s scrape, 15-day retention):

| Source | Target | What |
|---|---|---|
| node_exporter | backend:9100, mon:9100 | CPU, memory, disk usage and I/O, network, load, uptime |
| app `/metrics` (prom-client) | backend:3000 (prod), :3001 (staging) | `http_requests_total{method,route,status,env}`, `http_request_duration_seconds` histogram, Node runtime |
| postgres_exporter | mon:9187 → RDS | connections vs `max_connections`, TPS, cache hit ratio, rows, DB size, deadlocks (`rdsadmin` excluded) |
| self | prometheus, loki, grafana, alertmanager | stack health |

**Logs** (Loki on mon, filesystem storage, 7-day retention): promtail on backend
and mon ships (a) every Docker container's json-file log via Docker service
discovery, labelled `container`, `env` (`prod`/`staging`/`monitoring`), `host`,
plus `level` parsed from the app's pino JSON — this is both the application log
and the per-request access log; (b) the systemd journal (`job="system"`, labels
`unit`, `level`) — AL2023 has no rsyslog, so sshd/docker/cloud-init live there
— plus `/var/log/cloud-init-output.log` and `/var/log/8byte-bootstrap.log`.
ALB access logs go to the `8byte-alb-logs-<account-id>` S3 bucket (30-day
expiry), not into Loki.

**Dashboards** (provisioned from JSON in [`monitoring/grafana/dashboards/`](monitoring/grafana/dashboards/)):

1. **Todo — Application** (`todo-app`): request rate, error %, p50/p95/p99, requests by route/status, per-env selector, live Loki log panel.
2. **Infrastructure** (`infra`): per-host CPU, memory, root fs, disk I/O, network, load, uptime, scrape-target status.
3. **PostgreSQL** (`postgres`): connections vs max, TPS, cache hit ratio, rows, DB size, deadlocks, `pg_up`.

**Alerts:** Prometheus rules (`InstanceDown`, `HighErrorRate` 5xx > 5 %, `HighLatency`
p95 > 1 s, `DiskAlmostFull` > 80 %, `HighMemory` > 90 %, `HighCpu`, `PostgresDown`,
`PostgresTooManyConnections` > 80 %, `PostgresDeadlocks`) → Alertmanager →
`sns_configs` (SigV4 with the mon instance role) → the same `8byte-alerts`
topic → email, firing and resolved. Test: `docker stop todo-staging` on backend;
`InstanceDown` mails after ~2 minutes.

## Security considerations

- **One way in.** SSH (22) to management from `admin_cidr` only, key-only (`PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers <role>`), one named user per host (`management`, `backend`, `mon`) created by cloud-init with your public key. backend/mon have no public IP and accept SSH only from the management SG. Jenkins binds to 127.0.0.1; all UIs are reached through SSH tunnels.
- **Security groups** ([`terraform/modules/security`](terraform/modules/security/main.tf)) are the only allowed paths:

  | SG | Inbound from | Ports |
  |---|---|---|
  | alb | 0.0.0.0/0 | 80 (prod), 8080 (staging) |
  | management | `admin_cidr` | 22 |
  | backend | alb | 3000, 3001 |
  | backend | management | 22 |
  | backend | mon | 9100, 3000, 3001 (scrapes) |
  | mon | management | 22 |
  | mon | backend | 3100 (Loki push) |
  | rds | backend, mon | 5432 |

- **IMDSv2 required** on all hosts; `http_put_response_hop_limit = 2` because Alertmanager runs in a container (one extra network hop) and signs SNS calls with the instance role.
- **Encryption at rest:** gp3 root volumes and RDS storage encrypted; state bucket SSE-S3 with versioning and public access blocked; `publicly_accessible = false` on RDS.
- **Secrets never on disk in git or in Jenkins config.** Instance roles fetch `8byte/*` from Secrets Manager at boot and at deploy time; JCasC reads credentials from the systemd environment (`override.conf`, mode 0600). Your own AWS keys are used only locally for Terraform.
- **Least-privilege IAM:** each host has its own role; management may `ssm:SendCommand` only on the backend instance and the `AWS-RunShellScript` document; `secretsmanager:GetSecretValue` is scoped to named secret ARNs; `sns:Publish` to the one topic.
- **Container hygiene:** multi-stage `node:20-alpine` image, `npm ci --omit=dev`, runs as the `node` user, `HEALTHCHECK`; Trivy gates on HIGH/CRITICAL dependencies and CRITICAL image CVEs.
- **Verified TLS to RDS:** the image bundles the Amazon RDS global CA (`NODE_EXTRA_CA_CERTS`), so `sslmode=require` in node-postgres verifies the server certificate instead of disabling verification.
- **Input validation** on tag names in `ssm-deploy.sh` (`[A-Za-z0-9._-]+`) before anything is interpolated into an SSM command.

Demo relaxations you would change for production: `deletion_protection = false`
and `skip_final_snapshot = true` on RDS (set `true`/`false`); `force_destroy` on
the state and log buckets; secrets with `recovery_window_in_days = 0`; HTTP-only
ALB (add ACM + a domain and redirect 80 → 443); Jenkins "logged-in users can do
anything" and Job DSL script security off (use a matrix strategy and approve the
seed script); single-AZ RDS; no VPC flow logs or WAF.

## Cost

While everything is up (ap-south-1, on-demand):

| Resource | Approx. cost |
|---|---|
| NAT gateway (+ data) | ~$0.05/h |
| Application Load Balancer | ~$0.025/h |
| RDS `db.t4g.micro`, 20 GB gp3 | ~$0.02/h |
| 2× `t3.small` (management, mon) + 1× `t3.micro` (backend) | ~$0.06/h |
| Elastic IP, 70 GB gp3 EBS, S3 (state, ALB logs), SNS, Secrets Manager (4 secrets) | ~$0.01/h |
| **Total** | **≈ $0.17/h ≈ $4/day** |

Already taken: smallest viable instance types (ARM `t4g` for RDS), single AZ,
single NAT, one host shared by prod and staging, Jenkins co-located with the
bastion, Performance Insights off, 15-day/7-day retention, ALB logs expire after
30 days, no idle managed services (no ECS/EKS control plane, no managed
Grafana/Prometheus). Destroy when not in use (see Teardown); a three-day working
window costs well under $15.

Further options: replace the NAT gateway with a NAT instance or `fck-nat`
(~$0.005/h); spot for management/mon; a scheduled stop/start of the three
instances and RDS outside working hours (Lambda + EventBridge); VPC endpoints for
SSM, Secrets Manager and S3 to cut NAT data charges; Savings Plans if it ran for
months.

## Secret management

| Secret | Contents | Created by | Consumed by |
|---|---|---|---|
| `8byte/db` | `{host, port, username, password, dbname_prod, dbname_staging}` | Terraform (`random_password`) | backend (`deploy.sh`, DB creation), mon (postgres_exporter) |
| `8byte/jenkins` | `{admin_password}` | Terraform (`random_password`) | management (Jenkins admin), mon (Grafana admin) |
| `8byte/dockerhub` | `{username, token}` | you, via `scripts/put-secrets.sh` | management (Jenkins `dockerhub` credential) |
| `8byte/github` | `{token}` (may be empty) | you, via `scripts/put-secrets.sh` | all hosts (clone), management (Jenkins `github-token`) |

The values you supply are written with `aws secretsmanager put-secret-value`
and never pass through Terraform state. The two generated passwords do exist in
state, which is why state lives in an encrypted, versioned, access-blocked
bucket. Nothing is written to `/etc/8byte/env` except non-secret identifiers;
hosts fetch secrets with their instance role at boot and at each deploy.

Rotation:

```bash
cd terraform
terraform apply -var-file=envs/dev.tfvars -replace=module.database.random_password.master        # DB password
terraform apply -var-file=envs/dev.tfvars -replace=module.secrets.random_password.jenkins_admin  # Jenkins/Grafana admin
DOCKERHUB_TOKEN=... ../scripts/put-secrets.sh                                                     # Docker Hub / GitHub
```

After rotating, re-run the affected bootstrap script on the host
(`sudo bash /opt/8byte/repo/scripts/bootstrap/<role>.sh`) or `deploy.sh` so the
new value is picked up; Grafana's stored password is reset with
`grafana cli admin reset-admin-password` (see the monitoring README).

## Backup strategy

- **RDS automated backups:** `backup_retention_period = 7`, window 20:00–21:00 UTC, daily snapshot plus transaction logs for point-in-time recovery within the window.
- **Manual snapshot before risky changes:**
  ```bash
  aws rds create-db-snapshot --db-instance-identifier db-8byte \
    --db-snapshot-identifier manual-8byte-$(date +%Y%m%d-%H%M)
  aws rds describe-db-snapshots --db-instance-identifier db-8byte --query 'DBSnapshots[].DBSnapshotIdentifier'
  ```
- **Restore outline:** `aws rds restore-db-instance-from-db-snapshot --db-instance-identifier db-8byte-restored --db-snapshot-identifier <id> --db-subnet-group-name <group> --vpc-security-group-ids <rds-sg>` (or `restore-db-instance-to-point-in-time`), then either point `8byte/db` at the new endpoint and re-run `deploy.sh`, or import the restored instance into Terraform state and swap identifiers. Logical dumps are also possible from the backend host with `pg_dump` (the PostgreSQL 16 client is installed there).
- **Terraform state:** S3 versioning keeps every prior state file; restore by copying an older version key back.
- **Jenkins:** no backup needed — the controller is reproduced from `jenkins.yaml`, `plugins.txt` and the bootstrap script. Build history is disposable (last 20 builds kept).
- **Application code and images:** git on GitHub; every image tag is a commit SHA on Docker Hub, so any previous version can be redeployed.

## What was verified on real infrastructure

The development machine had no Docker, so during the build everything was
verified statically (`terraform validate`, `bash -n`, YAML/JSON parsing,
rendered templates, fake-backed script tests). On 2026-09-14 the stack was
then applied for real in `ap-south-1` and the following was observed on the
hosts (the fixes it took are [`docs/CHALLENGES.md`](docs/CHALLENGES.md) §13–§20):

- `terraform apply` from a fresh account: bootstrap root, then 78 resources in the main root; three instance replacements to roll user-data/bootstrap fixes, EIP and RDS untouched.
- **backend** bootstrap in 86 s: node_exporter, promtail (shipping to Loki on mon), `psql`, `todo_prod` + `todo_staging` created on RDS over TLS, `deploy.sh` installed.
- **mon** bootstrap in 112 s: Prometheus (7/7 infra targets UP, 9 rules loaded), Alertmanager (SNS receiver rendered with the real topic ARN), Grafana 11 (both datasources healthy, all 3 dashboards provisioned), Loki receiving logs from both hosts, postgres_exporter `pg_up 1`.
- **management**: Jenkins LTS 2.568 on Java 21, 85/85 plugins active, JCasC applied without errors, both credentials present, multibranch job discovers `main` and builds it automatically.
- **Pipeline, end to end** (build `main #1` after the fixes, ~2 min to the gate): checkout → lint → 35 unit tests → 3 integration tests against a real Postgres container → `trivy fs` (0) → image build → `trivy image` (0 CRITICAL; it had correctly **failed** an earlier run on a real CVE in the base image) → push `revtron/todo:<sha>` + `:latest` to Docker Hub (21 s) → `Deploy staging` via SSM (14 s) → ALB smoke test on `:8080` → **Approve production** (paused 7 min for a human) → `Deploy production` (8 s) → ALB smoke test on `:80` → `SUCCESS`, commit status `success` posted to GitHub, result email via SNS.
- **Running app**: `GET /health` through the ALB returns `{"status":"ok","env":"prod","version":"<sha>","db":"ok"}` (staging on `:8080`); todos created through the API; Prometheus scrapes both `todo-app` targets (`http_requests_total` by env), Loki shows `todo-prod` / `todo-staging` container logs, and the *Todo — Application* dashboard populates.

What to check on first boot: `/var/log/8byte-bootstrap.log` on each host;
`curl localhost:3000/health` on backend (`db: "ok"` proves the RDS TLS path);
Prometheus *Status → Targets* all UP; a Jenkins build reaching *Approve production*.

Deliberate simplifications and deferred minors: single NAT and single-AZ RDS;
brief (2–5 s) downtime per deploy (no blue/green); the first build of a branch
skips the Terraform check (empty changeset); Jenkins plugins unpinned;
management is replaced whenever the backend instance is replaced (its user-data
embeds the backend id); the RDS CA `ADD` in the Dockerfile has no checksum pin;
`repo.update()` builds malformed SQL if called with no fields (guarded by
validation upstream); backend/mon private IPs are fixed at `10.0.10.10` /
`10.0.10.20` (scrape targets depend on them; assumes the default `vpc_cidr`).

## Good practices I'd add next

HTTPS with ACM and a real domain (80 → 443 redirect); multi-AZ RDS and per-AZ
NAT; an Auto Scaling group behind the ALB with blue/green target-group swaps;
a GitHub webhook (or GitHub App) into Jenkins and a dedicated build agent;
pinned plugin versions; OIDC-federated CI credentials instead of long-lived
tokens; VPC flow logs and WAF on the ALB; Loki on S3 and Grafana SSO; Docker
Hub → ECR with image signing; `terraform plan` in CI with a policy check
(tfsec/checkov); DB migrations as a pipeline stage rather than `CREATE TABLE IF
NOT EXISTS` at startup; a scheduled stop/start to cut cost.

## Repository layout

```
8byte/
├── app/                      Express app: src/, public/, test/{unit,integration}, Dockerfile, docker-compose.yml
├── terraform/
│   ├── bootstrap/            S3 state bucket + DynamoDB lock table (local state, applied once)
│   ├── modules/              network, security, alb, compute, database, secrets, notifications
│   ├── templates/            user_data.sh.tftpl (cloud-init), ssh_config.tftpl
│   ├── envs/                 dev.tfvars.example
│   └── main.tf variables.tf outputs.tf backend.tf providers.tf versions.tf backend.hcl.example
├── jenkins/                  jenkins.yaml (JCasC), plugins.txt, README.md
├── Jenkinsfile               14-stage pipeline
├── monitoring/               docker-compose.yml, prometheus/, alertmanager/, loki/, promtail/, grafana/, README.md
├── scripts/
│   ├── bootstrap/            management.sh, backend.sh, mon.sh (run by cloud-init on each host)
│   ├── deploy.sh             runs on backend via SSM: pull, replace container, health-check
│   ├── ssm-deploy.sh         runs in Jenkins: send-command + wait
│   ├── smoke-test.sh         /health + CRUD round-trip against a URL
│   ├── put-secrets.sh        writes Docker Hub / GitHub values into Secrets Manager
│   ├── setup-ssh.sh / .ps1   installs ~/.ssh/config block and management/backend/mon shortcuts
│   └── install-node-exporter.sh, install-promtail.sh
└── docs/                     APPROACH.md, CHALLENGES.md, superpowers/specs/ (design spec)
```

## Teardown

```bash
cd terraform
terraform destroy -var-file=envs/dev.tfvars      # ~10 min; RDS is dropped without a final snapshot (demo setting)
cd bootstrap
terraform destroy                                # state bucket (force_destroy) and lock table
```

Then remove the `# BEGIN 8byte … # END 8byte` blocks from `~/.ssh/config` and
your shell profile if you no longer want the shortcuts.
