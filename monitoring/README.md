# Monitoring and logging (Part 3)

Prometheus + Alertmanager + Grafana + Loki run as Docker Compose services on the
`mon` host (`10.0.10.20`). node_exporter and promtail run as systemd services on
**both** the `backend` and `mon` hosts. Alerts go to email through the same SNS
topic the CI pipeline uses.

```mermaid
flowchart LR
  subgraph backend["backend 10.0.10.10"]
    prod["todo-prod :3000 /metrics"]
    stg["todo-staging :3001 /metrics"]
    ne1["node_exporter :9100"]
    pt1["promtail (docker_sd + /var/log)"]
  end
  subgraph mon["mon 10.0.10.20 (docker compose)"]
    prom["Prometheus :9090<br/>15 s scrape, 15 d retention"]
    am["Alertmanager :9093"]
    graf["Grafana :3000"]
    loki["Loki :3100<br/>filesystem, 7 d retention"]
    pgx["postgres_exporter :9187"]
    ne2["node_exporter :9100"]
    pt2["promtail"]
  end
  rds[("RDS PostgreSQL")]
  sns["SNS topic -> email"]
  prom --> prod & stg & ne1 & ne2 & pgx & loki & am
  pgx --> rds
  pt1 & pt2 --> loki
  prom -- rules --> am --> sns
  graf --> prom & loki
```

## What runs where

| Host | Component | How it runs | Port | Config |
|---|---|---|---|---|
| mon | Prometheus 2.54.1 | compose `prometheus` | 9090 | `prometheus/prometheus.yml`, `prometheus/rules/*.yml` |
| mon | Alertmanager 0.27.0 | compose `alertmanager` | 9093 | `alertmanager/alertmanager.yml` (rendered from `.tpl`, gitignored) |
| mon | Grafana 11.2.0 | compose `grafana` | 3000 | `grafana/provisioning/**`, `grafana/dashboards/*.json` |
| mon | Loki 3.1.1 | compose `loki` | 3100 | `loki/loki-config.yml` |
| mon | postgres_exporter 0.15.0 | compose `postgres_exporter` | 9187 | `PG_EXPORTER_DSN` in `.env` |
| mon, backend | node_exporter 1.8.2 | systemd `node_exporter` | 9100 | `scripts/install-node-exporter.sh` |
| mon, backend | promtail 3.1.1 | systemd `promtail` | 9080 | `/etc/promtail/config.yml` rendered from `promtail/promtail-config.yml.tpl` |

Everything on `mon` is started by `scripts/bootstrap/mon.sh`, which the Terraform
user-data runs after cloning the repo to `/opt/8byte/repo`. The script is
idempotent: re-run it (`sudo bash /opt/8byte/repo/scripts/bootstrap/mon.sh`)
after changing any file under `monitoring/` and pulling the repo.

Scrape targets use the static private IPs fixed in
`.superpowers/sdd/tracks/contracts.md` (backend `10.0.10.10`, mon `10.0.10.20`),
so there is no service discovery to configure. The mon security group only
admits SSH from management and `3100` from backend (Loki push); the compose
ports bind on `0.0.0.0` but nothing else can reach them.

### Secrets and generated files

`scripts/bootstrap/mon.sh` writes `monitoring/.env` (mode 0640 root:docker) from
Secrets Manager and `/etc/8byte/env`:

| Variable | Source |
|---|---|
| `GRAFANA_ADMIN_PASSWORD` | `8byte/jenkins` -> `admin_password` (one admin password for Jenkins and Grafana). If the secret is not populated yet a random password is generated; re-run the script after `scripts/put-secrets.sh`. |
| `PG_EXPORTER_DSN` | `8byte/db` -> `postgresql://user:pass@host:5432/todo_prod?sslmode=require` (user/password URL-encoded) |
| `SNS_TOPIC_ARN`, `AWS_REGION` | `/etc/8byte/env` |

`alertmanager/alertmanager.yml` is rendered from `alertmanager.yml.tpl` with
`envsubst` (only `${SNS_TOPIC_ARN}` and `${AWS_REGION}` are substituted). Both
generated files are gitignored. `.env.example` documents the variables for a
local run.

## Reaching the UIs (SSH tunnel through `management`)

Nothing on `mon` is exposed publicly. With the SSH config from
`scripts/setup-ssh.sh` (aliases `management`, `backend`, `mon` with
`ProxyJump management`):

```bash
ssh -N \
  -L 3000:localhost:3000 \
  -L 9090:localhost:9090 \
  -L 9093:localhost:9093 \
  -L 3100:localhost:3100 \
  mon
```

Then open:

- Grafana: http://localhost:3000 — user `admin`, password = Jenkins admin password (`8byte/jenkins` secret)
- Prometheus: http://localhost:9090 (Status -> Targets shows every scrape job; Alerts shows rule state)
- Alertmanager: http://localhost:9093
- Loki API: http://localhost:3100/ready

Without the SSH alias: `ssh -J management@<management-eip> mon@10.0.10.20 -L 3000:localhost:3000 ...`.

## Dashboards

Provisioned from JSON, no click-ops. `grafana/provisioning/dashboards/dashboards.yml`
is a file provider watching `/var/lib/grafana/dashboards` (bind mount of
`grafana/dashboards/`) every 30 s.

