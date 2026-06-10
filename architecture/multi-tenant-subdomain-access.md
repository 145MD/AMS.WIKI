# Multi-Tenant Subdomain Access

Tenant-scoped URLs (`<slug>.classpass.lk`) with a dedicated system-admin root (`portal.classpass.lk`) and a single backend host (`api.classpass.lk`). Industry-standard pattern (Slack / Zendesk / Atlassian style) adapted to the existing AMS Clean Architecture solution.

This document is the source of truth for the rollout. It cross-references existing code so every "what changes" line is concrete.

---

## 1. Goals

- Each institute gets a dedicated, brandable URL: `royal-college.classpass.lk`.
- Privileged institute users land on a tenant-branded sign-in screen and, after login, see only their institute's nav — no switcher, no global-admin tabs.
- SystemAdmins (and anyone holding `institutes:access-any`) on a tenant subdomain are **scoped to that tenant**; they go to `portal.classpass.lk` for cross-tenant work.
- One API host serves every tenant. Token-vs-host mismatch is rejected server-side; the tenant **cannot be changed** while logged in via a tenant subdomain.
- The architecture survives a future VPS → Azure backend migration with config changes only.

## 2. Non-goals

- Custom per-institute apex domains (e.g. `portal.royal-college.lk`). Deferrable to a paid tier later.
- Cross-subdomain SSO. Cookies stay per-subdomain by design.
- Tenant-specific data residency. All tenants share one Postgres DB; isolation is logical via `InstituteId` columns + EF query filters (already in place).

## 3. Domain & hosting

### URL layout

| Host | Audience | Behaviour |
|---|---|---|
| `portal.classpass.lk` | SystemAdmins, multi-institute users | Existing experience: generic sign-in, institute switcher, all admin tabs. |
| `<slug>.classpass.lk` | Institute admins + privileged institute users | Branded sign-in; JWT bound to that institute; switcher hidden; tenant-scoped nav. |
| `api.classpass.lk` | Both PWA experiences | Single backend host. Dynamic CORS allows the root + every known tenant origin. |
| `www.classpass.lk` | — | 301 to `portal.classpass.lk`. |

Reserved subdomains (never assignable as slugs): `portal`, `api`, `www`, `app`, `admin`, `static`, `assets`, `cdn`, `mail`, `docs`, `status`, `pages`, `dev`, `staging`.

### Why single-level wildcard

Cloudflare's Universal SSL covers `*.classpass.lk` and `classpass.lk` for free. A two-level pattern (`*.app.classpass.lk`) would need Advanced Certificate Manager (~$10/mo).

### Hosting

