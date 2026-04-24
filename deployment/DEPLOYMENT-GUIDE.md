# AMS Deployment Guide

Step-by-step guide to deploy AMS.API (.NET 10) and AMS.PWA (Vite/React) to an Ubuntu VPS with Nginx and GitHub Actions CI/CD.

## Architecture

```
Client Request
      |
      v
   Nginx (:80 / :443)
      |
      |-- /api/*     --> reverse proxy --> .NET API (localhost:5000)
      |-- /swagger    --> reverse proxy --> .NET API (localhost:5000)
      |-- /health     --> reverse proxy --> .NET API (localhost:5000)
      |-- /*          --> static files  --> /var/www/ams-pwa/index.html (SPA fallback)
```

```
git push main (AMS.API repo)
        |
        v
  GitHub Actions
        |
        |--> dotnet build + test + publish
        |--> SCP publish/ --> /var/www/ams-api/ on VPS
        |--> SSH: systemctl restart ams-api

git push main (AMS.PWA repo)
        |
        v
  GitHub Actions
        |
        |--> pnpm build (VITE_API_BASE_URL=/api baked in)
        |--> SCP dist/ --> /var/www/ams-pwa/ on VPS
        (Nginx serves new files immediately, no restart needed)
```

---

## Part 1: VPS Initial Setup

### 1.1 Install dependencies

```bash
sudo apt update && sudo apt upgrade -y

# .NET 10 runtime
sudo apt install -y dotnet-sdk-10.0

# Nginx
sudo apt install -y nginx

# PostgreSQL (if hosted on same VPS)
sudo apt install -y postgresql postgresql-contrib
```

### 1.1a Configure Firewall (UFW)

Ensure SSH, HTTP, and HTTPS ports are open.

```bash
# Install UFW if not already installed
sudo apt install -y ufw

# Allow SSH (port 22) - CRITICAL: Do this before enabling UFW!
sudo ufw allow OpenSSH

# Allow Nginx HTTP/HTTPS
sudo ufw allow 'Nginx Full'

# Enable the firewall
sudo ufw enable
```

> **Note:** If you are using AWS EC2, Azure VM, or Google Cloud, you must also open ports 80 (HTTP) and 443 (HTTPS) in your cloud provider's **Security Group** or **Firewall** settings.

### 1.2 Create a deploy user

```bash
sudo adduser --disabled-password deploy
sudo usermod -aG www-data deploy

# Set up SSH key auth for GitHub Actions
sudo mkdir -p /home/deploy/.ssh
sudo chown -R deploy:deploy /home/deploy/.ssh
sudo chmod 700 /home/deploy/.ssh
```

Generate a dedicated deploy SSH key pair (run this on your local machine):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ams_deploy -C "ams-deploy-ci" -N ""
```

Add the public key to the VPS:

```bash
# On the VPS, as root or your admin user:
echo "PASTE_PUBLIC_KEY_HERE" | sudo tee -a /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys
```

The private key (`~/.ssh/ams_deploy`) goes into GitHub Actions secrets (see Part 3).

### 1.3 Create directory structure

```bash
sudo mkdir -p /var/www/ams-api
sudo mkdir -p /var/www/ams-pwa
sudo mkdir -p /var/log/ams
sudo chown -R deploy:www-data /var/www/ams-api /var/www/ams-pwa
sudo chown deploy:deploy /var/log/ams
```

---

## Part 2: API Secrets (replacing local User Secrets)

Locally you use `.NET User Secrets` (`secrets.json`). On the VPS, the equivalent is an environment file loaded by systemd.

### How the key mapping works

ASP.NET Core reads environment variables as config by replacing `__` (double underscore) with `:` (the section separator). So:

| `secrets.json` key | Environment variable |
|---|---|
| `Jwt:SecretKey` | `Jwt__SecretKey` |
| `ConnectionStrings:DefaultConnection` | `ConnectionStrings__DefaultConnection` |
| `AzureAd:ClientSecret` | `AzureAd__ClientSecret` |

### 2.1 Create the secrets file on the VPS

```bash
sudo mkdir -p /etc/ams
sudo nano /etc/ams/api.env
```

Use `deployment/api.env.template` from this repo as a reference. Fill in all `CHANGE_ME` values with your production secrets.

```bash
# Lock down the file — only the deploy user can read it
sudo chmod 600 /etc/ams/api.env
sudo chown deploy:deploy /etc/ams/api.env
```

The systemd service (`deployment/ams-api.service`) loads this file via `EnvironmentFile=/etc/ams/api.env`. **Never commit `/etc/ams/api.env` to git.**

---

## Part 3: Nginx Setup

### 3.1 Install the config

Copy `deployment/ams-nginx.conf` to the VPS:

```bash
# From your local machine:
scp deployment/ams-nginx.conf deploy@YOUR_VPS_IP:/tmp/ams-nginx.conf

# On the VPS:
sudo cp /tmp/ams-nginx.conf /etc/nginx/sites-available/ams
```

Edit `server_name` to match your IP or domain:

```bash
sudo nano /etc/nginx/sites-available/ams
# Change:  server_name _;
# To:      server_name 203.0.113.10;   (your VPS IP)
# Or:      server_name yourdomain.com;
```

### 3.2 Enable the site

```bash
sudo ln -s /etc/nginx/sites-available/ams /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```

### 3.3 How SPA routing works

The key directive in the Nginx config:

```nginx
location / {
    try_files $uri $uri/ /index.html;
}
```

This makes `http://YOUR_IP/login` work even though there is no `login.html` file — Nginx serves `index.html` and TanStack Router renders the correct page client-side.

