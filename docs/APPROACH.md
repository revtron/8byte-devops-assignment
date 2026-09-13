# Approach

How the work was sequenced, why the major choices were made, and where each
assignment requirement is implemented. The short version: write the design
down first, fix the contracts between the moving parts, build the four parts
in parallel against those contracts, review each one, then review the merge.

## 1. Sequence

1. **Read the assignment, write the spec.** Every decision with its reason
   went into [`superpowers/specs/2026-09-13-8byte-devops-platform-design.md`](superpowers/specs/2026-09-13-8byte-devops-platform-design.md)
   before any code: region, compute model, topology, environments, registry,
   CI tool, deploy mechanism, monitoring stack, notification channel, state,
   secrets, backups, and an explicit out-of-scope list. "Happy path first"
   was the rule; anything that would blow the time budget was written down as
   an improvement rather than half-built.

2. **Cross-track contracts.** The four parts touch each other at a handful of
   points: secret names and JSON shapes (`8byte/db`, `8byte/dockerhub`,
   `8byte/github`, `8byte/jenkins`), the env file every host gets
   (`/etc/8byte/env`), the repo checkout path (`/opt/8byte/repo`), the
   bootstrap entry points (`scripts/bootstrap/<role>.sh`), fixed private IPs
   for scrape targets (`10.0.10.10`, `10.0.10.20`), container names and ports
   (`todo-prod` :3000, `todo-staging` :3001), the `/metrics` label set, and
   the deploy contract (`deploy.sh <env> <tag>`). These were pinned in a
   contracts file so tracks could be built independently without one waiting
   on another.

3. **Four tracks in parallel, each in its own branch/worktree.**
   - *Application* (`feat/todo-app`): config → validation → metrics → repo/db
     → app/router → server + integration tests → frontend → Dockerfile/compose.
     Nine small tasks, each with tests, unit suite green (35 tests) before
     moving on.
   - *Terraform* (`feat/terraform`): bootstrap root → network + security →
     database, secrets, notifications → ALB + compute + user-data template →
     root wiring, variables, outputs → SSH/secret helper scripts.
   - *Monitoring* (`feat/monitoring`): compose stack and configs → rules →
     Grafana provisioning + three dashboards → bootstrap and installer
     scripts → README.
   - *Jenkins* (`feat/jenkins`): Jenkinsfile → JCasC + plugins → deploy,
     SSM and smoke scripts → management/backend bootstrap scripts.

4. **Review and fix rounds per track.** Each track got an independent code
   review against the spec and contracts; findings were fixed in a scoped
   round and re-reviewed. This is where most of the real bugs were caught
   (RDS identifiers starting with a digit, hosts booting before the DB secret
   version existed, Trivy scanning `node_modules`, promtail reading files
   AL2023 does not write, `rdsadmin` breaking postgres_exporter — see
   [`CHALLENGES.md`](CHALLENGES.md)).

5. **Merge to `main`, integration review.** The four branches were merged;
   dotfile conflicts (`.gitignore`, `.gitattributes`) resolved by union. Post-
   merge checks: unit tests, lint, `bash -n` on every script, `terraform
   validate` on both roots. A final read-only integration review across the
   whole tree ran in parallel with writing these documents.

6. **Documentation last**, so it describes what exists rather than what was
   planned.

## 2. Reasoning for the major choices

- **EC2 + Docker instead of ECS/EKS.** The assignment asks for infrastructure
  metrics, centralized system logs and secure access; a real OS shows all
  three. EKS would cost more per hour than the rest of the platform combined
  and hide the mechanics being assessed.
- **Three hosts, bastion model, SSH tunnels for every UI.** No public
  endpoints other than the ALB and port 22 from one CIDR. Jenkins co-located
  with the bastion keeps the count at three.
- **One infrastructure, two logical environments.** Two containers, two ALB
  listeners, two databases. Real separation of process, data and URL for
  almost nothing; the root is parameterised so a second physical environment
  is a tfvars change, not a rewrite.
- **Jenkins with JCasC and polling.** Configuration as code means a rebuilt
  controller is identical and reviewable in git. Polling every minute instead
  of a webhook keeps Jenkins entirely private and still starts builds within
  60 s; results are pushed back as commit statuses so PRs show the outcome.
- **SSM Run Command for deploys.** Jenkins needs no SSH key and no network
  path to the backend; the IAM policy limits it to one document on one
  instance and every deploy is logged by SSM.
- **Same image promoted staging → prod.** The tag is the commit SHA, built
  once, scanned once, pushed once. The approval gate promotes; it never
  rebuilds.
