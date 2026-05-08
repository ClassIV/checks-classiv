# checks.classiv.com — Design Spec

**Date:** 2026-05-08
**Owner:** Bryan Becker
**Status:** Approved (brainstorming complete, awaiting implementation plan)

> **Implementation revision (2026-05-08):** Upstream `docker/uwsgi.ini`
> already runs `sendalerts` and `sendreports` as in-process daemons via
> `attach-daemon`. The "three Railway services" architecture below is
> over-engineered; deployed config uses **one** Railway service. The
> separate-services pattern remains valid if we ever need independent
> scaling, but YAGNI for v1. See `deploy/README.md` for actual deploy
> shape.

## Summary

Self-hosted cron / scheduled-job monitoring service, built by deploying the
open-source `healthchecks/healthchecks` Django application to Railway with a
Neon Postgres backend. Lives at `checks.classiv.com`. Intended for monitoring
Class IV's internal automation surface (Teddy, LocationsHQ sync, Mac Mini
LaunchAgents, Railway crons, future client jobs).

This is **not** a customer-facing product in v1. It is internal/operator-facing.
A future white-label client portal is explicitly out of scope.

## Goals

1. Replace ad-hoc "did the cron run?" detection across Teddy, sync services,
   and LaunchAgents with a single dashboard and notification fan-out.
2. Reuse stack already in use (Railway + Neon + SMTP2GO + Cloudflare DNS).
3. Standalone — no dependency on Teddy's infra; can monitor Teddy itself.
4. Live within an evening of starting implementation.

## Non-Goals (v1)

- Multi-region deployment.
- Custom integrations beyond Slack / Telegram / generic webhooks.
- pg_dump → R2 backup pipeline (Neon PITR is sufficient for v1).
- Client-tenanted white-label portal.
- Custom auth (no SSO, no SAML — magic-link email only).
- Public signup.

## Architecture

```
                  Cloudflare DNS (gray cloud, DNS-only)
                              |
                  checks.classiv.com (CNAME)
                              |
                              v
              +-------------------------------+
              | Railway project: checks       |
              |                               |
              |  service: web                 |
              |    cmd: gunicorn hc.wsgi      |
              |                               |
              |  service: sendalerts          |
              |    cmd: manage.py sendalerts  |
              |                               |
              |  service: sendreports         |
              |    cmd: manage.py sendreports |
              |         --loop                |
              +---------------+---------------+
                              |
                  DATABASE_URL (pooled)
                              |
                              v
                       Neon Postgres
                       (NullPool client side)
```

External dependencies:

- **SMTP2GO** — transactional email for magic-link auth, alert email,
  weekly reports. Class IV already uses SMTP2GO; reuse credentials.
- **Slack** — workspace-level integration via incoming webhooks
  (configured per-check, not OAuth).
- **Telegram** — single bot token, registered via BotFather, named e.g.
  `@ClassIVChecksBot`.
- **Cloudflare DNS** — DNS-only mode for `checks.classiv.com`. Proxied
  mode is rejected for v1 because it interferes with `curl`-based ping
  clients running from cron environments.

## Components

### Railway services

All three services build from the same forked repo (one Dockerfile, one
codebase, different start commands). Use Railway's "service variants" pattern
or three explicit services pointing at the same GitHub repo with overridden
start commands.

| Service | Replicas | Start command | Notes |
|---|---|---|---|
| `web` | 1 | `gunicorn hc.wsgi:application -b 0.0.0.0:$PORT` | Public HTTP. Custom domain attached here. |
| `sendalerts` | 1 | `python manage.py sendalerts` | Loop already built-in upstream. |
| `sendreports` | 1 | `python manage.py sendreports --loop` | Daily/weekly digests + nag emails. |

Healthchecks does **not** require Redis. Django's database-backed cache is
adequate at this scale (single-digit users, low thousands of checks). Add
Redis later only if cache contention shows up.

### Database

Neon Postgres, **pooled** connection string (`-pooler` host). Django uses
`NullPool` on the client side per the user's standing pattern (Neon handles
pool management upstream). The healthchecks repo's default Django DB config
honors `DATABASE_URL` via `dj-database-url`; we patch it (or set
`CONN_MAX_AGE=0`) to ensure no client-side pooling.

Migrations run via `python manage.py migrate` from the Railway shell on
first deploy. Subsequent deploys auto-run migrations as a release phase
(Railway pre-deploy hook).

