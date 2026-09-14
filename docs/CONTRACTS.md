# Cross-component contracts the tracks were built against

# Cross-track contracts (binding for terraform / monitoring / jenkins tracks)

Spec (authority): docs/superpowers/specs/2026-09-13-8byte-devops-platform-design.md — read it fully first.

## Naming
- Project prefix for every AWS resource name/tag: `8byte-` (e.g. `8byte-vpc`, `8byte-backend`). Tag every resource with `Project=8byte`, `Env=dev`, `ManagedBy=terraform`.
- Region `ap-south-1`. AZs `ap-south-1a`, `ap-south-1b`.
- Static private IPs (so hosts can reference each other with no Terraform dependency cycle):
  - backend `10.0.10.10`, mon `10.0.10.20` (both in private subnet a, `10.0.10.0/24`)
  - management is in public subnet a `10.0.0.0/24`, gets an Elastic IP.

## Secrets Manager secret names (Terraform creates the containers; values written by scripts/put-secrets.sh or Terraform for db)
| name | JSON shape | written by |
|---|---|---|
| `8byte/db` | `{"host","port","username","password","dbname_prod":"todo_prod","dbname_staging":"todo_staging"}` | Terraform (random_password) |
| `8byte/dockerhub` | `{"username","token"}` | put-secrets.sh |
| `8byte/github` | `{"token"}` | put-secrets.sh |
| `8byte/jenkins` | `{"admin_password"}` | put-secrets.sh (or Terraform random_password) |

## Host bootstrap contract
Terraform user-data (all three hosts) does ONLY the generic part, then hands off to the repo:
1. Create the role user (`management` | `backend` | `mon`) with the admin public key + passwordless sudo; harden sshd (PasswordAuthentication no, PermitRootLogin no, AllowUsers <user>); restart sshd.
2. `dnf install -y docker git jq` (+ awscli v2 is preinstalled on AL2023), enable+start docker, add the role user to the `docker` group. Install `docker compose` plugin (`docker-compose-plugin` is NOT in AL2023 repos — download the compose v2 binary to `/usr/local/lib/docker/cli-plugins/docker-compose`).
3. Write `/etc/8byte/env` (mode 0640 root:docker) with:
```
ROLE=<management|backend|mon>
AWS_REGION=ap-south-1
PROJECT=8byte
GITHUB_REPO=<owner/repo>          # var.github_repo
GIT_REF=main                      # var.git_ref
DOCKERHUB_REPO=<user/todo>        # var.dockerhub_repo
DB_SECRET_ID=8byte/db
DOCKERHUB_SECRET_ID=8byte/dockerhub
GITHUB_SECRET_ID=8byte/github
JENKINS_SECRET_ID=8byte/jenkins
SNS_TOPIC_ARN=<arn>
ALB_DNS=<dns>
BACKEND_PRIVATE_IP=10.0.10.10
MON_PRIVATE_IP=10.0.10.20
BACKEND_INSTANCE_ID=<id>          # management only
```
4. Clone the repo: `git clone --branch $GIT_REF https://github.com/$GITHUB_REPO /opt/8byte/repo` (if `8byte/github` secret has a non-empty token, clone with `https://x-access-token:$TOKEN@github.com/...` to support a private repo).
5. Run `bash /opt/8byte/repo/scripts/bootstrap/$ROLE.sh` (log to `/var/log/8byte-bootstrap.log`). If the script is missing, log a warning and exit 0.

The bootstrap scripts are owned by other tracks:
- `scripts/bootstrap/backend.sh` — jenkins track. Installs node_exporter (systemd, :9100), promtail (systemd, config from `monitoring/promtail/promtail-config.yml` with `${MON_PRIVATE_IP}` substituted via envsubst), installs `psql` client, creates databases `todo_prod` and `todo_staging` on RDS if missing (creds from `8byte/db`), copies `scripts/deploy.sh` to `/opt/todo/deploy.sh`, and runs `deploy.sh prod latest` and `deploy.sh staging latest` (tolerate failure if the image doesn't exist yet).
- `scripts/bootstrap/mon.sh` — monitoring track. Renders `monitoring/.env` (DB creds from `8byte/db`, SNS arn, backend IP, Grafana admin password = jenkins admin password from `8byte/jenkins` for simplicity) and `docker compose -f /opt/8byte/repo/monitoring/docker-compose.yml up -d`. Also installs node_exporter + promtail on mon itself.
- `scripts/bootstrap/management.sh` — jenkins track. Installs Java 21, Jenkins LTS, Trivy, Node 20, plugins from `jenkins/plugins.txt`, JCasC from `jenkins/jenkins.yaml`, systemd env from secrets; starts Jenkins on :8080 (localhost-facing; reached via SSH tunnel).

## Ports (security groups — terraform track)
- alb: 80, 8080 from 0.0.0.0/0
- management: 22 from var.admin_cidr
- backend: 3000, 3001 from alb SG; 22 from management SG; 9100, 3000, 3001 from mon SG
- mon: 22 from management SG; 3100 from backend SG (Loki push); 9100 from mon itself not needed (localhost)
- rds: 5432 from backend SG and mon SG
All egress open.

## Deploy contract (jenkins track)
`/opt/todo/deploy.sh <prod|staging> <tag>` — pulls `$DOCKERHUB_REPO:$tag`, replaces container `todo-<env>` (prod → host port 3000, staging → host port 3001, container port 3000), env: `PORT=3000 APP_ENV=<env> APP_VERSION=<tag> DATABASE_URL=postgres://user:pass@host:5432/todo_<env>`, `--restart unless-stopped`, docker label `env=<env>`, `--log-driver json-file --log-opt max-size=10m --log-opt max-file=3`; waits for `localhost:<port>/health` 200 within 60 s, exits non-zero otherwise.

## App facts (already built in feat/todo-app)
- Image listens on 3000, `GET /health` → 200 JSON `{status,env,version,db}`, `GET /metrics` Prometheus text with `http_requests_total{method,route,status,env}` and `http_request_duration_seconds` histogram, JSON logs to stdout (pino) including `env`, `req.method`, `req.url`, `res.statusCode`, `responseTime`.
- Container name `todo-prod` / `todo-staging`, docker label `env=prod|staging`.

## Alerts (monitoring track)
Alertmanager → SNS via `sns_configs` (topic ARN from env), instance role on mon grants sns:Publish (terraform track).
