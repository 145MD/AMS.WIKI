# Cloudflare Pages + DNS + TLS Setup

Operator runbook for moving the AMS.PWA from Netlify to Cloudflare Pages, wiring the tenant wildcard subdomain (`*.classpass.lk`), and standing up the API host on `api.classpass.lk`. Pairs with [`multi-tenant-subdomain-access.md`](../architecture/multi-tenant-subdomain-access.md) — see that doc for the *why*.

This is a one-time sequence; do it in order.

---

## 1. DNS records (Cloudflare dashboard)

Add these under the `classpass.lk` zone:

| Type | Name | Target | Proxy |
|---|---|---|---|
| A | `api` | VPS public IP | ✅ proxied (orange cloud) |
| CNAME | `portal` | `<pages-project>.pages.dev` | ✅ proxied |
| CNAME | `*` | `<pages-project>.pages.dev` | ✅ proxied |
| CNAME | `www` | `portal.classpass.lk` | ✅ proxied |

The `<pages-project>.pages.dev` value comes from the next step.

---

## 2. Cloudflare Pages project

1. **Pages → Create a project → Connect to Git** → pick the AMS.PWA repo (branch: `main`).
2. **Build settings**
   - Framework preset: `Vite`
   - Build command: `npm run build`
   - Build output directory: `dist`
   - Root directory: `AMS.PWA`
3. **Environment variables** (Production + Preview):

   | Variable | Value |
   |---|---|
   | `VITE_API_BASE_URL` | `https://api.classpass.lk/api` |
   | `VITE_ROOT_HOST` | `classpass.lk` |
   | `VITE_ADMIN_SUBDOMAIN` | `portal` |

4. Trigger the first build. Note the resulting `<pages-project>.pages.dev` hostname.
5. **Pages project → Custom domains → Add**, in this order:
   1. `portal.classpass.lk`
   2. `*.classpass.lk` (the wildcard — needed for every tenant)
   3. `www.classpass.lk` (Cloudflare will offer a 301 redirect — point it at `portal.classpass.lk`)

   Pages auto-provisions TLS for each. Universal SSL on the parent zone covers the wildcard at one level (i.e. `*.classpass.lk`) without ACM.

SPA history routing is handled by the `404.html` fallback the build script writes (copy of `index.html`). Cloudflare Pages serves `404.html` for any unmatched route, letting TanStack Router pick up the URL client-side. **Do not** add a `public/_redirects` with `/* /index.html 200` — Pages auto-strips `.html`/`/index`, which creates an infinite-loop validation error and rejects the deploy.

---

## 3. VPS — nginx + TLS for `api.classpass.lk`

The API is at `AMS.WIKI/deployment/ams-nginx.conf`. Install:

```bash
sudo cp AMS.WIKI/deployment/ams-nginx.conf /etc/nginx/sites-available/api.classpass.lk
sudo ln -s /etc/nginx/sites-available/api.classpass.lk /etc/nginx/sites-enabled/
sudo nginx -t            # syntax check
```

Issue the cert via DNS-01 (works through Cloudflare's proxy; no port-80 reachability needed):

```bash
sudo apt install python3-certbot-dns-cloudflare
# Create the credentials file with a SCOPED token (Zone:DNS:Edit on classpass.lk only):
sudo install -m 600 /dev/null /etc/letsencrypt/cloudflare.ini
sudo nano /etc/letsencrypt/cloudflare.ini
# Paste:  dns_cloudflare_api_token = <token>

sudo certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d api.classpass.lk \
  --non-interactive --agree-tos -m ops@classpass.lk

sudo systemctl reload nginx
```

Renewal is automatic via the systemd timer that ships with certbot; add a `--deploy-hook 'systemctl reload nginx'` flag to the timer unit if it's not already there.

---

## 4. API config — env vars

On the VPS, ensure `/etc/ams/api.env` includes the new tenant block (template at `AMS.WIKI/deployment/api.env.template`):

```
Tenant__RootHostSuffix=classpass.lk
Tenant__AdminSubdomain=portal
```

`appsettings.Production.json` already declares the `Cloudflare:KnownNetworks` ranges that the API uses with `UseForwardedHeaders`; no env override needed.

Restart the API service: `sudo systemctl restart ams-api`.

---

## 5. Cutover sequence

Do this in one short window, ideally outside peak hours.

1. **Pre-flight on Pages** — visit `https://portal.classpass.lk` (the URL is live the moment the custom domain finishes provisioning) and confirm the PWA loads against the new API.
2. **Verify wildcard reachability** — `curl -I https://anything-unknown.classpass.lk` should serve the SPA (`200`, `index.html`). The PWA renders the "Institute not found" screen for unknown slugs.
3. **Pause Netlify auto-deploys** — Netlify project → Build & deploy → stop auto-publishing on `main`. Don't delete the site yet (rollback insurance).
4. **Smoke**
   - Sign in on `portal.classpass.lk` → existing experience (switcher + admin tabs).
   - Sign in on `<known-slug>.classpass.lk` → branded screen, tenant-locked nav.
   - Cross-tenant token replay → 403 `tenant_token_mismatch` (use two browser profiles / tokens to test).
5. **DNS confirm** — `dig portal.classpass.lk` should resolve to a Cloudflare anycast IP; the Netlify CNAME (`*.netlify.app`) should no longer be referenced.

After 7 days of clean Pages traffic, delete the Netlify site.

---

## 6. Rollback plan

If something is wrong before the 7-day window closes:

1. Cloudflare DNS → flip `portal` (and `*` if needed) CNAME back to the old Netlify hostname.
2. Cloudflare Pages — pause the project (keep custom domains so the rollback is reversible).
3. Netlify — un-pause auto-deploys.
4. Investigate, fix, redo cutover.

The API on `api.classpass.lk` is unaffected by any of the above — only the PWA host changes.

---

## 7. Notes for the future Azure migration

The frontend stays on Cloudflare Pages (no reason to move with the backend). For the backend:

- DNS — flip `api.classpass.lk` A record from the VPS IP to the App Service / Front Door hostname. CNAME flattening is fine since `api` is a leaf label.
- TLS — Azure App Service Managed Certificate covers a single host (`api.classpass.lk`) for free; no certbot.
- Cloudflare proxy stays on, so the `Cloudflare:KnownNetworks` config in `appsettings.Production.json` doesn't change.
- `Tenant:RootHostSuffix` and `Tenant:AdminSubdomain` env vars carry over verbatim.
