# Challenges and resolutions

Concrete problems hit while building the platform, in the order they surfaced.
Each entry: what went wrong, why, what was changed, and what to take from it.

## 1. `pino-http` rejected the test logger

**Problem.** The app's tests passed a plain-object fake (`{ info(), error() }`)
as the logger. `pino-http` inspects the logger it is given (child loggers,
level methods) and failed, so the first version of `app.js` grew duck-typing
branches to tolerate the fake.

**Cause.** The fix was being made in production code to satisfy a test double.

**Fix.** `app.js` was reverted to the straightforward `pino-http({ logger })`
form; the unit and integration tests now use a real `pino({ level: 'silent' })`
instance ([`app/test/unit/app.test.js`](../app/test/unit/app.test.js)).

**Lesson.** When a library dislikes a test double, fix the double, not the
code under test.

## 2. node-postgres verifies the RDS certificate; Alpine has no RDS CA

**Problem.** The deploy contract sets `DATABASE_URL=...?sslmode=require`.
`pg` treats `sslmode=require` as "verify the server certificate" (libpq does
not), and `node:20-alpine` does not ship the Amazon RDS CA, so the app would
fail the TLS handshake on its first real connection.

**Fix.** The [`Dockerfile`](../app/Dockerfile) `ADD`s
`https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem` and sets
`NODE_EXTRA_CA_CERTS` to it. TLS stays verified; the alternative
(`rejectUnauthorized: false` / `sslmode=no-verify`) was rejected as a
downgrade. `deploy.sh` still honours `DB_SSLMODE` from `/etc/8byte/env` as an
escape hatch.

**Lesson.** "sslmode" means different things in different drivers; decide
where the CA lives before the first deploy, not after `/health` reports
`db: "error"`.

## 3. RDS identifiers cannot start with a digit

**Problem.** Every resource was prefixed with the project name `8byte`, so the
RDS instance and parameter group were named `8byte-db` / `8byte-postgres16`.
RDS rejects identifiers that do not start with a letter; `terraform validate`
does not catch this — it would have failed at apply.

**Fix.** `identifier = "db-${var.project}"`, parameter group
`pg16-${var.project}`; the `Name` tag keeps the readable `8byte-` form
([`terraform/modules/database/main.tf`](../terraform/modules/database/main.tf)).
The first real `apply` then failed on the one name the review had missed —
the DB subnet group, `8byte-db` (`InvalidParameterValue: Invalid subnet group
name`) — so it became `db-${var.project}` too. The rule covers every RDS
name, not just the instance identifier.

**Lesson.** Provider-side naming rules are only enforced at apply; review
names against the service docs when the project prefix is unusual.

## 4. Hosts booted before the DB secret had a value

**Problem.** `module.compute` referenced only the secret *containers*
(ARNs/names). The `8byte/db` secret *version* depends on RDS, which takes
several minutes. Terraform would happily create the instances first; the
backend and mon bootstrap scripts would then read an empty secret and fail.

**Fix.** `depends_on = [module.network, module.secrets]` on `module.compute`
([`terraform/main.tf`](../terraform/main.tf)) — the secrets module includes the
versions, so instances wait for RDS indirectly. Side effect: the AMI data
source is deferred to apply time, so the plan shows it as "known after apply".

**Lesson.** Referencing an output is not the same as depending on everything
in a module; when boot scripts read data at first start, make the dependency
explicit.

## 5. IMDSv2 hop limit and containers

**Problem.** IMDSv2 was required with the default `hop_limit = 1`. Alertmanager
runs in a container and signs SNS requests with the instance role; traffic
from the Docker bridge adds a network hop, so the credential lookup would
time out and alert emails would silently never send.

**Fix.** `http_put_response_hop_limit = 2` on all three instances
([`terraform/modules/compute/main.tf`](../terraform/modules/compute/main.tf)).

**Lesson.** IMDSv2 + containers needs hop limit 2 (or a credential proxy);
it is a one-line setting that is invisible until something in a container
needs AWS credentials.

## 6. Amazon Linux 2023 has no `/var/log/messages`

**Problem.** The promtail config shipped `/var/log/messages` and
`/var/log/secure`. AL2023 is journald-only (no rsyslog), so the "system logs"
stream would have been empty — a silent failure of a Part 3 requirement.