### 3.4 SSL with Let's Encrypt (recommended if you have a domain)

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d yourdomain.com
sudo certbot renew --dry-run  # verify auto-renewal works
```

---

## Part 4: API systemd Service

### 4.1 Install the service

```bash
# From your local machine:
scp deployment/ams-api.service deploy@YOUR_VPS_IP:/tmp/ams-api.service

# On the VPS:
sudo cp /tmp/ams-api.service /etc/systemd/system/ams-api.service
sudo systemctl daemon-reload
sudo systemctl enable ams-api
```

### 4.2 Grant deploy user permission to restart the service

Run `sudo visudo` and add this line at the bottom:

```
deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ams-api, /usr/bin/systemctl is-active ams-api
```

### 4.3 Run EF Core migrations on the VPS

Before starting the API for the first time (or after deploying migrations), run:

```bash
# On the VPS, as the deploy user or an admin with the correct env:
cd /var/www/ams-api
export $(cat /etc/ams/api.env | xargs)
dotnet AMS.Api.dll  # or use ef tools if installed
```

Or install the EF tools and run migrations as part of the deploy workflow (advanced).

---

## Part 5: GitHub Actions CI/CD

### 5.1 Required secrets (both repos)

Go to **Settings > Secrets and variables > Actions** in each GitHub repo and add:

| Secret | Value |
|---|---|
| `VPS_HOST` | Your VPS IP address |
| `VPS_SSH_KEY` | Contents of `~/.ssh/ams_deploy` (the private key) |

### 5.2 Required variable (AMS.PWA repo only)

Go to **Settings > Secrets and variables > Actions > Variables tab** and add:

| Variable | Value |
|---|---|
| `VITE_API_BASE_URL` | `/api` |

**Why `/api` (relative path)?**

Because Nginx serves both the PWA and the API from the same IP and port. When the browser is at `http://YOUR_IP/dashboard`, a relative `/api` call resolves to `http://YOUR_IP/api/...`, which Nginx reverse-proxies to the .NET API. No absolute URL or CORS configuration needed.

If your API is on a separate domain (e.g., `https://api.yourdomain.com`), use that full URL instead, and add it to `AllowedOrigins` in `appsettings.Production.json`.

### 5.3 Workflow files

| File | Trigger | What it does |
|---|---|---|
| `AMS.API/.github/workflows/deploy-api.yml` | push to main | build → test → publish → SCP → restart service |
| `AMS.PWA/.github/workflows/deploy-pwa.yml` | push to main | pnpm install → build → SCP dist/ to VPS |

---

## Part 6: appsettings.Production.json

Non-secret production config overrides live in `AMS.Api/appsettings.Production.json` (committed to the repo):

```json
{
  "AllowedOrigins": [
    "http://YOUR_VPS_IP",
    "https://yourdomain.com"
  ],
  "Serilog": {
    "WriteTo": [
      { "Name": "Console" },
      {
        "Name": "File",
        "Args": {
          "path": "/var/log/ams/api.log",
          "rollingInterval": "Day",
          "retainedFileCountLimit": 30
        }
      }
    ]
  }
}
```

Update `AllowedOrigins` with your actual VPS IP or domain.

---

## Routing reference

| URL | Served by |
|---|---|
| `http://YOUR_IP/` | Nginx → index.html → PWA |
| `http://YOUR_IP/login` | Nginx → index.html → TanStack Router renders /login |
| `http://YOUR_IP/api/*` | Nginx → reverse proxy → .NET API on port 5000 |
| `http://YOUR_IP/swagger` | Nginx → reverse proxy → Swagger UI |
| `http://YOUR_IP/health` | Nginx → reverse proxy → health check |

---

## Useful commands on the VPS

```bash
# Restart the API
sudo systemctl restart ams-api

# View API logs (live)
journalctl -u ams-api -f

# View API log file
tail -f /var/log/ams/api.log

# Reload Nginx after config change (zero downtime)
sudo systemctl reload nginx

# View Nginx error logs
sudo tail -f /var/log/nginx/error.log

# Test Nginx config syntax
sudo nginx -t

# Check API service status
sudo systemctl status ams-api
```

---

## Troubleshooting

### 502 Bad Gateway on `/api/*`

The API service is not running. Check:

```bash
sudo systemctl status ams-api
journalctl -u ams-api -n 50
```

Common causes: wrong path in `ExecStart`, missing `/etc/ams/api.env`, bad DB connection string.

### Page refresh returns 404

The Nginx SPA fallback is not active. Verify the site is enabled and config is correct:

```bash
ls -la /etc/nginx/sites-enabled/  # should show ams -> sites-available/ams
sudo nginx -t
```

### CORS errors in browser console

Add your VPS IP/domain to `AllowedOrigins` in `appsettings.Production.json` and redeploy the API.

### `VITE_API_BASE_URL` is undefined in the built app

The GitHub Actions variable was not set. Go to the PWA repo **Settings > Secrets and variables > Actions > Variables** and confirm `VITE_API_BASE_URL` is defined. Re-run the workflow after adding it.

### Secrets not loading in API

Verify the env file is correct:

```bash
sudo cat /etc/ams/api.env          # check contents
sudo systemctl show ams-api | grep EnvironmentFile  # verify it's referenced
journalctl -u ams-api -n 20        # check for config errors at startup
```