### Repo layout

Fork `healthchecks/healthchecks` to `becker-classiv/checks-classiv` (or
similar — actual GitHub org TBD by user at deploy time). Add a thin
`deploy/` overlay rather than mutating upstream:

```
checks-classiv/
├── (upstream healthchecks files, untouched where possible)
├── deploy/
│   ├── Dockerfile         # builds the upstream app + our static overrides
│   ├── railway.json       # service config (web vs worker variants)
│   └── static-overrides/
│       └── img/logo.png   # Class IV teal mark
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-05-08-checks-classiv-com-design.md  # this file
```

This keeps upstream-tracking trivial: rebase onto `healthchecks/master`
periodically and only deal with merge conflicts in our `deploy/` overlay.

### Branding

Minimal. Override:

- `SITE_NAME=Class IV Checks` (env var, picked up by templates and emails).
- `static/img/logo.png` replaced with Class IV teal mark via Dockerfile
  `COPY` step. Brand colors: `#4ba2ac` primary teal, fonts left as upstream
  defaults (Class IV brand fonts — Poppins/Lato — only required for
  client-facing artifacts; this is operator-facing).
- Email `From:` = `checks@classiv.com`, signed/aligned for SMTP2GO.

No template forks in v1. If we end up rewriting templates, that signals
this should have been a custom build, not a fork.

## Environment variables

All configured as Railway environment variables, marked secret where noted.

### Required

| Var | Value | Secret |
|---|---|---|
| `SECRET_KEY` | Generated 50-char random string | Yes |
| `DATABASE_URL` | Neon pooled connection string | Yes |
| `ALLOWED_HOSTS` | `checks.classiv.com` | No |
| `SITE_ROOT` | `https://checks.classiv.com` | No |
| `PING_ROOT` | `https://checks.classiv.com/ping` | No |
| `SITE_NAME` | `Class IV Checks` | No |
| `DEFAULT_FROM_EMAIL` | `checks@classiv.com` | No |
| `EMAIL_HOST` | `mail.smtp2go.com` | No |
| `EMAIL_PORT` | `2525` | No |
| `EMAIL_USE_TLS` | `True` | No |
| `EMAIL_HOST_USER` | SMTP2GO username | Yes |
| `EMAIL_HOST_PASSWORD` | SMTP2GO password | Yes |
| `REGISTRATION_OPEN` | `False` | No |
| `DEBUG` | `False` | No |
| `SECURE_PROXY_SSL_HEADER` | `HTTP_X_FORWARDED_PROTO,https` | No |

### Notification channels

| Var | Value | Secret |
|---|---|---|
| `SLACK_ENABLED` | `True` | No |
| `TELEGRAM_ENABLED` | `True` | No |
| `TELEGRAM_TOKEN` | BotFather token | Yes |
| `TELEGRAM_BOT_NAME` | `ClassIVChecksBot` | No |
| `WEBHOOKS_ENABLED` | `True` | No |

All other channel `*_ENABLED` flags default `False` upstream — leave them.

## DNS / TLS

- Cloudflare zone: `classiv.com` (existing).
- Add CNAME: `checks` → `<railway-app-domain>` provided by Railway when
  custom domain is attached.
- **Gray cloud (DNS-only).** Proxy mode is rejected for v1 because:
  1. Cloudflare's bot-fight / challenge layer can intercept `curl` from
     cron environments and silently break ping delivery.
  2. The `/ping/<uuid>` endpoints are designed for unauthenticated GET/POST
     from automation; WAF rules add no value, only failure modes.
- TLS is terminated by Railway via auto-issued Let's Encrypt cert when the
  custom domain is attached.

If a Cloudflare WAF is wanted later, the migration is: enable orange cloud
*only* after authoring a Page Rule that exempts `/ping/*` from challenges
and security level escalation. That's a v1.1 task.

## Auth model

- `REGISTRATION_OPEN=False` — no public signup.
- Initial superuser created via `python manage.py createsuperuser` from
  Railway shell on first deploy.
- Users are invited into projects from the dashboard. Login is magic-link
  email — no passwords stored.
- 2FA is supported upstream (TOTP, U2F). Enable for the superuser
  immediately post-bootstrap.

## Teddy / Class IV automation integration pattern

Each scheduled job at Class IV that we want to monitor gets:

1. **One check** in the dashboard, with:
   - Schedule expressed as cron syntax matching the actual schedule
     (e.g., LaunchAgent `StartCalendarInterval`, Railway cron, etc.).
   - Grace period set to ~2× expected runtime, minimum 5 min.
   - Notification channels assigned (Slack + webhook for ops jobs;
     Telegram for time-sensitive ones).
2. **A UUID baked into the worker config**, sourced from `~/.openclaw/.env`
   or the Railway env (never inline, per the LaunchAgent secret-hygiene
   memory). Variable name convention: `HC_PING_<JOB_NAME>` →
   `https://checks.classiv.com/ping/<uuid>`.
3. **Three pings per run:**
   - `GET <PING_URL>/start` at job entry.
   - `GET <PING_URL>` on success exit.
   - `GET <PING_URL>/fail` on exception or non-zero exit.
4. **Failure routing** via webhook channel that POSTs into the existing
   Class IV alerting flow (Slack `#alerts` channel + ClickUp task creation
   via existing Class IV ClickUp MCP — exact path defined at integration
   time, not in this spec).

Documentation for the integration pattern lives in the repo at
`docs/integrations/teddy.md` (created during implementation, not now).

## Security

- All secrets in Railway env, marked secret. Nothing in repo.
- `SECRET_KEY` generated fresh, never reused from any other Class IV system.
- Database accessible only via Neon's IP allowlist (Railway egress added).
- HSTS enabled (`SECURE_HSTS_SECONDS=31536000`,
  `SECURE_HSTS_INCLUDE_SUBDOMAINS=True`) once the cert is verified live —
  not on day one to avoid a misissue lockout.
- Admin URL not changed from `/admin/` upstream default in v1; revisit if
  brute-force noise becomes signal.
- Rate limiting: upstream healthchecks has built-in rate limits on
  `/ping/*`; leave defaults.

## Backup & DR

- **Primary:** Neon PITR. The default Neon plan retains 24h–7d depending on
  tier; confirm tier supports at least 7d before deploy.
- **Secondary:** None in v1. Loss of all checks is a one-day re-creation
  job — annoying, not catastrophic. pg_dump → R2 cron is a v1.1 task if
  the check inventory grows past trivial recreation.
- **App recovery:** repo + Railway config + env var snapshot are the entire
  recovery surface. Document an env var export step in
  `docs/runbooks/recovery.md` post-deploy.

## Out of scope (explicit)

These are deliberately not in v1. Each is a separate future spec:

- pg_dump cron → R2/S3 backup belt-and-suspenders.
- Cloudflare proxy/WAF in front of the dashboard.
- Multi-tenant client portal (white-label per Class IV client).
- Custom integrations beyond Slack/Telegram/Webhooks (Discord, MS Teams,
  PagerDuty, etc. — flip the env flag when needed).
- SSO / SAML.
- Status pages (the `hc.front.views.status` upstream supports them, but
  exposing public status pages is a product decision deferred).
- Multi-region / DR replica.

## Implementation sequence (high-level — full plan via writing-plans)

1. Fork `healthchecks/healthchecks` → `becker-classiv/checks-classiv`.
2. Add `deploy/` overlay (Dockerfile, railway.json, branding overrides).
3. Provision Neon database, capture pooled connection string.
4. Create Railway project + three services pointing at the fork.
5. Configure all env vars; verify SECRET_KEY / DATABASE_URL /
   SMTP creds / Telegram token are set.
6. First deploy → run `migrate` + `createsuperuser` from Railway shell.
7. Attach `checks.classiv.com` custom domain to `web` service.
8. Add Cloudflare CNAME (gray cloud) → wait for cert issuance.
9. Smoke test: log in, create a check, fire pings via `curl` from local
   shell, simulate a failure, verify Slack + Telegram notifications.
10. Document the Teddy integration pattern in `docs/integrations/teddy.md`.
11. Migrate one canary Teddy job onto the system; observe for 48h before
    rolling out to remaining jobs.

## Open questions deferred to implementation

- Exact GitHub org for the fork (`becker-classiv` vs `ClassIV` org per
  memory). Decide at fork time.
- Whether to put the overlay in a separate repo and use upstream as a
  submodule. Default in this spec: single fork repo. Revisit if upstream
  rebase pain emerges.
- Telegram bot username availability — `@ClassIVChecksBot` may be taken;
  fallback list maintained in implementation plan.
