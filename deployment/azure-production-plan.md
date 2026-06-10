# Azure Production Deployment Plan

Reference architecture for moving AMS.API + Postgres off the VPS to Azure managed services. Grounded in the actual application — Clean Architecture .NET 10 API, EF Core + Postgres, ASP.NET Identity + JWT, Azure Blob + Azure Service Bus already in use, 5 hosted background workers, Cloudflare DNS / Pages already in front for the PWA.

Pairs with [`cloudflare-pages-setup.md`](./cloudflare-pages-setup.md) (the frontend stays on Cloudflare Pages — no reason to move it) and [`multi-tenant-subdomain-access.md`](../architecture/multi-tenant-subdomain-access.md).

---

## 1. High-level architecture

```
                      Cloudflare (DNS + WAF + DDoS)
                                 |
                  +--------------+--------------+
                  |                             |
        portal.classpass.lk           api.classpass.lk
        *.classpass.lk
                  |                             |
        Cloudflare Pages              Azure Front Door (optional)
        (PWA — unchanged)                       |
                                       App Service Plan — Linux P1v3
                                       +---------------------+----------------+
                                       |  AMS.Api (HTTP)     |  AMS.Worker    |
                                       |  autoscale 1..5     |  fixed 1 inst  |
                                       +---------------------+----------------+
                                                        |
                                       Managed Identity (no secrets)
                                                        |
       +---------------------+-------------------+-------+-------+--------------+
       |                     |                   |               |              |
  Postgres Flex SS    Service Bus Std       Blob Storage    Key Vault    App Insights
  ZRS HA, PITR        4 topics             documents,       jwt, google,  + Log Analytics
                      (existing)           audit            smtp
```

