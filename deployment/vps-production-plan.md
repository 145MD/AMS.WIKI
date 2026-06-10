# VPS Production Deployment Plan (Hostinger / Ubuntu)

Production deployment plan for the **initial AMS launch** on a single dedicated Hostinger Ubuntu VPS. Chosen over Azure for v1 on cost grounds, given a limited initial user base. Grounded in the actual application: Clean Architecture **.NET 10** API, EF Core + **PostgreSQL**, ASP.NET Identity + JWT, 5 in-process hosted workers, and **Azure Blob Storage** for documents (the only external cloud dependency we keep).

This is the **v1 target**. When load or reliability requirements outgrow a single box, the lift-and-shift path is documented in [`azure-production-plan.md`](./azure-production-plan.md). The PWA already lives on Cloudflare Pages and does **not** move — see [`cloudflare-pages-setup.md`](./cloudflare-pages-setup.md). DNS/TLS shape is set by [`multi-tenant-subdomain-access.md`](../architecture/multi-tenant-subdomain-access.md).

**Key decisions baked into this plan:**

| Decision | Choice | Section |
|---|---|---|
| Document storage | **Azure Blob Storage** (kept as-is) | [§7](#7-azure-blob-storage-documents) |
| Database | **PostgreSQL on the VPS** | [§6](#6-postgresql-on-vps) |
| Message broker (identity matching) | **Self-hosted RabbitMQ on the VPS** — requires a code change | [§8](#8-message-broker-rabbitmq--code-change-required) |
| Schema migrations | **EF migrations bundle run from CI/CD** | [§10](#10-database-migrations--permission-seeding) |
| Backups | **Full**: nightly logical dump + offsite to Blob + pgBackRest PITR + VM snapshots | [§12](#12-backups--disaster-recovery) |

---

## 1. High-level architecture

```
                         Cloudflare (DNS + WAF + TLS + DDoS)
                                     | orange-cloud proxy
                  +------------------+-------------------+
                  |                                      |
        portal.classpass.lk                       api.classpass.lk
        *.classpass.lk                                  |
                  |                                      v
        Cloudflare Pages                       ┌──────────────────────────────┐
        (PWA — unchanged)                      │      Hostinger Ubuntu VPS      │
                                               │                                │
                                               │  nginx :443/:80 (reverse proxy)│
                                               │        │                       │
                                               │        ▼                       │
                                               │  Kestrel — AMS.Api :5000       │
                                               │   • HTTP API + 5 hosted workers│
                                               │        │            │          │
                                               │        ▼            ▼          │
                                               │  PostgreSQL 16   RabbitMQ      │
                                               │  (localhost)     (localhost)   │
                                               └────────┬───────────────────────┘
                                                        │ outbound only
                                          ┌─────────────┼───────────────┐
                                          ▼             ▼               ▼
                                   Azure Blob      SMTP (Gmail)   Azure Blob
                                   (documents)     587 STARTTLS   (DB backups)
```

Everything stateful runs on one box (API, Postgres, RabbitMQ). The only outbound dependencies are Azure Blob (document storage + offsite backups) and SMTP (notifications). Cloudflare proxies every inbound request, so the VPS only ever needs ports 80/443 open to Cloudflare's IP ranges.

**Why a single box is fine for v1:** the 5 hosted workers (`IdentityMatchingWorker`, `CardExpiryWorker`, `LowAttendanceAlertWorker`, `WeeklyAttendanceSummaryWorker`, `AttendanceAutoCheckoutWorker`) run **in-process**. On one instance there is no duplicate-firing risk — the exact problem the Azure plan has to solve by splitting out an `AMS.Worker`. Here we get it for free.

---

## 2. Hostinger VPS — plan & OS

> Verify the current Hostinger KVM lineup at purchase time; specs below reflect the typical tiers.

| Plan | vCPU / RAM / Disk | Fit |
|---|---|---|
| KVM 1 | 1 / 4 GB / 50 GB NVMe | Too tight — Postgres + .NET + RabbitMQ will contend. Avoid for prod. |
| **KVM 2** | **2 / 8 GB / 100 GB NVMe** | **Recommended starting point.** Comfortable for API + PG + RabbitMQ at a low/limited initial load. |
| KVM 4 | 4 / 16 GB / 200 GB | Headroom option if you expect rapid early growth or run heavy reports. |

- **OS:** Ubuntu **24.04 LTS** (long-term support through 2029; ships .NET-friendly toolchain and PostgreSQL 16-compatible PGDG packages).
- **Location:** pick the Hostinger region closest to Sri Lanka (typically their India/Singapore datacenters). Cloudflare terminates users at the Colombo PoP regardless, so origin latency is mostly back-office.
- **Hostinger features to enable from hPanel:** weekly automatic **snapshots**, manual **snapshot** capability (used pre-release), and the **VPS firewall** (we layer UFW on-box as well). A dedicated IPv4 is included.

Disk budget on 100 GB: OS ~10 GB, Postgres data grows with enrollment/attendance volume, local backup staging area (`/var/backups/ams`) needs headroom for ~7 days of dumps + pgBackRest local cache. Monitor and alert at 80% (see [§13](#13-observability--monitoring)).

---

## 3. Initial server provisioning & hardening

Run as root on first login, then stop using root directly.

### 3.1 Patch + base packages

```bash
apt update && apt upgrade -y
apt install -y ufw fail2ban unattended-upgrades curl gnupg ca-certificates acl
```

### 3.2 Service/deploy user

A single non-root user owns deploys and runs the app (mirrors the existing `deployment/` assets).

```bash
adduser --disabled-password --gecos "" deploy
usermod -aG www-data deploy

mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
# Paste the CI deploy public key (and your admin key):
nano /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
```

Generate the CI deploy keypair on your machine (private half goes into GitHub Actions secrets, [§11](#11-cicd-github-actions)):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ams_deploy -C "ams-deploy-ci" -N ""
```

### 3.3 SSH hardening

Edit `/etc/ssh/sshd_config`:

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

```bash
systemctl restart ssh
```

Confirm you can log in as `deploy` in a **second** session **before** closing root — see [`server-lockout-recovery.md`](./server-lockout-recovery.md) if you ever get locked out.

### 3.4 Firewall (UFW) — Cloudflare-only ingress

Because Cloudflare proxies all web traffic, restrict 80/443 to Cloudflare's published ranges. This is a hard barrier against direct-to-origin attacks that bypass the WAF.

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH

# HTTP/HTTPS only from Cloudflare. Keep this list in sync with the
# Cloudflare:KnownNetworks block in appsettings.Production.json.
for cidr in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 \
  141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 \
  197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 \
  104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
    ufw allow from $cidr to any port 80 proto tcp
    ufw allow from $cidr to any port 443 proto tcp
done

ufw enable
```

> Postgres (5432) and RabbitMQ (5672/15672) are **never** opened in UFW — they bind to `localhost` only ([§6](#6-postgresql-on-vps), [§8](#8-message-broker-rabbitmq--code-change-required)).

### 3.5 Automatic security updates + fail2ban

```bash
dpkg-reconfigure -plow unattended-upgrades   # enable
systemctl enable --now fail2ban              # default sshd jail protects SSH
```

---

## 4. Runtime dependencies

```bash
# .NET 10 runtime (ASP.NET Core). Use the runtime, not the full SDK —
# the VPS does not build; CI publishes a framework-dependent bundle.
apt install -y dotnet-runtime-10.0 aspnetcore-runtime-10.0

# nginx reverse proxy + certbot (DNS-01 via Cloudflare)
apt install -y nginx certbot python3-certbot-dns-cloudflare
```

> If the distro feed lags on .NET 10, use Microsoft's `packages-microsoft-prod` feed or the bundled `dotnet-install.sh` (already in the repo root) pinned to `--channel 10.0 --runtime aspnetcore`.

Directory layout:

```bash
mkdir -p /var/www/ams-api /var/log/ams /etc/ams /var/backups/ams
chown -R deploy:www-data /var/www/ams-api
chown deploy:deploy /var/log/ams /var/backups/ams
chmod 750 /etc/ams
```

---

## 5. (reserved)

> The PWA tier requires **no VPS work** — it is served by Cloudflare Pages. See [`cloudflare-pages-setup.md`](./cloudflare-pages-setup.md). Section kept for numbering parity with the operator runbooks.

---

## 6. PostgreSQL on VPS

### 6.1 Install (PGDG, PostgreSQL 16)

```bash
install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
  https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
apt update && apt install -y postgresql-16
```

### 6.2 App role + database (least privilege)

The application connects as a **non-superuser** role that owns its own database.

```bash
sudo -u postgres psql <<'SQL'
CREATE ROLE ams_app LOGIN PASSWORD 'CHANGE_ME_STRONG';
CREATE DATABASE ams_prod OWNER ams_app;
\connect ams_prod
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
```

The connection string (`ConnectionStrings__DefaultConnection`) uses this role; it never needs superuser. A separate read-only `ams_backup` role is created in [§12](#12-backups--disaster-recovery).

### 6.3 Local-only + auth

In `/etc/postgresql/16/main/postgresql.conf`:

```
listen_addresses = 'localhost'
password_encryption = scram-sha-256
shared_preload_libraries = 'pg_stat_statements'
```

In `/etc/postgresql/16/main/pg_hba.conf`, ensure local TCP uses `scram-sha-256`:

```
host    ams_prod    ams_app       127.0.0.1/32    scram-sha-256
host    ams_prod    ams_backup    127.0.0.1/32    scram-sha-256
```

### 6.4 Tuning starting point (8 GB box, shared with API)

Conservative because the API and RabbitMQ share the box. Adjust with `pg_stat_statements` data after launch.

| Parameter | Value | Note |
|---|---|---|
| `shared_buffers` | `2GB` | ~25% RAM |
| `effective_cache_size` | `4GB` | planner hint; not allocated |
| `work_mem` | `16MB` | per-sort; raise cautiously |
| `maintenance_work_mem` | `256MB` | vacuum / index builds |
| `max_connections` | `100` | app pool caps at `MaxPoolSize=20` per process |
| `wal_level` | `replica` | required for pgBackRest PITR ([§12](#12-backups--disaster-recovery)) |

```bash
systemctl restart postgresql
```

---

## 7. Azure Blob Storage (documents)

No change to application code — `DocumentStorageService` keeps using `BlobServiceClient(connectionString)` (`AddAzureBlobStorageService` in `AMS.Infrastructure/DependencyInjection.cs`). For the VPS launch we stay on a **connection string** in `/etc/ams/api.env`; the Managed-Identity path is an Azure-migration concern.

Provisioning checklist (Azure portal / CLI):

- One **Standard** storage account, **LRS** is sufficient for v1 (consider **GRS** if document loss tolerance is low — these are the source of truth, not backed up elsewhere).
- Containers as the app expects (`ContainerStrategyService` drives naming).
- **Enable blob soft-delete + versioning** — cheap insurance against accidental deletes/overwrites.
- A **lifecycle rule**: documents → Cool tier after 90 days (optional cost trim).
- A **second container `db-backups`** for offsite database dumps ([§12](#12-backups--disaster-recovery)) — separate so a documents-lifecycle rule never touches backups.

Config keys already present in `appsettings.json` / `api.env.template`:

```
ConnectionStrings__AzureBlobStorage=DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...;EndpointSuffix=core.windows.net
```

---

## 8. Message broker (RabbitMQ) — code change required

**Why this exists:** identity auto-matching is event-driven. `ServiceBusIdentityEventPublisher` emits `IdentityMatchRequestedEvent` and `IdentityMatchingWorker` consumes it to auto-link / queue-for-review provisional students. Today both are **Azure Service Bus-specific**, and both **silently disable themselves when no Service Bus connection string is present** (the publisher no-ops; the worker logs `"Service Bus not configured. IdentityMatchingWorker is disabled."` and returns). So on a Blob-only VPS, **provisional students would never get matched** — they'd sit `IsLinkPending` forever.

Decision for v1: **self-host RabbitMQ on the VPS** and add a broker-agnostic implementation behind config. The Azure Service Bus implementation is retained for the future migration ([`azure-production-plan.md`](./azure-production-plan.md)).

### 8.1 Install + harden RabbitMQ

```bash
apt install -y rabbitmq-server
systemctl enable --now rabbitmq-server

# App user, drop the default guest account (guest can't be remote anyway, but remove it)
rabbitmqctl add_user ams_app 'CHANGE_ME_STRONG'
rabbitmqctl set_permissions -p / ams_app ".*" ".*" ".*"
rabbitmqctl delete_user guest
```

RabbitMQ binds to `localhost` by default for AMQP (5672) and the management UI (15672). Keep it that way — **do not** open these in UFW. The app connects over `localhost`.

### 8.2 Required code change (tracked work item)

Introduce a broker abstraction selected by config, with a RabbitMQ implementation that mirrors the existing Service Bus semantics (durable queue, manual ack, dead-letter after retries):

| Item | Change |
|---|---|
| Config | Add `MessageBroker:Provider = RabbitMq \| AzureServiceBus \| None` + a `RabbitMq` connection block. |
| `AddAzureServiceBusService(...)` → generalize | In `AMS.Infrastructure/DependencyInjection.cs`, branch on `MessageBroker:Provider` to register either the Service Bus client or a `RabbitMQ.Client` `IConnection`. |
| Publishers | Add `RabbitMqIdentityEventPublisher : IIdentityEventPublisher` and `RabbitMqNfcEventPublisher : INfcEventPublisher`. Keep the existing `ServiceBus*` impls. Register whichever matches the provider. |
| Worker | Add a RabbitMQ consumer path (refactor `IdentityMatchingWorker` to consume from a durable queue, prefetch=1, manual ack, dead-letter exchange after 3 deliveries — mirrors current `MaxConcurrentCalls=1` / `AutoCompleteMessages=false` / DLQ-after-3 behavior). |

Suggested RabbitMQ topology for identity events:

```
exchange  ams.identity        (direct, durable)
  └── queue  identity-match    (durable)  ── x-dead-letter-exchange ─▶ ams.identity.dlx
exchange  ams.identity.dlx     (fanout, durable)
  └── queue  identity-match.dlq (durable)
```

Effort: ~1–2 days including tests. **Until this lands, identity matching stays dormant** — same functional gap as launching without any broker. Track it as a go-live prerequisite if identity matching is in scope for launch; otherwise it can follow shortly after.

> NFC/attendance events (`ServiceBusNfcEventPublisher`) currently have no VPS-side consumer; publishing them to RabbitMQ is fire-and-forget and harmless. Wire consumers only when a downstream actually needs them.

---

## 9. Application config, secrets & nginx/TLS

### 9.1 Secrets — `/etc/ams/api.env`

Production secrets live in an env file loaded by systemd (ASP.NET maps `__` → `:`). Start from [`api.env.template`](./api.env.template) and add the broker block:

```bash
cp /tmp/api.env.template /etc/ams/api.env   # then fill in CHANGE_ME values
chmod 600 /etc/ams/api.env
chown deploy:deploy /etc/ams/api.env
```

Minimum production keys:

```ini
ConnectionStrings__DefaultConnection=Host=localhost;Port=5432;Database=ams_prod;Username=ams_app;Password=...
ConnectionStrings__AzureBlobStorage=DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...;EndpointSuffix=core.windows.net
Jwt__SecretKey=<min 32 chars>
MediatR__LicenseKey=...
Email__SmtpUsername=...
Email__SmtpPassword=...
GoogleAuth__ClientId=...        # optional — omit to disable Google sign-in
GoogleAuth__ClientSecret=...
Tenant__RootHostSuffix=classpass.lk
Tenant__AdminSubdomain=portal
# Broker (after §8 lands):
MessageBroker__Provider=RabbitMq
RabbitMq__HostName=localhost
RabbitMq__UserName=ams_app
RabbitMq__Password=...
```

Non-secret prod overrides are already committed in `appsettings.Production.json` (`AllowedOrigins`, `Tenant`, `Cloudflare:KnownNetworks`, Serilog file sink → `/var/log/ams/api.log`, 30-day retention). No change needed.

### 9.2 nginx + TLS

The API-only vhost is already written: [`ams-nginx.conf`](./ams-nginx.conf) (Cloudflare real-IP, `/health` carve-out, proxy to `127.0.0.1:5000`). Install it and issue the cert via DNS-01 (works through Cloudflare's proxy without exposing port 80 publicly) exactly as in [`cloudflare-pages-setup.md` §3](./cloudflare-pages-setup.md):

```bash
cp ams-nginx.conf /etc/nginx/sites-available/api.classpass.lk
ln -s /etc/nginx/sites-available/api.classpass.lk /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# DNS-01 cert (scoped Cloudflare token, Zone:DNS:Edit on classpass.lk)
install -m 600 /dev/null /etc/letsencrypt/cloudflare.ini
echo "dns_cloudflare_api_token = <token>" > /etc/letsencrypt/cloudflare.ini
certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d api.classpass.lk --non-interactive --agree-tos -m ops@classpass.lk \
  --deploy-hook 'systemctl reload nginx'
```

Set Cloudflare SSL/TLS mode to **Full (Strict)** so the CF→origin hop validates the Let's Encrypt cert.

> `JwtBearer.RequireHttpsMetadata=false` is set in code. That is acceptable here because TLS is terminated at Cloudflare and again at nginx; Kestrel only ever receives loopback traffic. Leave it.

---

## 10. Database migrations & permission seeding

Production must **not** auto-migrate: `Program.cs` calls `ApplyMigrations()` **and** `SeedPermissionsAsync()` only inside `if (app.Environment.IsDevelopment())`. A fresh prod DB gets neither automatically.

### 10.1 Schema — EF migrations bundle from CI/CD

CI produces a self-contained bundle (no SDK/EF tools needed on the VPS), ships it, and runs it against the prod DB **before** restarting the service:

```bash
# In CI (build job):
dotnet ef migrations bundle \
  --project AMS.Infrastructure --startup-project AMS.Api \
  --self-contained -r linux-x64 -o efbundle

# On the VPS (deploy job), reads the same env the app uses:
export $(grep -v '^#' /etc/ams/api.env | xargs -d '\n')
./efbundle --connection "$ConnectionStrings__DefaultConnection"
```

### 10.2 Permission seeding — one-time + re-runnable

`SeedPermissionsAsync()` is idempotent (upserts permission/role-permission rows) but is currently Dev-gated. New permission constants get added across releases, so seeding should run on **every** deploy, not just once.

**Required small code change:** add a startup arg so seeding can be invoked explicitly and exits — e.g. `dotnet AMS.Api.dll --seed-permissions` runs `SeedPermissionsAsync()` then returns. The deploy pipeline calls it right after the migration bundle, before the slot/service restart. This keeps seeding out of the normal request-serving boot path while ensuring new permissions land every release.

Deploy order each release: **migrate → seed permissions → restart `ams-api`** ([§11](#11-cicd-github-actions)).

---

## 11. CI/CD (GitHub Actions)

Keep the lightweight SCP + `systemctl restart` flow already described in [`DEPLOYMENT-GUIDE.md`](./DEPLOYMENT-GUIDE.md), extended with the migrate + seed steps. The API runs framework-dependent (runtime installed in [§4](#4-runtime-dependencies)).

**Secrets** (AMS.API repo → Settings → Secrets and variables → Actions): `VPS_HOST`, `VPS_SSH_KEY` (the `ams_deploy` private key).

Per push to `main`:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with: { dotnet-version: '10.0.x' }
      - run: dotnet test AMS.API/AMS.slnx --nologo
      - run: dotnet publish AMS.API/AMS.Api/AMS.Api.csproj -c Release -o publish
      - run: dotnet ef migrations bundle --project AMS.API/AMS.Infrastructure
             --startup-project AMS.API/AMS.Api --self-contained -r linux-x64 -o publish/efbundle
      - uses: actions/upload-artifact@v4
        with: { name: api, path: publish/ }

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { name: api, path: publish/ }
      # SCP publish/ -> /var/www/ams-api on the VPS (appleboy/scp-action or rsync over SSH)
      # then over SSH, as deploy:
      #   export $(grep -v '^#' /etc/ams/api.env | xargs -d '\n')
      #   /var/www/ams-api/efbundle --connection "$ConnectionStrings__DefaultConnection"
      #   dotnet /var/www/ams-api/AMS.Api.dll --seed-permissions
      #   sudo systemctl restart ams-api && sudo systemctl is-active ams-api
```

Grant the restart in `visudo`:

```
deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ams-api, /usr/bin/systemctl is-active ams-api
```

### systemd service

Install [`ams-api.service`](./ams-api.service). **Change `User=ubuntu` → `User=deploy`** to match this plan, then:

```bash
cp ams-api.service /etc/systemd/system/ams-api.service
systemctl daemon-reload && systemctl enable --now ams-api
```

The 5 hosted workers start with the API process — nothing extra to deploy.

---

## 12. Backups & disaster recovery

Full coverage, layered. The VPS is a single point of failure, so the priority is getting **data off the box** and proving we can **restore**.

| Layer | Tool | Frequency | Destination | Recovers |
|---|---|---|---|---|
| Logical DB dump | `pg_dump -Fc` (script below) | Nightly | Local + **Azure Blob** `db-backups` | Whole-DB, portable, version-independent |
| **PITR** | **pgBackRest** → Azure Blob | Full weekly + incr daily + continuous WAL | Azure Blob repo | Point-in-time to any second within retention |
| Whole-VM | Hostinger **snapshots** | Weekly auto + manual pre-release | Hostinger | Bare-metal rollback (OS + configs + data) |
| Config/secrets | encrypted tar (`age`) | Weekly + after changes | Azure Blob `db-backups/config` | `/etc/ams`, nginx, letsencrypt, systemd unit |
| Documents | Azure Blob soft-delete + versioning | Continuous | Azure (same/GRS) | Accidental document delete/overwrite |

### 12.1 Read-only backup role

```bash
sudo -u postgres psql -c "CREATE ROLE ams_backup LOGIN PASSWORD 'CHANGE_ME' IN ROLE pg_read_all_data;"
```

### 12.2 Nightly logical dump → Azure Blob

Ready-to-use assets ship alongside this plan:

- [`pg-backup.sh`](./pg-backup.sh) — `pg_dump -Fc`, gzip, local GFS retention (7 daily), upload to Azure Blob, optional dead-man's-switch ping.
- [`ams-pg-backup.service`](./ams-pg-backup.service) + [`ams-pg-backup.timer`](./ams-pg-backup.timer) — runs it nightly.

Install:

```bash
install -m 750 pg-backup.sh /usr/local/bin/pg-backup.sh
cp ams-pg-backup.service ams-pg-backup.timer /etc/systemd/system/
# Backup-only secrets (DB password + Azure storage creds), 600:
cat > /etc/ams/backup.env <<'EOF'
PGPASSWORD=...                         # ams_backup password
AZURE_STORAGE_CONNECTION_STRING=...    # or AZURE_STORAGE_ACCOUNT + SAS
BACKUP_CONTAINER=db-backups
HEALTHCHECK_URL=                       # optional healthchecks.io ping URL
EOF
chmod 600 /etc/ams/backup.env && chown deploy:deploy /etc/ams/backup.env
systemctl daemon-reload && systemctl enable --now ams-pg-backup.timer
```

Offsite **retention** is enforced by an Azure Blob **lifecycle rule** on `db-backups` (e.g. Cool after 30 days, delete after 180) — set once in the portal so the script stays simple and a compromised VPS can't purge history (combine with a **delete-lock / immutability** policy for ransomware resilience).

### 12.3 PITR with pgBackRest

For point-in-time recovery (recover to the moment *before* a bad migration or bulk delete):

```bash
apt install -y pgbackrest
```

`/etc/pgbackrest/pgbackrest.conf` — repo on Azure Blob, retention 2 full backups, WAL archived continuously:

```ini
[global]
repo1-type=azure
repo1-azure-account=<storage-account>
repo1-azure-container=pgbackrest
repo1-azure-key=<key>
repo1-retention-full=2
start-fast=y

[ams]
pg1-path=/var/lib/postgresql/16/main
```

Enable archiving in `postgresql.conf` (requires `wal_level=replica`, already set in [§6.4](#64-tuning-starting-point-8-gb-box-shared-with-api)):

```
archive_mode = on
archive_command = 'pgbackrest --stanza=ams archive-push %p'
```

```bash
sudo -u postgres pgbackrest --stanza=ams stanza-create
sudo -u postgres pgbackrest --stanza=ams --type=full backup   # seed; schedule weekly full + daily incr via timer
```

### 12.4 Config/secrets backup (encrypted)

`/etc/ams/api.env` holds live secrets, so it must be **encrypted before leaving the box**:

```bash
apt install -y age
# one-time: age-keygen -o /root/ams-backup.key  (store the PUBLIC key on the box, PRIVATE key offline)
tar czf - /etc/ams /etc/nginx/sites-available /etc/letsencrypt \
  /etc/systemd/system/ams-api.service \
| age -r <age-public-key> \
| az storage blob upload --container-name db-backups \
    --name "config/ams-config-$(date +%F).tar.gz.age" --data @- \
    --connection-string "$AZURE_STORAGE_CONNECTION_STRING"
```

### 12.5 Restore runbook + drills

- **Logical restore:** `pg_restore --clean --if-exists -d ams_prod latest.dump` (after `gunzip`).
- **PITR:** `pgbackrest --stanza=ams --type=time "--target=2026-05-28 14:30:00+05:30" restore`, then start Postgres in recovery.
- **Whole box:** restore the latest Hostinger snapshot, then re-apply the newest logical dump / PITR for the delta since the snapshot.
- **Monthly drill:** restore the latest dump into a scratch DB (`ams_drill`), run `SELECT count(*)` sanity checks against key tables, drop it. A backup you haven't restored is a hope, not a backup.

### 12.6 Backup monitoring

- `pg-backup.sh` pings a **healthchecks.io** check on success → alerts if a night is missed (dead-man's switch).
- Disk-space alert at 80% so backups never fill the volume ([§13](#13-observability--monitoring)).

---

## 13. Observability & monitoring

- **App logs:** Serilog file sink at `/var/log/ams/api.log` (daily roll, 30 retained — already in `appsettings.Production.json`) + journald (`journalctl -u ams-api`). Add a `logrotate` rule only if the Serilog rotation proves insufficient.
- **Uptime:** point UptimeRobot / healthchecks.io at `https://api.classpass.lk/health` (the Npgsql health check fails the endpoint if the DB is down). nginx serves `/health` with `access_log off`.
- **Host metrics:** install **netdata** (single binary, localhost dashboard behind SSH tunnel) for CPU/RAM/disk/IO at a glance. Lightweight enough for KVM 2.
- **Alerts to wire:** 5xx spike, `/health` down, disk > 80%, Postgres connection-pool exhaustion (`Npgsql ... pool reached maximum size` in logs), backup dead-man's switch.

---

## 14. Security hardening checklist

- [ ] Root SSH disabled, key-only auth, fail2ban active ([§3](#3-initial-server-provisioning--hardening)).
- [ ] UFW: only SSH + Cloudflare-IP-restricted 80/443. Postgres/RabbitMQ localhost-only.
- [ ] Cloudflare SSL **Full (Strict)**, WAF managed rules on, rate-limiting + Bot Fight Mode.
- [ ] `unattended-upgrades` enabled for security patches.
- [ ] `/etc/ams/api.env` and `/etc/ams/backup.env` are `chmod 600`, owned by `deploy`.
- [ ] Postgres app role is **not** superuser; backup role is read-only.
- [ ] RabbitMQ default `guest` user deleted; broker bound to localhost.
- [ ] JWT secret ≥ 32 chars (enforced at startup by `AddAuthenticationInternal`).
- [ ] Azure Blob: soft-delete + versioning on; backup container has a delete-lock/immutability policy.
- [ ] age private key for config backups stored **off** the VPS.

---

## 15. Cost envelope (USD, monthly, indicative)

| Component | ~Monthly |
|---|---|
| Hostinger KVM 2 (8 GB) | $7–$12 (lower on long terms) |
| Azure Blob — documents (< 100 GB, LRS) + bandwidth | $3–$8 |
| Azure Blob — DB backups + pgBackRest repo | $2–$5 |
| Domain (`classpass.lk`) | ~$2 amortized |
| Cloudflare (Free / Pro) | $0–$20 |
| **Total** | **~$15–$45/mo** |

Roughly an order of magnitude below the Azure plan's ~$500/mo — the explicit reason for choosing VPS for v1. RabbitMQ, Postgres, and nginx add **no** marginal cost (self-hosted on the box).

---

## 16. Go-live runbook (ordered)

1. Provision VPS, OS patch, harden ([§3](#3-initial-server-provisioning--hardening)).
2. Install .NET runtime, nginx, Postgres, RabbitMQ ([§4](#4-runtime-dependencies), [§6](#6-postgresql-on-vps), [§8](#8-message-broker-rabbitmq--code-change-required)).
3. Land the RabbitMQ broker code change + tests ([§8.2](#82-required-code-change-tracked-work-item)) — or consciously defer identity matching.
4. Land the `--seed-permissions` startup arg ([§10.2](#102-permission-seeding--one-time--re-runnable)).
5. Create DB, app role, backup role; apply tuning ([§6](#6-postgresql-on-vps)).
6. Put secrets in `/etc/ams/api.env`; install systemd unit (`User=deploy`).
7. Install nginx vhost + DNS-01 cert; Cloudflare DNS `A api → VPS IP` (proxied), SSL Full (Strict) ([§9.2](#92-nginx--tls)).
8. Run migration bundle → seed permissions → start `ams-api` ([§10](#10-database-migrations--permission-seeding)).
9. Smoke: `curl https://api.classpass.lk/health` = 200; sign in on `portal.classpass.lk`; tenant slug screen on `<slug>.classpass.lk`; upload a document (Blob); trigger a provisional enrollment and confirm identity-match consumption (if §8 landed).
10. Enable nightly DB backup timer + pgBackRest stanza; run one manual backup **and one restore drill** before declaring go-live ([§12](#12-backups--disaster-recovery)).
11. Wire uptime + disk + backup alerts ([§13](#13-observability--monitoring)).
12. Take a Hostinger **snapshot** as the clean baseline.

---

## 17. Operational runbook

```bash
# API
sudo systemctl restart ams-api
journalctl -u ams-api -f
tail -f /var/log/ams/api.log

# nginx
sudo nginx -t && sudo systemctl reload nginx
sudo tail -f /var/log/nginx/error.log

# Postgres
sudo -u postgres psql ams_prod
sudo systemctl status postgresql

# RabbitMQ
rabbitmqctl list_queues name messages consumers
sudo systemctl status rabbitmq-server

# Backups
systemctl list-timers ams-pg-backup.timer
sudo -u postgres pgbackrest --stanza=ams info
```

**Rollback a bad deploy:** redeploy the previous artifact (CI keeps it) → restart. If a migration corrupted data, use pgBackRest PITR to the timestamp just before the deploy ([§12.5](#125-restore-runbook--drills)). For catastrophic loss, restore the latest Hostinger snapshot and replay the newest dump/WAL.

---

## 18. Known limitations & the path to Azure

| Limitation | Status / mitigation |
|---|---|
| Single box = SPOF for API, DB, broker | Accepted for v1. Snapshots + offsite backups bound data loss; restore drills bound recovery time. Scale-out is the Azure trigger. |
| Identity matching needs the §8 code change | Tracked prerequisite. Dormant (no data loss) until it lands. |
| In-process workers tied to API lifecycle | Fine on one instance; the moment you run 2+ API instances they duplicate-fire — that is exactly when you execute [`azure-production-plan.md`](./azure-production-plan.md) (split `AMS.Worker`). |
| `IMemoryCache` slug resolver per process | Single process here, so no staleness across replicas. Revisit with Redis at scale. |
| Gmail SMTP deliverability/limits | Fine for low volume; move to a transactional provider (or Azure Communication Services) as send volume grows. |

When any of these bind, the migration is a DNS flip of `api.classpass.lk` from the VPS to Azure plus a `pg_dump | pg_restore` — the PWA on Cloudflare Pages is unaffected throughout.