- **Secrets Manager + instance roles.** Generated passwords come from
  Terraform; user-supplied tokens are written by a script so they never enter
  state; every host reads only the secrets its role names.
- **Prometheus/Grafana/Loki, all file-provisioned.** Dashboards, datasources,
  rules and Alertmanager routing are JSON/YAML in git; a re-run of the
  bootstrap script reconciles the box.
- **Static analysis where Docker was unavailable.** The build machine had no
  Docker, so everything that needs it was written to be verifiable another
  way: `terraform validate`, rendered templates syntax-checked with `bash -n`,
  YAML/JSON parsed, scripts exercised with fake `aws`/`docker`/`curl` on
  `PATH`. What could not be verified is listed honestly in the README.

## 3. Requirement checklist

| Part | Requirement | Implemented in |
|---|---|---|
| 1 | VPC with public and private subnets | [`terraform/modules/network`](../terraform/modules/network/main.tf) |
| 1 | Compute hosting (EC2) | [`terraform/modules/compute`](../terraform/modules/compute/main.tf), [`terraform/templates/user_data.sh.tftpl`](../terraform/templates/user_data.sh.tftpl) |
| 1 | RDS PostgreSQL | [`terraform/modules/database`](../terraform/modules/database/main.tf) |
| 1 | Security groups | [`terraform/modules/security`](../terraform/modules/security/main.tf) |
| 1 | Load balancer for the frontend | [`terraform/modules/alb`](../terraform/modules/alb/main.tf) |
| 1 | `variables.tf`, outputs | [`terraform/variables.tf`](../terraform/variables.tf), [`terraform/outputs.tf`](../terraform/outputs.tf) |
| 1 | Proper state management | [`terraform/bootstrap`](../terraform/bootstrap/main.tf), [`terraform/backend.tf`](../terraform/backend.tf), committed lock files |
| 2 | Tests on PR | [`Jenkinsfile`](../Jenkinsfile) stages 1–6 (all branches/PRs) |
| 2 | Build + push image on merge to main | `Jenkinsfile` stages 7–9 (`when { branch 'main' }`) |
| 2 | Deploy to staging | stage 10 → [`scripts/ssm-deploy.sh`](../scripts/ssm-deploy.sh) → [`scripts/deploy.sh`](../scripts/deploy.sh) |
| 2 | Manual approval for production | stage 12 (`input`, 30-minute timeout) |
| 2 | Unit + integration tests | [`app/test/unit`](../app/test/unit), [`app/test/integration`](../app/test/integration); stages 3–4 |
| 2 | Dependency + container vulnerability scans | stage 5 (`npm audit`, `trivy fs`), stage 8 (`trivy image`) |
| 2 | Notify on failure | `post { failure }` → SNS → email; topic in [`terraform/modules/notifications`](../terraform/modules/notifications/main.tf) |
| 3 | Infra metrics (CPU/mem/disk) | node_exporter via [`scripts/install-node-exporter.sh`](../scripts/install-node-exporter.sh); [`monitoring/prometheus/prometheus.yml`](../monitoring/prometheus/prometheus.yml) |
| 3 | App metrics (rate/errors/latency) | [`app/src/metrics.js`](../app/src/metrics.js) (`prom-client`), scraped as job `todo-app` |
| 3 | DB metrics | postgres_exporter in [`monitoring/docker-compose.yml`](../monitoring/docker-compose.yml) |
| 3 | Centralized logs: app, system, access | promtail ([`monitoring/promtail/promtail-config.yml.tpl`](../monitoring/promtail/promtail-config.yml.tpl)) → Loki; ALB access logs → S3 ([`terraform/modules/alb/logs.tf`](../terraform/modules/alb/logs.tf)) |
| 3 | ≥ 2 meaningful dashboards | [`monitoring/grafana/dashboards/`](../monitoring/grafana/dashboards) (application, infrastructure, PostgreSQL) |
| 3 | Alerting (extra) | [`monitoring/prometheus/rules/`](../monitoring/prometheus/rules), [`monitoring/alertmanager/alertmanager.yml.tpl`](../monitoring/alertmanager/alertmanager.yml.tpl) |
| 4 | README: setup, architecture, security, cost | [`README.md`](../README.md) |
| 4 | Secret management | [`terraform/modules/secrets`](../terraform/modules/secrets/main.tf), [`scripts/put-secrets.sh`](../scripts/put-secrets.sh), instance-role reads in bootstrap/deploy scripts |
| 4 | Backup strategy | RDS `backup_retention_period = 7` in the database module; manual snapshot + restore procedure in the README; versioned state bucket |
| Deliverables | Approach, challenges | this file, [`CHALLENGES.md`](CHALLENGES.md) |