**Fix.** promtail now uses a `journal` scrape (labels `unit`, `level`) and the
static file job keeps only `cloud-init-output.log` and
`8byte-bootstrap.log`. Because AL2023 keeps the journal volatile in
`/run/log/journal`, [`scripts/install-promtail.sh`](../scripts/install-promtail.sh)
creates `/var/log/journal` and restarts journald once so the journal is
persistent and visible to promtail.

**Lesson.** Check what the OS actually writes before choosing log paths;
"system logs" on modern distros means the journal.

## 7. postgres_exporter and the `rdsadmin` database

**Problem.** postgres_exporter auto-discovers databases and tries to connect
to each. On RDS the `rdsadmin` database is not accessible to the master
user, producing permanent connection errors in the exporter's logs and a
noisy `pg_up`.

**Fix.** `PG_EXPORTER_EXCLUDE_DATABASES: rdsadmin,template0,template1` in
[`monitoring/docker-compose.yml`](../monitoring/docker-compose.yml).

**Lesson.** Managed databases have vendor-owned schemas; exporters written for
self-hosted Postgres need to be told about them.

## 8. Trivy scanned `node_modules` with dev dependencies

**Problem.** The dependency scan ran after `npm ci` (which installs dev deps
for lint/tests), so `trivy fs app/` walked `node_modules` and the HIGH gate
would block on dev-only advisories that never ship in the image.

**Fix.** `trivy fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1
--skip-dirs '**/node_modules' app/` — the lockfile's production graph is the
gate; `npm audit` remains advisory. The glob form is used because Trivy
matches skip paths relative to the scan root.

**Lesson.** Decide what a scan gate is judging (what ships) and scope it to
exactly that; otherwise the first red build teaches people to ignore it.

## 9. CRLF on Windows would break cloud-init

**Problem.** The repo was authored on Windows with `core.autocrlf=true`. A
future checkout would turn `user_data.sh.tftpl` and every `*.sh` into CRLF,
and the hosts would fail at boot with `$'\r': command not found`.

**Fix.** A root [`.gitattributes`](../.gitattributes) pins `*.sh`, `*.tftpl`,
`*.tf`, `*.hcl`, `*.example`, YAML and `Jenkinsfile` to `eol=lf` (and `*.ps1`
to CRLF). Verified with `git ls-files --eol`.

**Lesson.** Anything executed on Linux from a repo touched on Windows needs
line endings pinned in git, not left to per-machine config.

## 10. Terraform lock file was gitignored

**Problem.** The initial `.gitignore` excluded `.terraform.lock.hcl`, so a
fresh clone could resolve a different provider version than the one the
configuration was validated against.

**Fix.** Lock files for both roots committed; the AWS provider pinned to
`~> 5.100` (the version actually resolved), `random ~> 3.6`.

**Lesson.** Commit the lock file; it is the reproducibility guarantee for
`terraform init`.

## 11. User-supplied secrets are needed before the hosts boot

**Problem.** Docker Hub and GitHub tokens are written by a script, not by
Terraform. A single `terraform apply` on a fresh account would create the
secret containers and the hosts in the same run, so management's bootstrap
could read an empty `8byte/dockerhub` and Jenkins would start without
registry credentials.

**Fix.** A documented apply order: `terraform apply -target=module.secrets`
→ `scripts/put-secrets.sh` → full `terraform apply` (written into the headers
of `envs/dev.tfvars.example` and `backend.hcl.example` and into the README).
The Jenkins admin password was moved from the script into Terraform
(`random_password`) to remove one more boot-order dependency. Bootstrap
scripts tolerate an empty secret (warn, continue) and are idempotent, so
re-running them after `put-secrets.sh` repairs a host that booted too early.

**Lesson.** When runtime bootstrap reads something Terraform does not
produce, either generate it in Terraform or make the ordering explicit and
the scripts re-runnable.

## 12. No Docker on the build machine

**Problem.** The development machine had no Docker, so the image build, the
app's compose file, the integration tests against a real Postgres, the
Jenkins controller, and the monitoring stack could not be run locally.