| File | UID | Content |
|---|---|---|
| `todo-application.json` | `todo-app` | req/s, 5xx %, p50/p95/p99, requests by route/status, per-`env` selector, live Loki logs `{container=~"todo-.*", env="$env"}` |
| `infrastructure.json` | `infra` | per-host CPU, memory, root fs, disk I/O, network rx/tx, load, uptime, scrape target status; `host` selector |
| `postgresql.json` | `postgres` | connections vs `max_connections`, TPS, cache hit ratio, rows fetched/inserted/updated/deleted, DB size, deadlocks, `pg_up` |

Datasources are provisioned with fixed UIDs (`prometheus` = default, `loki`) so
dashboard JSON can reference them without per-install IDs.

### Adding a dashboard

1. Build it in Grafana (dashboards are `editable` but `allowUiUpdates: false`,
   so the UI will not overwrite the file). Alternatively write the JSON by hand.
2. Share -> Export -> *Export for sharing externally* off, copy the JSON.
3. Set a stable `"uid"` and `"title"`, reference datasources as
   `{"type": "prometheus", "uid": "prometheus"}` / `{"type": "loki", "uid": "loki"}`,
   drop the `id` field, and save it as `grafana/dashboards/<name>.json`.
4. Validate: `python -m json.tool grafana/dashboards/<name>.json`.
5. Commit and pull on `mon`; the provider picks it up within 30 s (or
   `docker compose restart grafana`).

## Alerts: Prometheus -> Alertmanager -> SNS -> email

Rules live in `prometheus/rules/` and are evaluated every 15 s:

| Rule | File | Condition |
|---|---|---|
| `InstanceDown` | `infra.yml` | `up == 0` for 2 m (any job) |
| `DiskAlmostFull` | `infra.yml` | root fs > 80 % for 10 m |
| `HighMemory` | `infra.yml` | memory > 90 % for 5 m |
| `HighCpu` | `infra.yml` | CPU > 90 % for 10 m |
| `HighErrorRate` | `app.yml` | 5xx > 5 % of requests per env for 5 m |
| `HighLatency` | `app.yml` | p95 > 1 s per env for 5 m |
| `PostgresDown` | `postgres.yml` | `pg_up == 0` (or absent) for 2 m |
| `PostgresTooManyConnections` | `postgres.yml` | connections > 80 % of `max_connections` for 5 m |
| `PostgresDeadlocks` | `postgres.yml` | any deadlock in 5 m |

Flow:

1. Prometheus fires the alert to `alertmanager:9093`.
2. Alertmanager groups by `alertname`/`env`/`host` (30 s wait, 5 m group
   interval, repeat every 4 h) and sends firing **and resolved** notifications
   to the single receiver `sns-email`.
3. `sns_configs` publishes to `SNS_TOPIC_ARN` using SigV4 with the **mon
   instance role** (`sns:Publish`, granted by Terraform) — no static AWS keys.
4. The SNS topic has an email subscription (Terraform `notifications` module;
   confirm the subscription email once). Subject line:
   `[8byte] FIRING:1 HighErrorRate`; body lists each alert's summary,
   description, labels and start time.

`InstanceDown` inhibits the derived alerts (`HighErrorRate`, `HighLatency`,
`HighMemory`, `HighCpu`, `DiskAlmostFull`) for the same `instance`, so a dead
host produces one email rather than five.

To test end to end: `docker stop todo-staging` on backend; after ~2 m
`InstanceDown` fires (Prometheus -> Alerts) and an email arrives; `docker start
todo-staging` sends the RESOLVED mail.

Changing rules: edit, commit, pull on `mon`, then either re-run `mon.sh` or
`curl -X POST localhost:9090/-/reload` (lifecycle API is enabled). Validate
rules locally with `promtool check rules prometheus/rules/*.yml` if you have
promtool; the CI machine does not run Docker, so YAML validity is checked with
Python.

## Logs

promtail on each host ships two streams to Loki:

- `job="docker"`: every container found through `/var/run/docker.sock`, labels
  `container` (name without the leading `/`), `env` (docker label `env`, i.e.
  `prod`/`staging` for the app, `monitoring` for the stack), `host`, and
  `level` extracted from the pino JSON line of the `todo-*` containers (numeric levels mapped to
  `info`/`warn`/`error`...). Nothing per-request becomes a label.
- `job="system"`: `/var/log/messages`, `/var/log/secure`,
  `/var/log/cloud-init-output.log`, `/var/log/8byte-bootstrap.log`, label `host`.

Useful LogQL in Grafana Explore (datasource Loki):

```logql
{container="todo-prod"} | json | res_statusCode >= 500
{job="system", host="backend"} |= "sshd"
sum by (level) (count_over_time({container=~"todo-.*"}[5m]))
```

Retention is 7 days (Loki compactor, `retention_enabled: true`). ALB access
logs go to S3 (Terraform `alb` module), not into Loki.

## Local run (optional)

Docker Desktop: `cp .env.example .env`, edit, render alertmanager
(`envsubst < alertmanager/alertmanager.yml.tpl > alertmanager/alertmanager.yml`
with `SNS_TOPIC_ARN`/`AWS_REGION` exported), then `docker compose up -d`. The
`node`/`todo-app` targets will show as DOWN because 10.0.10.x is not routable;
Alertmanager will fail to publish without AWS credentials. Everything else
(Grafana, dashboards, Loki, rules) can be checked locally.
