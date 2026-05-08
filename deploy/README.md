# Deployment runbook — checks.classiv.com

This overlay deploys the upstream `healthchecks/healthchecks` Django app
to Railway with a Neon Postgres backend. **One** Railway service handles
web + sendalerts + sendreports because upstream's `docker/uwsgi.ini`
already runs the alert and report loops as attached daemons.

See `docs/superpowers/specs/2026-05-08-checks-classiv-com-design.md` for
the architecture decision record.

## Prerequisites

- Neon project provisioned, pooled `DATABASE_URL` captured.
- Railway account with `railway login` completed.
- Cloudflare API token with DNS edit scope on `classiv.com`.
- Telegram bot token (talk to @BotFather, name: `ClassIVChecksBot`).
- 1P entry `SMTP2GO (Class IV)` accessible.

## Deploy steps

1. **Create Railway project linked to this repo:**

   ```bash
   railway login            # interactive
   railway init checks-classiv
   railway link             # link this dir to the project
   ```

2. **Configure target port (uWSGI binds via `$PORT`):**
   In Railway service settings → Networking, set target port to whatever
   `$PORT` resolves to (Railway auto-injects). The `startCommand` in
   `deploy/railway.json` already passes `--http-socket :$PORT`.

3. **Set environment variables:**

   Copy from `deploy/.env.template`. Replace `<SECRET: ...>` placeholders:

   ```bash
   # SECRET_KEY (generated, see .secrets-generated — gitignored)
   railway variables set SECRET_KEY="$(cat deploy/.secrets-generated)"

   # SMTP2GO from 1Password
   railway variables set EMAIL_HOST_USER="$(op read 'op://Teddy Automation/SMTP2GO (Class IV)/username')"
   railway variables set EMAIL_HOST_PASSWORD="$(op read 'op://Teddy Automation/SMTP2GO (Class IV)/password')"

   # Neon DATABASE_URL (paste from neonctl output)
   railway variables set DATABASE_URL="postgresql://..."

   # Telegram (after BotFather)
   railway variables set TELEGRAM_TOKEN="..."

   # Bulk-set the rest from .env.template
   ```

4. **Deploy:**

   ```bash
   railway up
   ```

   Migrations run automatically (uwsgi `hook-pre-app` calls
   `manage.py migrate`).

5. **Bootstrap superuser:**

   ```bash
   railway run python manage.py createsuperuser
   ```

6. **Custom domain:**

   ```bash
   railway domain checks.classiv.com
   # → Railway prints the CNAME target. Add CNAME in Cloudflare DNS-only.
   ```

7. **Cloudflare DNS (DNS-only / gray cloud):**

   ```bash
   curl -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json" \
     --data '{
       "type": "CNAME",
       "name": "checks",
       "content": "<railway-target>.up.railway.app",
       "proxied": false,
       "ttl": 300
     }'
   ```

8. **Smoke test:**

   ```bash
   curl -I https://checks.classiv.com/      # expect 200 with redirect to login
   ```

   Log in (magic-link), create a check, ping it:

   ```bash
   curl https://checks.classiv.com/ping/<uuid>
   ```

## Local dev

Not supported by this overlay. Use `docker/docker-compose.yml` upstream
for local iteration if needed.

## Upstream tracking

```bash
git remote -v   # 'upstream' should be healthchecks/healthchecks
git fetch upstream
git rebase upstream/master
```

Rebase conflicts should only touch `deploy/` (overlay) — never upstream
files. If upstream files conflict, that signals scope creep.