Two App Service instances on one Linux App Service Plan: the **API** (autoscales) and a **single-instance Worker** that owns the 5 hosted services (so they don't duplicate-fire when the API scales out). Data, secrets, and observability are all locked behind VNet + Managed Identity — no connection strings on disk.

---

## 2. Region

**Recommend: Southeast Asia (Singapore).** Closest fully-featured region to Sri Lanka; all required services GA there (Postgres Flexible Server, Service Bus, Container Apps, App Insights). South India is closer but has narrower SKU availability for PG Flex HA. Cloudflare's PoP in Colombo terminates user requests anyway, so the extra ~70 ms to Singapore vs Mumbai isn't user-visible.

---

## 3. Resource layout

One resource group per environment, geo-suffix for clarity, hyphenated names that match Azure resource naming rules.

```
rg-ams-prod-sea
├─ plan-ams-prod-sea            App Service Plan (Linux, P1v3)
├─ app-ams-api-prod-sea         App Service — AMS.Api
├─ app-ams-worker-prod-sea      App Service — AMS.Worker (single instance)
├─ pg-ams-prod-sea              PostgreSQL Flexible Server (GP D2ds_v5, ZRS)
├─ sb-ams-prod-sea              Service Bus namespace (Standard)
├─ st-amsprodsea                Storage Account (Blob — documents)
├─ kv-ams-prod-sea              Key Vault
├─ log-ams-prod-sea             Log Analytics workspace
├─ appi-ams-prod-sea            Application Insights (workspace-based)
├─ vnet-ams-prod-sea            VNet
│   ├─ snet-app-integration     /27 — App Service VNet integration
│   ├─ snet-pe                  /27 — Private Endpoints
│   └─ snet-jobs                /27 — Container App Job (migrations)
├─ caenv-ams-prod-sea           Container Apps Environment (for migration jobs)
└─ cae-ams-migrate-prod-sea     Container App Job — EF migrations
```

Lower envs (`-dev-sea`, `-stg-sea`) are smaller-SKU clones in their own RGs. Same names, same shape — only SKUs differ.

---

## 4. Compute — API + Worker

### Why split API and Worker

`AMS.Infrastructure.DependencyInjection.AddServices()` registers 5 `IHostedService` workers — `IdentityMatchingWorker`, `CardExpiryWorker`, `LowAttendanceAlertWorker`, `WeeklyAttendanceSummaryWorker`, `AttendanceAutoCheckoutWorker`. Each replica that runs the host runs all five. Once the API scales out, every worker fires from every replica → duplicate emails, duplicate auto-checkouts, etc.

**Fix:** extract them into a separate `AMS.Worker` host that does *not* call `app.MapControllers()` and is deployed as its own App Service with `WEBSITES_INSTANCE_ID`-based scaling **off**. Both apps share `AMS.Application` + `AMS.Infrastructure`, the only difference is `Program.cs`.

```
AMS.API/
├─ AMS.Api/            <- existing — HTTP host, drop AddHostedService calls
├─ AMS.Worker/         <- NEW — hosted-services-only entrypoint
├─ AMS.Application/    <- shared
├─ AMS.Infrastructure/ <- shared (split AddHostedService block into AddWorkerHostedServices)
├─ AMS.Domain/         <- shared
```

`AddInfrastructure(...)` exposes two methods: `AddInfrastructure(...)` for the API (no workers), `AddWorkerHostedServices(...)` for the Worker. Migration is mechanical — no logic changes.

### SKU sizing (production launch)

| Resource | SKU | Why |
|---|---|---|
| App Service Plan | **P1v3 (Linux)** — 2 vCPU / 8 GB | Premium V3 is the cheapest tier with VNet integration, deployment slots, and zone redundancy options. Standard S1 also works but Premium V3 prices closer (~$0.124/h) and has better cold-start behaviour. |
| `app-ams-api` | Always On, HTTP/2, **Autoscale 1..5** on CPU>70% | Stateless API — scale-out is safe (slug resolver cache TTLs at 60 s). |
| `app-ams-worker` | Always On, **fixed 1 instance**, autoscale OFF | Workers are not idempotent across replicas; a single instance is the simplest safe topology. |

If/when scale-out the workers is required, KEDA-style queue-depth scaling on Container Apps is the natural next step — but only do that once the workers are actually queue-driven (today they're cron-style timers).

### Deployment slots

Both apps get **one** non-prod slot (`staging`):

1. CI deploys to `staging` slot.
2. Health probe + smoke runs against `https://app-ams-api-prod-sea-staging.azurewebsites.net`.
3. `az webapp deployment slot swap` flips slots — zero-downtime cutover.
4. Slot-specific app settings keep `ASPNETCORE_ENVIRONMENT=Staging` for the slot so config loads aren't mixed.

---

## 5. Database — Postgres Flexible Server

EF Core + Npgsql is already in `AddDatabaseService(...)`. The connection string is the only thing that changes.

### SKU + topology

| Setting | Value | Notes |
|---|---|---|
| Tier | **General Purpose, D2ds_v5** (2 vCore / 8 GB) | Burstable B2s/B4ms is fine for dev/stg; GP for prod because of better IO and HA support. |
| Storage | 64 GB Premium SSD, autogrow ON | Grows in 32 GB steps. Cap at 1 TB to bound cost. |
| HA | **Zone-redundant HA** | Standby in a different AZ; 1-minute failover. Costs ~2×; required for "production" stamp. |
| Backups | Point-in-time, **35 days** | Maximum retention; geo-redundant if compliance asks. |
| Postgres version | **16** | Matches the Npgsql.EntityFrameworkCore.PostgreSQL version in use. |
| Networking | **Private access (VNet integrated)** — `snet-pe` | Public access disabled. |
| Extensions | `pg_stat_statements`, `uuid-ossp` if migrations need it | Enable via server parameters. |

### Connection string

Pulled from Key Vault, injected as `ConnectionStrings__DefaultConnection`:

```
Host=pg-ams-prod-sea.postgres.database.azure.com;Database=ams_prod;
Port=5432;Username=ams_app;Password=<from KV>;SslMode=Require;TrustServerCertificate=false;
Pooling=true;MinPoolSize=1;MaxPoolSize=20;
```

Both `app-ams-api` and `app-ams-worker` share the same connection string; pooling is per-process.

### Migration runner

Auto-migrate on startup is **off** in production (`app.ApplyMigrations()` only runs in Dev — keep it that way). Instead:

1. Build a tiny migrations container from the existing solution: `dotnet ef migrations bundle -o efbundle --self-contained`.
2. Deploy as `cae-ams-migrate-prod-sea` — a **Container App Job** in `snet-jobs`, manual-trigger.
3. CI pipeline step: `az containerapp job start --name cae-ams-migrate-prod-sea` before the slot swap. Job pulls the connection string from Key Vault via Managed Identity, runs the bundle, exits.

Container App Jobs are the right tool here: VNet-attached, run-to-completion, no idle cost, exit codes propagate cleanly to GitHub Actions.

### Backup / restore

- PITR retention 35 days (configured at server level).
- Manual on-demand backup before each schema-altering release: `az postgres flexible-server backup create`.
- Quarterly DR drill: restore latest backup into `rg-ams-drtest-sea`, smoke-test, delete.

---

## 6. Storage, Service Bus, Key Vault

Already in use; switch the access path.

### Blob storage

- `st-amsprodsea` — Standard LRS (ZRS if uptime SLO matters more than the price delta).
- Containers stay as they are; `DocumentStorageService.UploadAsync` doesn't change.
- **Drop the connection string** from config. Use Managed Identity + `BlobServiceClient(new Uri(...), new DefaultAzureCredential())`.
- Lifecycle: move blobs in `documents` to Cool tier after 90 days, Archive after 365.

### Service Bus

- `sb-ams-prod-sea` — **Standard** tier (4 topics, modest message volume → Premium is overkill).
- Topics + subscriptions already named in `appsettings.json` (`transaction-events`, `charging-events`, `notification-events`, `identity-events`) — recreate them with the same names.
- `AddAzureServiceBusService(...)` already checks `UseManagedIdentity` — flip it on in prod and switch the registration to `new ServiceBusClient(fullyQualifiedNamespace, new DefaultAzureCredential())`.

### Key Vault

Holds every secret currently in `api.env.template`:

| Vault secret | Maps to env var |
|---|---|
| `pg-connection-string` | `ConnectionStrings__DefaultConnection` |
| `jwt-secret-key` | `Jwt__SecretKey` |
| `mediatr-license-key` | `MediatR__LicenseKey` |
| `google-client-secret` | `GoogleAuth__ClientSecret` |
| `smtp-password` | `Email__SmtpPassword` |
| `azure-blob-connection-string` | (deprecated — drop in favour of MI) |
| `service-bus-connection-string` | (deprecated — drop in favour of MI) |

App Service references them via the `@Microsoft.KeyVault(VaultName=...;SecretName=...)` syntax. RBAC grant: `Key Vault Secrets User` to the App Service Managed Identities.

---

## 7. Identity & secrets — Managed Identity, no secrets on disk

System-assigned Managed Identity on both `app-ams-api` and `app-ams-worker`. RBAC grants:

| Identity | Resource | Role |
|---|---|---|
| `app-ams-api` MI | `pg-ams-prod-sea` | `ams_app` PG role (Entra ID auth — optional, password fallback fine for v1) |
| `app-ams-api` MI | `st-amsprodsea` | Storage Blob Data Contributor |
| `app-ams-api` MI | `sb-ams-prod-sea` | Azure Service Bus Data Sender + Receiver |
| `app-ams-api` MI | `kv-ams-prod-sea` | Key Vault Secrets User |
| `app-ams-worker` MI | (same set) | (same roles) |

`DefaultAzureCredential` picks the MI up automatically in `BlobServiceClient` and `ServiceBusClient`. Code changes are tiny — already partly anticipated by the `UseManagedIdentity` flag in `AzureServiceBus` config.

**JWT signing key**: stays a Key Vault secret for v1. Future hardening: move to a Key Vault `key` and sign with `KeyVaultSecurityKey` — eliminates the secret-rotation-on-disk path entirely.

---

## 8. Networking

### Inbound (PWA → API)

Cloudflare already proxies (orange cloud). Two options for the App Service inbound:

| Option | When to pick |
|---|---|
| **Cloudflare → App Service public endpoint, with Access Restrictions allowing only Cloudflare IPs** | Simpler. Matches what nginx does today (Cloudflare-IP-only). What I'd recommend for v1. |
| **Cloudflare → Azure Front Door → App Service private endpoint** | Picks up Front Door's WAF, but doubles the inbound infra cost. Pick this when compliance asks for Azure-native WAF. |

For v1, App Service **Access Restrictions** with Cloudflare's published v4 + v6 ranges (same list already in `appsettings.Production.json` under `Cloudflare:KnownNetworks`) + a service tag for `AzureFrontDoor.Backend` if/when added. Origin TLS: App Service Managed Certificate for `api.classpass.lk` — free, auto-renewing.

### Outbound (API → data services)

- **VNet integration** on both App Services into `snet-app-integration` (regional VNet integration, no gateway needed on P1v3).
- **Private Endpoints** for Postgres, Service Bus, Blob Storage, Key Vault in `snet-pe`.
- Private DNS zones (`privatelink.postgres.database.azure.com`, `privatelink.servicebus.windows.net`, `privatelink.blob.core.windows.net`, `privatelink.vaultcore.azure.net`) linked to the VNet.
- **Public network access OFF** on all data services. Anything talking to PG / Blob / SB / KV comes through the VNet.

### Forwarded headers

`Program.cs` already calls `UseForwardedHeaders` with Cloudflare's known networks for the multi-tenant resolution flow. No changes required.

---

## 9. Observability

### Logging

Serilog already wired (`Serilog.AspNetCore`, `Serilog.Sinks.Seq` for dev). For Azure:

- Add `Serilog.Sinks.ApplicationInsights` to `AMS.Api.csproj`.
- Configure in `appsettings.Production.json`:
  ```jsonc
  "Serilog": {
    "WriteTo": [
      { "Name": "Console" },
      { "Name": "ApplicationInsights",
        "Args": { "telemetryConverter": "Serilog.Sinks.ApplicationInsights.TelemetryConverters.TraceTelemetryConverter, Serilog.Sinks.ApplicationInsights" } }
    ]
  }
  ```
- Connection string lives in `APPLICATIONINSIGHTS_CONNECTION_STRING` (auto-injected when App Insights is linked to the App Service).
- Existing structured log properties (`InstituteId`, `InstituteContextSource`, `TenantHostSlug`, `IsSuperAdmin`, `RequestId`) flow through unchanged — they appear as `customDimensions` in App Insights.

### Metrics + dashboards

- **App Insights workbook**: rps, p50/p95/p99 latency, 4xx/5xx ratio, dependency duration to PG/Blob/SB, top failing endpoints.
- Pre-built **Service Bus** + **PostgreSQL Flex** dashboards from the Azure portal.
- Custom KQL alerts in Log Analytics:
  - 5xx ratio > 1% over 10 min
  - p95 latency > 1 s over 10 min
  - PG connection-pool exhaustion (Npgsql logs `Connection pool reached maximum size`)
  - Tenant token-mismatch rate > N/min (the new `tenant_token_mismatch` 403 — anomaly indicator)

### Tracing

OpenTelemetry SDK is straightforward to add later; for v1 App Insights' auto-instrumentation of HTTP, EF Core, and Azure SDK calls is enough.

---

## 10. CI/CD

Move off the current SCP-to-VPS GitHub Actions flow to App Service deploys via OIDC.

### One-time setup

1. Register a `prod` GitHub Environment (manual approval required).
2. Create an **Entra ID app registration** with federated credentials for `repo:<org>/<repo>:environment:prod`.
3. Grant the app registration `Contributor` on `rg-ams-prod-sea` (or scope tighter to App Service + Container App Job).

### Pipeline per push to `main`

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with: { dotnet-version: '10.0.x' }
      - run: dotnet test AMS.slnx --nologo
      - run: dotnet publish AMS.Api/AMS.Api.csproj -c Release -o publish/api
      - run: dotnet publish AMS.Worker/AMS.Worker.csproj -c Release -o publish/worker
      - run: dotnet ef migrations bundle --project AMS.Infrastructure --startup-project AMS.Api -o publish/efbundle --self-contained
      - uses: actions/upload-artifact@v4
        with: { name: build, path: publish/ }

  deploy:
    needs: build
    environment: prod
    runs-on: ubuntu-latest
    permissions: { id-token: write, contents: read }
    steps:
      - uses: actions/download-artifact@v4
      - uses: azure/login@v2
        with:
          client-id:        ${{ vars.AZURE_CLIENT_ID }}
          tenant-id:        ${{ vars.AZURE_TENANT_ID }}
          subscription-id:  ${{ vars.AZURE_SUBSCRIPTION_ID }}

      # 1. Apply schema migrations via the Container App Job
      - run: az containerapp job start --name cae-ams-migrate-prod-sea --resource-group rg-ams-prod-sea --wait

      # 2. Deploy both apps to their staging slots
      - uses: azure/webapps-deploy@v3
        with: { app-name: app-ams-api-prod-sea, slot-name: staging, package: build/api }
      - uses: azure/webapps-deploy@v3
        with: { app-name: app-ams-worker-prod-sea, slot-name: staging, package: build/worker }

      # 3. Smoke probe + slot swap
      - run: ./scripts/smoke.sh https://app-ams-api-prod-sea-staging.azurewebsites.net
      - run: az webapp deployment slot swap -n app-ams-api-prod-sea -g rg-ams-prod-sea --slot staging --target-slot production
      - run: az webapp deployment slot swap -n app-ams-worker-prod-sea -g rg-ams-prod-sea --slot staging --target-slot production
```

No SSH, no SCP, no PAT secrets, no shared SSH key on disk.

---

## 11. Cost envelope (USD, Southeast Asia, monthly, list price)

Rough order-of-magnitude for **production launch sized for a few thousand DAU across a handful of institutes**:

| Component | SKU | ~Monthly |
|---|---|---|
| App Service Plan P1v3 (Linux) | 1 instance baseline | $135 |
| PG Flex GP D2ds_v5 + ZRS HA, 64 GB | + 35-day PITR | $290 |
| Service Bus Standard | 4 topics | $10 |
| Blob Storage (LRS, < 100 GB) | + bandwidth | $5 |
| Key Vault | < 10k ops | $1 |
| Log Analytics + App Insights | 5 GB/day | $50 |
| Container App Job (migrations) | sporadic | < $1 |
| **Total** | | **~$500/mo** |

Bandwidth and PG IO scale linearly with load; expect another $50–$150/mo at moderate growth. Add ~$135 per additional API replica during autoscale peaks.

**Dev / stg** clones in the same subscription land at ~$80/mo each on Burstable B2s + smaller App Service Basic B1 — fine for non-prod.

---

## 12. Migration from VPS — phased

1. **Provision (zero traffic impact)** — Stand up all Azure resources via Bicep / Terraform. Verify with synthetic traffic against `https://app-ams-api-prod-sea.azurewebsites.net` (the *.azurewebsites.net hostname, not yet swapped).
2. **Dual-write to Blob + Service Bus (already Azure-hosted)** — these don't move; just confirm the new MI-based access works.
3. **Restore Postgres** — `pg_dump` from the VPS, `pg_restore` into Azure PG. Time the dump to estimate downtime window. Expect 1–3 minutes per GB.
4. **Cutover window (10–30 min downtime)**
   1. Put a Cloudflare "maintenance" page on `api.classpass.lk`.
   2. Final delta-dump from VPS PG → Azure PG.
   3. Run the EF migration job once against Azure PG (sanity).
   4. Flip Cloudflare DNS: `api.classpass.lk` A → App Service IP, or CNAME → `app-ams-api-prod-sea.azurewebsites.net`.
   5. Validate `/health` returns 200 from App Service.
   6. Remove the Cloudflare maintenance page.
5. **Decommission** — keep VPS running for 14 days as warm rollback. After two clean weeks: terminate, archive `/etc/ams/`, delete.

The PWA on Cloudflare Pages is unaffected throughout — only `api.classpass.lk` moves.

---

## 13. What changes in code

Small surface, mostly DI-level:

| File | Change |
|---|---|
| New project `AMS.Worker/` | Mirrors `AMS.Api/Program.cs` minus controllers/Swagger/CORS. Hosts the 5 `IHostedService`s. |
| `AMS.Infrastructure/DependencyInjection.cs` | Split `AddHostedService<...>()` block into `AddWorkerHostedServices(...)`. API DI no longer calls it. |
| `AMS.Infrastructure/DependencyInjection.cs::AddAzureBlobStorageService` | `new BlobServiceClient(new Uri(serviceUri), new DefaultAzureCredential())` when `Storage:UseManagedIdentity=true`. |
| `AMS.Infrastructure/DependencyInjection.cs::AddAzureServiceBusService` | Honour the existing `UseManagedIdentity` flag — `new ServiceBusClient(fullyQualifiedNamespace, new DefaultAzureCredential())`. |
| `AMS.Api.csproj` + `AMS.Worker.csproj` | Add `Serilog.Sinks.ApplicationInsights`, `Microsoft.ApplicationInsights.AspNetCore`, `Azure.Identity`. |
| `appsettings.Production.json` | Replace direct connection strings with the Key Vault reference syntax in App Service config (not committed). Add the App Insights sink block. |
| `Program.cs` | `builder.Services.AddApplicationInsightsTelemetry()` + `builder.Configuration.AddAzureKeyVault(...)` (or pure App Service KV reference). |

Everything else — Clean Architecture layers, CQRS handlers, EF migrations, tenant middleware — stays as is.

---

## 14. Open decisions / risks

| Risk | Mitigation |
|---|---|
| Workers in a single App Service instance = SPOF for scheduled jobs | App Service auto-heals on crash; missed runs are eventually idempotent (auto-checkout / card expiry sweeps re-scan on the next interval). Acceptable for v1. |
| `IMemoryCache` slug resolver per replica | Documented in the multi-tenant plan. 60s TTL bounds staleness. Move to Redis if/when latency complaints surface. |
| Cold start on slot swap | Use **Warmup** in App Service deployment slot settings; hit `/health` and `/api/auth/me` (without token, expecting 401) before swap. |
| Outbound Gmail SMTP from App Service | Microsoft blocks port 25; 587 STARTTLS works. Verify before cutover, or switch to Azure Communication Services Email. |
| Region drift on data services if accidentally provisioned in different zones | Bicep / Terraform enforces region; manual portal provisioning is the risk surface — avoid. |
| Bicep / Terraform module choice | Bicep keeps everything in one Azure-native tool; Terraform is more portable. Pick one and stick with it for IaC consistency. |

---

## 15. What I'd execute first

1. Spin up `rg-ams-dev-sea` end-to-end via Bicep — App Service + PG Flex + KV + SB + Blob + AI — pointed at a fresh empty DB. Smoke the API.
2. Add the `AMS.Worker` project and split the hosted services. Verify both processes share `AMS.Application` cleanly.
3. Stand up the Container App Job for migrations and run it against the dev DB.
4. Cut a `staging` slot and the GitHub Actions OIDC pipeline.
5. Once dev is green for a week, repeat for `prod`, then do the Postgres `pg_dump | pg_restore` cutover.

Steps 1–4 are zero customer impact and can land alongside the existing VPS deployment. Step 5 is the only step that needs the maintenance window.