- **DNS**: Cloudflare (domain registered at register.lk).
- **Frontend (AMS.PWA)**: Cloudflare Pages. The current Netlify free tier rejects unknown Host headers, and the Pro plan ($19/mo) trades real money for a worse fit than Pages (same vendor as DNS, native wildcards, unlimited bandwidth, free).
- **Backend (AMS.Api)**: .NET 9 on a VPS today (nginx → Kestrel, Let's Encrypt DNS-01 via Cloudflare). Designed to lift-and-shift to Azure App Service / Container Apps later; no code path is host-aware.
- **Storage**: already Azure Blob + Azure Service Bus (per `appsettings.json`).

---

## 4. Existing code we build on

The system already does most of the heavy lifting; this plan extends rather than replaces.

| Concept | Existing artefact | Notes |
|---|---|---|
| Tenant entity | `AMS.Domain/Entities/Institute/Entity/Institute.cs` | Has `Code`, `Name`, `LogoUrl`, `Settings (jsonb)`, `IsActive`. Adds `Slug` + `BrandingTheme`. |
| Repository | `AMS.Domain/Entities/Institute/Interfaces/IInstituteRepository.cs` + `AMS.Infrastructure/Repositories/Institute/InstituteRepository.cs` | Has `GetByCodeAsync`. Adds `GetBySlugAsync` / `ExistsBySlugAsync`. |
| EF config | `AMS.Infrastructure/EntityConfigurations/Institute/InstituteEntityConfig.cs` | Adds `slug` column + unique lowercase index, `branding_theme` jsonb. |
| Membership | `InstituteUser` + `IInstituteUserRepository.ExistsAsync` | Unchanged; remains the source of truth for "can this user act in this institute". |
| Tenant context | `AMS.Application/Interfaces/Institute/IInstituteContext.cs` + `AMS.Infrastructure/Services/Institute/InstituteContext.cs` | Precedence becomes: host > header > JWT claim. New `InstituteContextSource.Host`. |
| Enforcement | `AMS.Api/Middleware/InstituteContextEnforcementMiddleware.cs` | Adds host-vs-token mismatch check. Adds `/api/public` to exempt list. |
| Logging | `InstituteContextLoggingMiddleware` | Picks up the new source enum for free. |
| Login | `AMS.Application/Handlers/User/Commands/LoginApplicationUserCommand.cs` | Already accepts `Guid? InstituteId`. Controller now resolves from host or body slug. |
| Switch | `AMS.Application/Handlers/Auth/Commands/SwitchInstituteCommand.cs` | Add tenant-host rejection in handler. |
| Auth `/me` | `AuthController.GetCurrentUser` | Add `TenantSlug` field. |
| PWA auth store | `AMS.PWA/src/stores/auth-store.ts` | Add `canSwitchInstitute()` derived from host. |
| PWA api client | `AMS.PWA/src/lib/api-client.ts` | Stop sending `X-Institute-Id` header on tenant hosts (server ignores it anyway, but cleaner). |
| PWA switcher | `AMS.PWA/src/components/layout/institute-switcher.tsx` | Replaced by `InstituteBadge` on tenant hosts. |
| PWA sidebar | `AMS.PWA/src/components/layout/data/sidebar-data.ts` + `app-sidebar.tsx` | Items gain `requiredPermission` / `requiredRole` / `visibleOnRootOnly`; new `useSidebarData()` filters them. |
| PWA cookies | `AMS.PWA/src/lib/cookies.ts` | Already host-scoped (no `Domain=` attribute). Per-subdomain isolation works for free. |
| PWA SPA redirect | `AMS.PWA/netlify.toml` | Replaced by `public/_redirects`. |
| CORS | `AMS.Infrastructure/DependencyInjection.cs:708` (`AddCorsInternal`) | Already calls `SetIsOriginAllowedToAllowWildcardSubdomains()` — wildcard origin like `https://*.classpass.lk` just works. We add a delegate guard so unknown slugs are rejected and the `portal` origin is explicitly allowed. |
| nginx | `AMS.WIKI/deployment/ams-nginx.conf` | Today serves PWA + proxies API. Split: PWA moves to Cloudflare Pages; nginx becomes API-only at `api.classpass.lk`. |

---

## 5. Phase 0 — Infrastructure foundation

> Operator task list; not code.

### 5.1 Cloudflare DNS

| Type | Name | Target | Proxy |
|---|---|---|---|
| A | `api` | VPS public IP | ✅ proxied (orange cloud) |
| CNAME | `portal` | `<pages-project>.pages.dev` | ✅ proxied |
| CNAME | `*` | `<pages-project>.pages.dev` | ✅ proxied |
| CNAME | `www` | `portal.classpass.lk` | ✅ proxied |

### 5.2 TLS

- Universal SSL auto-provisions `*.classpass.lk` and `classpass.lk` — verify under **SSL/TLS → Edge Certificates**.
- VPS cert for `api.classpass.lk` via certbot + `python3-certbot-dns-cloudflare` plugin and a scoped Cloudflare API token (Zone:DNS:Edit on `classpass.lk` only).

### 5.3 Cloudflare Pages

- Connect AMS.PWA repo; build `npm run build`, output `dist`.
- Custom domains: `portal.classpass.lk`, `*.classpass.lk`, `www.classpass.lk`.
- Env vars: `VITE_API_BASE_URL=https://api.classpass.lk/api`, `VITE_ROOT_HOST=classpass.lk`, `VITE_ADMIN_SUBDOMAIN=portal`.

### 5.4 nginx on the VPS

Replace `AMS.WIKI/deployment/ams-nginx.conf` with an API-only vhost on `api.classpass.lk` that terminates TLS, proxies to Kestrel on `127.0.0.1:5000`, and trusts Cloudflare's published IP ranges as `set_real_ip_from`. The PWA `root` and SPA-fallback blocks come out — Pages serves the frontend.

### 5.5 Backend forwarded-headers

`Program.cs` must call `app.UseForwardedHeaders` before `UseAuthentication` so Kestrel honours `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Forwarded-Host` from Cloudflare. Restrict via `KnownNetworks` / `KnownProxies` to Cloudflare's published ranges.

### 5.6 Acceptance

```
curl https://api.classpass.lk/health                            # 200 from VPS
curl -I https://portal.classpass.lk                             # 200 from Pages
curl -I https://anything-unknown-yet.classpass.lk               # 200 (SPA), 404 inside app
```

---

## 6. Phase 1 — Domain & data

### 6.1 `Institute` entity (`AMS.Domain/Entities/Institute/Entity/Institute.cs`)

- New private setter `Slug` (string, required after backfill).
- New private setter `BrandingTheme` (string?, JSON: `{ accentColor, secondaryColor, tagline }`).
- `Create` overload accepts `slug`.
- Method `ChangeSlug(string newSlug)` raises `InstituteSlugChangedEvent` (domain event).
- Validation in the entity: regex `^[a-z][a-z0-9-]{1,38}[a-z0-9]$`; reject any value in `ReservedSlugs`.

### 6.2 Constants

- `AMS.Domain.Constants.ReservedSlugs` — `IReadOnlyCollection<string>` literal list (above).
- Mirror in PWA: `AMS.PWA/src/lib/reserved-slugs.ts` for client-side pre-check.

### 6.3 EF config (`InstituteEntityConfig.cs`)

```csharp
builder.Property(x => x.Slug)
    .HasColumnName("slug")
    .IsRequired()
    .HasMaxLength(40);
builder.Property(x => x.BrandingTheme)
    .HasColumnName("branding_theme")
    .HasColumnType("jsonb");
builder.HasIndex(x => x.Slug)
    .IsUnique()
    .HasDatabaseName("IX_Institutes_Slug");
```

Postgres index uses `LOWER(slug)` semantics via a check constraint or by always lower-casing on write (we lowercase in the entity). Single-column unique index is enough since the entity guarantees lowercase.

### 6.4 Repository (`IInstituteRepository`, `InstituteRepository`)

```csharp
Task<Institute?> GetBySlugAsync(string slug, CancellationToken ct = default);
Task<bool> ExistsBySlugAsync(string slug, CancellationToken ct = default);
```

### 6.5 Migration

`dotnet ef migrations add AddInstituteSlugAndBranding --project AMS.Infrastructure --startup-project AMS.Api`

- Add `slug` nullable, `branding_theme` jsonb nullable.
- Backfill `slug` from `LOWER(code)` (strip the `INST-` prefix if you want shorter slugs — confirm with stakeholders before deciding; default is to keep `inst-2026-0001` style and let admins rename later).
- Set NOT NULL on `slug`; add the unique index.

### 6.6 Tests (`AMS.Tests`)

- Slug regex accepts/rejects per spec.
- Reserved-slug rejection.
- `ChangeSlug` raises the domain event.
- `GetBySlugAsync` is case-insensitive in queries (`.ToLowerInvariant()` on input).

### 6.7 Acceptance

Dev DB migrates cleanly; every existing institute has a non-null slug; calling `GetBySlugAsync("inst-2026-0001")` returns the matching row.

---

## 7. Phase 2 — API tenant resolution

### 7.1 Slug resolver

`AMS.Application/Interfaces/Institute/IInstituteSlugResolver.cs`

```csharp
public interface IInstituteSlugResolver
{
    Task<InstituteSlugInfo?> ResolveAsync(string slug, CancellationToken ct);
    void Invalidate(string slug);
}
public sealed record InstituteSlugInfo(Guid Id, string Slug, bool IsActive);
```

Implementation in `AMS.Infrastructure/Services/Institute/InstituteSlugResolver.cs`. Backed by `IInstituteRepository` + `IMemoryCache` (60s sliding TTL). Invalidate from a `INotificationHandler<InstituteSlugChangedEvent>` and from create/deactivate handlers.

### 7.2 Tenant host context

`AMS.Application/Interfaces/Institute/ITenantHostContext.cs`

```csharp
public interface ITenantHostContext
{
    string? Slug { get; }
    Guid? InstituteId { get; }
    bool IsTenantHost { get; }
    bool IsRootHost { get; }   // portal.classpass.lk or apex
}
```

Implementation reads `HttpContext.Items[TenantContextKey]` set by the middleware below. Registered scoped.

### 7.3 `TenantResolutionMiddleware`

`AMS.Api/Middleware/TenantResolutionMiddleware.cs`. Runs immediately after `UseRouting` and before `UseAuthentication`.

```text
host = forwarded host || request.host
suffix = config["Tenant:RootHostSuffix"]            // "classpass.lk"
admin  = config["Tenant:AdminSubdomain"]            // "portal"
label  = host minus suffix (first label)

if label is null OR label == "www" OR label == suffix → IsRootHost=true
elif label == admin                                  → IsRootHost=true
elif label in ReservedSlugs                          → 404 tenant_unknown
else:
    info = await resolver.ResolveAsync(label)
    if info is null              → 404 tenant_unknown
    elif !info.IsActive          → 410 tenant_inactive
    else:
        Items[TenantContextKey] = new TenantHostContext(label, info.Id)
```

The 404/410 response is a small JSON `{ error, slug }` so the PWA can render a clean page when it hits the API directly. The middleware skips `/health` and `/swagger`.

### 7.4 `InstituteContext` precedence change

`AMS.Infrastructure/Services/Institute/InstituteContext.cs`. New precedence:

1. `ITenantHostContext.InstituteId` (Source = `Host`)
2. `X-Institute-Id` header (Source = `Header`) — ignored if the host context disagrees; log a warning.
3. JWT `institute_id` claim (Source = `JwtClaim`)

Extend `InstituteContextSource` with `Host = 3`.

### 7.5 `InstituteContextEnforcementMiddleware` hardening

`AMS.Api/Middleware/InstituteContextEnforcementMiddleware.cs`:

- Add `/api/public` to `ExemptPathPrefixes`.
- New rule executed before the existing membership check:
  ```
  if tenantHost.IsTenantHost && jwt.institute_id is set
     && jwt.institute_id != tenantHost.InstituteId
  → 403 tenant_token_mismatch
  ```
  This is the cross-tenant token-replay defence.
- Super-admins on tenant hosts must still pass the existing membership check **OR** hold `Institutes.AccessAny`. (Current code already short-circuits on `AccessAny`; we keep that — being on a tenant host doesn't strip the permission, it just locks the institute scope.)

### 7.6 Auth surface changes

#### `LoginApplicationUserCommand`

Already takes `Guid? InstituteId`. We do **not** add `InstituteSlug` to the application-layer record; the controller (which has access to `ITenantHostContext`) resolves and forwards an `InstituteId`:

```csharp
[HttpPost("login")]
public async Task<IActionResult> Login(
    [FromBody] LoginApplicationUserCommand command,
    [FromServices] ITenantHostContext tenant)
{
    if (tenant.IsTenantHost && tenant.InstituteId is { } hostInstituteId)
        command = command with { InstituteId = hostInstituteId };

    var result = await Mediator.Send(command);
    return HandleResult(result);
}
```

This keeps the application contract clean and ensures any host-supplied institute always wins over a client-supplied one — no spoofing.

**Error parity**: keep `Error.NotFound("User", …)` for unknown emails. To remove the enumeration leak on tenant hosts, the handler should collapse "user not found", "wrong password", and "not a member of this institute" to the same `Error.Unauthorized("invalid_credentials", "Invalid email or password")` response. (Existing code returns three distinct errors; this is a small change in the handler.)

#### `SwitchInstituteCommand`

```csharp
if (tenant.IsTenantHost && request.InstituteId != tenant.InstituteId)
    return Result.Failure<UseLoginDto>(
        Error.Forbidden("SwitchInstitute", "Switching is not allowed on a tenant host"));
```

Inject `ITenantHostContext` into the handler.

#### `AuthController.GetCurrentUser` (`/api/auth/me`)

Add `TenantSlug` (string?) and `IsTenantHost` (bool) read from `ITenantHostContext`.

### 7.7 Public branding endpoint

`AMS.Api/Controllers/RestApi/PublicInstituteController.cs`:

```csharp
[ApiController]
[Route("api/public/institutes")]
[AllowAnonymous]
public sealed class PublicInstituteController : PublicApiController
{
    [HttpGet("by-slug/{slug}/branding")]
    public async Task<IActionResult> GetBranding(string slug, CancellationToken ct) =>
        HandleResult(await Mediator.Send(new GetInstituteBrandingBySlugQuery(slug), ct));
}
```

`GetInstituteBrandingBySlugQuery` returns `{ name, slug, logoUrl, accentColor, secondaryColor, tagline, isActive }`. 404 when slug unknown.

### 7.8 CORS

`AMS.Infrastructure/DependencyInjection.cs::AddCorsInternal` already calls `SetIsOriginAllowedToAllowWildcardSubdomains()`. Tweaks:

- `appsettings.Production.json` `AllowedOrigins` becomes `["https://portal.classpass.lk", "https://*.classpass.lk"]`.
- Optionally tighten with a `SetIsOriginAllowed(origin => …)` delegate that pings `IInstituteSlugResolver` for any non-portal subdomain, rejecting unknown slugs at the CORS layer too. (Defence-in-depth; the real protection is the host-vs-token check.)

### 7.9 Forwarded headers

`Program.cs` (insert before `app.UseAuthentication()`):

```csharp
var forwarded = new ForwardedHeadersOptions
{
    ForwardedHeaders = ForwardedHeaders.XForwardedFor
                    | ForwardedHeaders.XForwardedProto
                    | ForwardedHeaders.XForwardedHost,
    ForwardLimit = 2
};
foreach (var range in builder.Configuration.GetSection("Cloudflare:KnownNetworks").Get<string[]>() ?? [])
    forwarded.KnownNetworks.Add(IPNetwork.Parse(range));
app.UseForwardedHeaders(forwarded);
```

### 7.10 Acceptance

- `curl https://api.classpass.lk/api/public/institutes/by-slug/inst-2026-0001/branding` → 200.
- Login with `Host: royal-college.classpass.lk` issues a JWT whose `institute_id` matches that slug's institute (verify by decoding the token).
- A JWT minted on `royal-college.classpass.lk` replayed with `Host: st-peters.classpass.lk` → 403 `tenant_token_mismatch`.
- POST `/api/auth/switch-institute` on a tenant host → 403 `switch_not_allowed_on_tenant_host`.

---

## 8. Phase 3 — PWA tenant detection + branded sign-in

### 8.1 Host detection

`AMS.PWA/src/lib/tenant-host.ts`:

```ts
const ROOT_HOST = import.meta.env.VITE_ROOT_HOST as string;        // "classpass.lk"
const ADMIN     = import.meta.env.VITE_ADMIN_SUBDOMAIN as string;   // "portal"

export interface TenantHostInfo {
  isTenantHost: boolean;   // false on portal / apex / localhost
  isAdminHost: boolean;    // portal.classpass.lk
  slug: string | null;     // the tenant slug or null
}

export function detectTenantHost(hostname = window.location.hostname): TenantHostInfo { … }
```

Localhost: returns `isAdminHost: true` so dev mirrors `portal` behaviour. To dev-test a tenant locally, set `VITE_DEV_TENANT_SLUG=royal-college` (a debug-only override read by `detectTenantHost`).

### 8.2 Tenant provider

`AMS.PWA/src/context/tenant-provider.tsx` wraps the app inside `main.tsx`. On boot:

- If `!isTenantHost` → provide `null`, render children immediately.
- Else fetch `/api/public/institutes/by-slug/{slug}/branding`.
  - 200 + `isActive` → provide `{ slug, name, logoUrl, accentColor, … }`.
  - 200 + `!isActive` → render full-page "This institute is inactive" with a link to `portal.classpass.lk`.
  - 404 → render full-page "Institute not found".

Expose `useTenant()` hook returning `TenantBranding | null`.

### 8.3 Branded sign-in

`AMS.PWA/src/features/auth/sign-in/index.tsx`:

- If `useTenant()` is non-null, render a `<TenantBrand />` panel (logo + name + optional tagline) above the form.
- Apply `accentColor` as CSS variable `--brand` on `<html data-tenant="…">` to recolour primary buttons in the auth flow.

`AMS.PWA/src/features/auth/sign-in/components/user-auth-form.tsx`:

- On tenant hosts: send `instituteSlug: tenant.slug` in the login body. Backend ignores body slug if host disagrees (host wins).
- Skip the existing `/institutes/mine` + auto-switch fallback on tenant hosts — the JWT is already scoped.
- Treat 401 / 403 generically: "Invalid email or password, or you are not a member of this institute" (matches the new backend parity).

### 8.4 Auth store

`AMS.PWA/src/stores/auth-store.ts` gains:

```ts
canSwitchInstitute: () => !detectTenantHost().isTenantHost
```

`switchInstitute` mutation hook returns a no-op when this is false.

### 8.5 API client

`AMS.PWA/src/lib/api-client.ts`: in the request interceptor, skip the `X-Institute-Id` header when `detectTenantHost().isTenantHost` (or always send it — backend ignores it on tenant hosts anyway; preference is to suppress for cleanliness).

### 8.6 Switcher → badge

`AMS.PWA/src/components/layout/app-sidebar.tsx`:

```tsx
{isTenantHost ? <InstituteBadge /> : <InstituteSwitcher />}
```

`InstituteBadge` is a new small read-only component that shows the tenant logo + name from `useTenant()`. The "Operate globally" affordance disappears with the switcher.

### 8.7 Acceptance

- Visit `https://royal-college.classpass.lk/sign-in` → see logo + name; sign in; land on `/` with switcher absent and accent applied.
- Visit `https://portal.classpass.lk/sign-in` → unchanged generic flow with the switcher.
- An unknown subdomain renders the "Institute not found" page.

---

## 9. Phase 4 — Sidebar & route gating

### 9.1 Sidebar item schema

`AMS.PWA/src/components/layout/types.ts`: extend `NavItem` with

```ts
requiredPermission?: string;   // e.g. "users:manage"
requiredRole?: string;         // e.g. "SystemAdmin"
visibleOnRootOnly?: boolean;   // hide on tenant subdomains
```

### 9.2 Filtering

`AMS.PWA/src/components/layout/app-sidebar.tsx` uses a new `useSidebarData()` hook that:

1. Loads `sidebarData.navGroups`.
2. For each item: hide if `requiredPermission` set and `!auth.hasPermission(p)`; hide if `requiredRole` set and `!auth.hasRole(r)`; hide if `visibleOnRootOnly` and tenant host.
3. Drops empty groups.

### 9.3 Group restructure

`AMS.PWA/src/components/layout/data/sidebar-data.ts` becomes:

- **General** (universal): Dashboard, Class Rooms, Students, Instructors, Classes, NFC Cards, Attendance, Payments.
- **Institute Administration**: Institute Settings, Institute Users (`requiredPermission: "institutes:view"`), Institute Roles (`requiredPermission: "institute-roles:manage"`), Notifications (`requiredPermission: "notifications:manage"`), Audit Logs.
- **System Administration** (`visibleOnRootOnly: true`): Institutes (`requiredPermission: "institutes:view"`), Global Users (`requiredPermission: "users:manage"`), Global Roles (`requiredPermission: "roles:manage"`), Identity Review (`requiredRole: "GlobalIdentityAdmin"`).
- **Settings** (universal, profile/account/etc.).

### 9.4 Route guards

- `AMS.PWA/src/routes/_global-admin/route.tsx`: extend `beforeLoad` to redirect to `/` when `detectTenantHost().isTenantHost`.
- `AMS.PWA/src/routes/__root.tsx`: no change needed; the underlying route guard handles it.

### 9.5 Acceptance

- An institute-admin user on `royal-college.classpass.lk` sees only General + Institute Administration + Settings.
- A SystemAdmin on `portal.classpass.lk` sees all four groups.
- A SystemAdmin who navigates to `royal-college.classpass.lk` sees the same nav as the institute admin (system tabs hidden).

---

## 10. Phase 5 — Hosting cutover

### 10.1 PWA → Cloudflare Pages

- Delete `AMS.PWA/netlify.toml`.
- Add `AMS.PWA/public/_redirects` with `/* /index.html 200`.
- Create the Pages project, wire custom domains (Phase 0.3 / 0.1).
- Run the new PWA against the existing API for one week before flipping DNS.

### 10.2 API on `api.classpass.lk`

- Replace `AMS.WIKI/deployment/ams-nginx.conf` with the API-only vhost.
- Issue and install the `api.classpass.lk` cert via certbot DNS-01.
- Update `AMS.WIKI/deployment/api.env.template`: add `Tenant__RootHostSuffix=classpass.lk`, `Tenant__AdminSubdomain=portal`, `Cloudflare__KnownNetworks__0=…` (one entry per published range).

### 10.3 Decommission Netlify

After 7 days of stable Pages traffic, delete the Netlify site.

---

## 11. Phase 6 — Onboarding UX

### 11.1 Institute creation form

`AMS.PWA/src/features/institutes/` — add a slug field with:

- Live availability check `GET /api/institutes/check-slug?value=…` (system-admin only; returns `{ available, reason }` with `reason` ∈ `"taken" | "reserved" | "invalid"`).
- Inline URL preview: `https://<slug>.classpass.lk`.
- Client-side pre-validation against `AMS.PWA/src/lib/reserved-slugs.ts` (Phase 1.2).

`CreateInstituteCommand` gains an optional `Slug`. If null, the handler defaults to `LOWER(code)`; if provided, validates and persists it.

### 11.2 Slug change

`UpdateInstituteCommand` (or a new `ChangeInstituteSlugCommand` for auditability) gates slug changes behind:

- A PWA confirmation modal warning that existing tenant URLs / sessions will break.
- A domain event (`InstituteSlugChangedEvent`) handled by the slug resolver to invalidate the cache.
- An audit row in the existing audit infrastructure.

### 11.3 Acceptance

- Reserved slugs (`portal`, `api`, etc.) are rejected with a clear inline error.
- Renaming an institute's slug invalidates the resolver cache within 1s.

---

## 12. Phase 7 — Azure-readiness audit *(do before any cutover)*

Architectural guardrails so the VPS → Azure migration is config-only.

- Every host/origin/storage/DB value flows through `IConfiguration`. No string literal pinning to VPS IPs.
- `AllowedOrigins` already supports wildcards. `Tenant:RootHostSuffix` and `Tenant:AdminSubdomain` join the pattern.
- Postgres connection string supports `SslMode=Require;Trust Server Certificate=true` toggle (Azure Flexible Server enforces SSL).
- Logs: keep Seq via env var; add an Application Insights `TelemetryClient` registration behind an `Observability:UseApplicationInsights` flag.
- Health: `/health` exists; add `/health/ready` and `/health/live` aliases for App Service / Container Apps probes.
- Sticky sessions / in-memory state: none (already stateless). The `IMemoryCache` for slug resolution is process-local; that's fine because invalidation is event-driven per process (cache TTL caps staleness anyway).

**Migration sequence (when ready):**

1. Provision Azure DB for PostgreSQL Flexible Server; `pg_dump | pg_restore`.
2. Deploy API to App Service / Container App with the same env vars.
3. Cloudflare DNS: flip `api.classpass.lk` A record → App Service / Front Door hostname.
4. Decommission VPS.

The frontend on Cloudflare Pages is **not** affected.

---

## 13. Security model

- Tenant subdomain ≠ authorisation. A user must already have an `InstituteUser` row for the host's institute (or hold `Institutes.AccessAny`). The host narrows scope; it never grants access.
- JWT `institute_id` MUST equal `TenantHostContext.InstituteId` when the request is from a tenant host (Phase 2.5).
- `X-Institute-Id` header is ignored on tenant hosts.
- Switch-institute is server-rejected on tenant hosts.
- Cookies are per-host by default (PWA `cookies.ts` does not set `Domain=`). A stolen cookie cannot move laterally between tenants.
- Failed login on a tenant host returns the same error whether the email exists, the password is wrong, or the user isn't a member — no enumeration leak.

---

## 14. Risks & open items

| Risk | Mitigation |
|---|---|
| Cookie scope regression | Audit any future `setCookie` change to confirm no `Domain=` attribute slips in. |
| Reserved-slug drift between API + PWA | Mirror the list in `AMS.Domain.Constants.ReservedSlugs` and `AMS.PWA/src/lib/reserved-slugs.ts`; CI grep test asserting parity (`AMS.Tests` integration). |
| Slug resolver cache invalidation across multiple API instances | Today: single-process VPS, no issue. On Azure scale-out: add a `IDistributedCache` (Redis) or rely on the 60s TTL. Document the limit. |
| Cloudflare WebSocket proxying | Confirm any SSE/WebSocket feature works through Cloudflare's orange-cloud (notifications stream). |
| Unknown-subdomain UX | Phase 3 tenant provider already renders a "Not found" screen. |
| Backup access path | Keep the VPS IP reachable directly (`https://<vps-ip>` with a self-signed cert) for emergency support; documented in the runbook. |

---

## 15. Roll-forward order

1. **Phase 1 — Domain/data** (smallest blast radius; everything else depends on `Slug`).
2. **Phase 2 — API tenant resolution** (server-side complete; PWA still works on root host).
3. **Phase 5 — Hosting cutover** to Cloudflare Pages on `portal.classpass.lk` only, before tenant subdomains exist.
4. **Phase 3 — PWA tenant detection & branded sign-in** (now tenant URLs become real).
5. **Phase 4 — Sidebar & route gating**.
6. **Phase 6 — Onboarding UX**.
7. **Phase 7 — Azure-readiness audit** (whenever the Azure decision lands).
