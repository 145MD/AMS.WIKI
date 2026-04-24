# Nginx Setup Guide for AMS

This guide covers setting up Nginx on an Ubuntu VPS to serve the AMS PWA frontend and reverse proxy the AMS API.

## Architecture

```
Client Request
      |
      v
   Nginx (:80/:443)
      |
      |-- /api/*     --> reverse proxy --> .NET API (localhost:5000)
      |-- /swagger    --> reverse proxy --> .NET API (localhost:5000)
      |-- /health     --> reverse proxy --> .NET API (localhost:5000)
      |-- /*          --> static files  --> /var/www/ams-pwa/index.html (SPA fallback)
```

## Prerequisites

- Ubuntu VPS with SSH access
- A `deploy` user with appropriate permissions

## Step 1: Install Nginx

```bash
sudo apt update
sudo apt install -y nginx
```

Verify installation:

```bash
nginx -v
sudo systemctl status nginx
```

## Step 2: Create directory structure

```bash
sudo mkdir -p /var/www/ams-api
sudo mkdir -p /var/www/ams-pwa
sudo chown -R deploy:www-data /var/www/ams-api /var/www/ams-pwa
```

## Step 3: Copy the Nginx config

The config file is at `deployment/ams-nginx.conf` in this repo. Copy it to the VPS:

```bash
# From your local machine
scp deployment/ams-nginx.conf deploy@YOUR_VPS_IP:/tmp/ams

# On the VPS
sudo cp /tmp/ams /etc/nginx/sites-available/ams
```

### Edit the config

Open the config and replace `server_name _;` with your actual domain or IP:

```bash
sudo nano /etc/nginx/sites-available/ams
```

```nginx
server_name yourdomain.com;   # or your VPS IP like 203.0.113.10
```

## Step 4: Enable the site

```bash
# Create symlink to enable
sudo ln -s /etc/nginx/sites-available/ams /etc/nginx/sites-enabled/

# Remove default site
sudo rm /etc/nginx/sites-enabled/default

# Test configuration
sudo nginx -t

# Reload Nginx
sudo systemctl reload nginx
```

## Step 5: Verify routing

After deployment, test that routes work correctly:

| URL | Expected behavior |
|---|---|
| `http://YOUR_IP/` | PWA loads (index.html) |
| `http://YOUR_IP/login` | PWA loads, client-side router shows login page |
| `http://YOUR_IP/dashboard` | PWA loads, client-side router shows dashboard |
| `http://YOUR_IP/api/...` | Proxied to .NET API |
| `http://YOUR_IP/swagger` | API Swagger UI |
| `http://YOUR_IP/health` | API health check response |

### How SPA routing works

The key directive is:

```nginx
location / {
    try_files $uri $uri/ /index.html;
}
```

This tells Nginx:
1. Try to serve the exact file requested (e.g., `/assets/main.js`)
2. Try it as a directory
3. If neither exists, serve `/index.html` — the SPA shell

TanStack Router then reads the URL path and renders the correct page client-side. This is why `http://YOUR_IP/login` works even though there is no `login.html` file.

## Step 6: Add SSL with Let's Encrypt (recommended)

If you have a domain name pointed to your VPS:

```bash
# Install Certbot
sudo apt install -y certbot python3-certbot-nginx

# Get and install certificate
sudo certbot --nginx -d yourdomain.com

# Certbot auto-modifies the Nginx config to:
# - Listen on 443 with SSL
# - Redirect HTTP (80) to HTTPS (443)
# - Add certificate paths
```

Verify auto-renewal:

```bash
sudo certbot renew --dry-run
```

### Post-SSL checklist

After enabling SSL, update these:

1. **appsettings.Production.json** — update `AllowedOrigins` to use `https://`
2. **PWA build** — ensure `VITE_API_BASE_URL` still works (relative `/api` path is fine)
3. **Nginx config** — Certbot handles this automatically, but verify with `sudo nginx -t`

## Nginx Config Explained

### API reverse proxy

```nginx
location /api/ {
    proxy_pass http://localhost:5000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection keep-alive;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_cache_bypass $http_upgrade;
}
```

- `proxy_pass` — forwards to the .NET Kestrel server
- `X-Real-IP` / `X-Forwarded-For` — passes the real client IP to the API
- `X-Forwarded-Proto` — tells the API whether the original request was HTTP or HTTPS
- `proxy_http_version 1.1` — required for keep-alive connections

### Static asset caching

```nginx
location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
}
```

Vite produces hashed filenames (e.g., `main-abc123.js`), so aggressive caching is safe — when the content changes, the filename changes.

## Troubleshooting

### 502 Bad Gateway

The API is not running. Check:

```bash
sudo systemctl status ams-api
journalctl -u ams-api -n 50
```

### 404 on page refresh

The `try_files` fallback is not working. Verify:

```bash
# Check the config is linked
ls -la /etc/nginx/sites-enabled/
# Should show: ams -> /etc/nginx/sites-available/ams

# Check no other config is conflicting
sudo nginx -t
```

### API returns CORS errors

Update `AllowedOrigins` in `appsettings.Production.json` to match your actual domain/IP (including protocol and port if non-standard).

### Permission denied on static files

```bash
# Ensure www-data can read the PWA files
sudo chown -R deploy:www-data /var/www/ams-pwa
sudo chmod -R 755 /var/www/ams-pwa
```

## Useful commands

```bash
# Reload Nginx after config changes (no downtime)
sudo systemctl reload nginx

# View Nginx error logs
sudo tail -f /var/log/nginx/error.log

# View Nginx access logs
sudo tail -f /var/log/nginx/access.log

# Test Nginx config syntax
sudo nginx -t

# Restart API service
sudo systemctl restart ams-api

# View API logs
journalctl -u ams-api -f
```