**Fix.** Verification was pushed to whatever could run: `terraform validate`
on both roots; rendered user-data through `templatefile()` and `bash -n`;
YAML/JSON parsing plus `envsubst` rendering of the promtail and Alertmanager
templates; metric names cross-checked against exporter reference sets;
`deploy.sh`, `ssm-deploy.sh` and `smoke-test.sh` exercised with fake
`aws`/`docker`/`curl` binaries on `PATH` and a mock HTTP server (this found
two real bugs in curl status handling). Everything that still needs a real
box is listed in the README under "Known limitations".

**Lesson.** State clearly what was verified and how; a reviewer can forgive
"not run here" but not "it works" without evidence.

## 13. First real apply: the free-plan account caps RDS backups

**Problem.** `terraform apply` failed with `FreeTierRestrictionError: The
specified backup retention period exceeds the maximum available to free tier
customers` — the design said 7 days of automated backups; an AWS free-plan
account allows 1.

**Fix.** `backup_retention_period` became a variable
(`db_backup_retention_days`, default 7, set to 1 in `envs/dev.tfvars`) so the
design stays intact and the account limit is a tfvars override, not a code
change. Documented next to the other optional overrides in
`envs/dev.tfvars.example`.

**Lesson.** Account-level limits are invisible to `validate` and `plan`;
anything that might hit one should be a variable so the fix is data, not code.

## 14. `chown` to the role user, then `git` as root: "dubious ownership"

**Problem.** On all three hosts cloud-init died right after cloning the repo.
User-data clones `/opt/8byte/repo`, `chown -R backend:backend`s it so the
role user can read it, then runs `git log -1` as root for the boot log. git
≥ 2.35 refuses to touch a repository owned by another user
(`fatal: detected dubious ownership in repository`), `set -e` stopped the
script, and the role bootstrap never ran — the hosts sat with Docker installed
and nothing else. This was invisible to every static check; it only shows up
with a real git on a real host.

**Fix.** `git config --system --add safe.directory "$REPO_DIR"` immediately
after the `chown` in
[`terraform/templates/user_data.sh.tftpl`](../terraform/templates/user_data.sh.tftpl)
(system-wide so root, the role user and later `deploy.sh` all pass).
Because user-data is part of the instance definition
(`user_data_replace_on_change = true`), the fix was applied by letting
Terraform replace the three instances — about three minutes, and it proved
the "rebuild from git" property rather than hand-patching live hosts.

**Lesson.** Any script that changes a checkout's owner and then runs git as
someone else needs `safe.directory`. Also: replacing instances to apply a
user-data fix is cheap here and is the honest test of reproducibility.

## 15. Jenkins LTS now requires Java 21

**Problem.** `jenkins.service` crash-looped on the freshly built management
host: `Running with Java 17 ... older than the minimum required version
(Java 21). Supported Java versions are: [21, 25]`. The bootstrap installed
`java-17-amazon-corretto-headless`, which was correct when the design was
written and is not any more — the LTS line moved its floor to Java 21 in
2025. This was exactly the "plugin/package versions unverified" risk the
README listed.

**Fix.** `java-21-amazon-corretto-headless` (available in the AL2023 repo)
in [`scripts/bootstrap/management.sh`](../scripts/bootstrap/management.sh).

**Lesson.** Anything installed as "latest" (Jenkins LTS, its plugins) has a
moving set of prerequisites; the bootstrap log's first Jenkins start is the
place to look when the UI never answers.

## 16. Jenkins built-in node offline: AL2023 `/tmp` is a small tmpfs

**Problem.** Jenkins started, JCasC applied, the multibranch job discovered
`main` and queued build #1 — which sat at *Waiting for next available
executor* forever. The node monitor had taken the built-in node offline:
`Disk space is below threshold of 1.00 GiB. Only 950.13 MiB out of 954.88
MiB left on /tmp`. Amazon Linux 2023 mounts `/tmp` as a tmpfs sized to half
the RAM; on a t3.small that is under Jenkins' default 1 GiB temp-space
threshold, so a perfectly healthy controller refuses to run anything.

**Fix.** `-Djava.io.tmpdir=/var/lib/jenkins/tmp` in the systemd override
written by the bootstrap, so Jenkins' temp space (and its monitor) live on
the 30 GB root volume. Lowering the threshold in JCasC would also work but
would leave builds writing into a 950 MiB RAM disk.

**Lesson.** "Queued but never starts" is a node-availability problem before
it is a pipeline problem: check `/computer/api/json` for `offlineCauseReason`
first.

