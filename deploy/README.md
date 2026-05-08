# Deployment runbook — checks.classiv.com

This overlay deploys the upstream `healthchecks/healthchecks` Django app
to Railway with a Neon Postgres backend. **One** Railway service handles
web + sendalerts + sendreports because upstream's `docker/uwsgi.ini`
already runs the alert and report loops as attached daemons.

See `docs/superpowers/specs/2026-05-08-checks-classiv-com-design.md` for
the architecture decision record.

## Realized deployment (2026-05-08)

| Resource | Identifier | Notes |
|---|---|---|
| GitHub repo | `ClassIV/checks-classiv` | Fork of `healthchecks/healthchecks` v4.2 |
| Railway project | `checks-classiv` (`89774ade-fa05-48c6-b8a3-c4bdbcee71cf`) | Personal account, no team |
| Railway service | `web` (`4d5407ed-b469-48d8-b5e1-56df14b4e2ea`) | Single service; daemons run in-proc via uwsgi |
| Railway env | `production` (`a2c10372-aebb-49ff-b1e4-794b03ed8e5a`) | |
| Railway-issued subdomain | `web-production-2ef78.up.railway.app:8000` | Returns 400 — `ALLOWED_HOSTS` blocks |
| Custom domain | `checks.classiv.com` (`0bd758d6-1a2b-4fc5-bb06-58628ce4ce55`) | targetPort=8000, verified=true |
| Neon project | `checks-classiv` (`nameless-mud-46413630`) | aws-us-east-1, pooled URL in `deploy/.secrets-database` |
| Cloudflare DNS | CNAME `checks` → `98br1yg4.up.railway.app` (DNS-only) | TXT `_railway-verify.checks` |
| Initial superuser | `becker@classiv.com` | Random username, password in `deploy/.secrets-superuser` |

## Railway gotchas hit during initial deploy

These are the surprises that should not bite us again on rebuilds. None of
them are documented prominently in healthchecks or Railway docs.

1. **Healthchecks does not honor `DATABASE_URL`.** It uses discrete
   env vars: `DB=postgres`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
   `DB_PASSWORD`, `DB_SSLMODE=require`. Setting `DATABASE_URL` will
   silently fall through to SQLite at `BASE_DIR/hc.sqlite`.

2. **Railway metal builder rejects subdirectory Dockerfiles.** Setting
   `dockerfilePath: "docker/Dockerfile"` in `railway.json` results in
   "skipping … not rooted at a valid path." Solution: ship a Dockerfile
   at the repo root (we have one — `/Dockerfile` — that mirrors upstream).

3. **`--mount=type=bind` is not supported by Railway's builder.** Only
   `--mount=type=cache` works. Our root Dockerfile uses `COPY --from=builder`
   instead.

4. **Don't override `startCommand` to inject `$PORT`.** uwsgi reads its
   socket from `docker/uwsgi.ini` which hardcodes `:8000`. If you pass
   `--http-socket :$PORT`, Railway does not expand the env var and uwsgi
   binds to literal `:$PORT`. Solution: set the custom domain's
   `targetPort=8000` and let uwsgi keep its default.

5. **Custom domain needs TXT verification record.** `customDomainCreate`
   returns a `verificationToken` that must be added as TXT at
   `_railway-verify.<host>`. Without it, Railway's edge returns
   `{"status":"error","code":404,"message":"Application not found"}`
   regardless of CNAME health. The TXT can stay even if you delete and
   recreate the custom domain — the token is reused.

6. **Healthchecks' `createsuperuser` does NOT accept `--no-input` /
   `--noinput`.** It's a custom command that takes `--email` and
   `--password` directly. Use `DJANGO_SUPERUSER_EMAIL` /
   `DJANGO_SUPERUSER_PASSWORD` env vars + a `preDeployCommand` like:

   ```
   sh -c "./manage.py migrate --noinput && (./manage.py createsuperuser --email $DJANGO_SUPERUSER_EMAIL --password $DJANGO_SUPERUSER_PASSWORD 2>&1 || true)"
   ```

   The `|| true` makes it idempotent across redeploys (subsequent runs
   error with "User with this email already exists").

7. **Migrations must run as `preDeployCommand`, NOT via uwsgi
   `hook-pre-app`.** uwsgi's `attach-daemon` directives spawn `sendalerts`
   and `sendreports` in parallel with the hook, so they race against
   migrate and crash on missing tables. Setting `preDeployCommand`
   guarantees migrations finish before the container starts.

8. **TLS issuance can fail with generic "internal error."** Even with
   verified=true and DNS propagated. Workaround: hit "Retry" in the
   Railway dashboard custom-domain section. The cert pipeline will
   often succeed on a manual retry where automatic retries fail.

## Operations

### Re-deploy from local

The repo auto-deploys on push to `master`. To force a redeploy without
a commit:

```bash
RAILWAY_API_TOKEN="$(cat deploy/.secrets-railway | cut -d= -f2)"
SERVICE_ID=4d5407ed-b469-48d8-b5e1-56df14b4e2ea
ENV_ID=a2c10372-aebb-49ff-b1e4-794b03ed8e5a

curl -sS -X POST https://backboard.railway.com/graphql/v2 \
  -H "Authorization: Bearer $RAILWAY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"mutation{ serviceInstanceDeployV2(serviceId:\\\"$SERVICE_ID\\\", environmentId:\\\"$ENV_ID\\\") }\"}"
```

(The `railway` CLI does not work with the current account token; use
GraphQL directly. See `deploy/.secrets-railway`.)

### Tail deploy logs

```bash
RAILWAY_API_TOKEN="$(cat deploy/.secrets-railway | cut -d= -f2)"
SERVICE_ID=4d5407ed-b469-48d8-b5e1-56df14b4e2ea

# Get most recent deployment ID
DEP_ID=$(curl -sS -X POST https://backboard.railway.com/graphql/v2 \
  -H "Authorization: Bearer $RAILWAY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"{ service(id: \\\"$SERVICE_ID\\\") { deployments(first:1) { edges { node { id } } } } }\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["service"]["deployments"]["edges"][0]["node"]["id"])')

curl -sS -X POST https://backboard.railway.com/graphql/v2 \
  -H "Authorization: Bearer $RAILWAY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"{ deploymentLogs(deploymentId: \\\"$DEP_ID\\\") { timestamp message severity } }\"}"
```

### Rotate secrets

All secrets live in Railway env vars and locally in `deploy/.env`,
`deploy/.secrets-database`, `deploy/.secrets-generated` (SECRET_KEY),
`deploy/.secrets-superuser`, `deploy/.secrets-railway`. All gitignored.

Rotate by:
1. Generate new value
2. Update `deploy/.env`
3. Re-upsert via the `variableCollectionUpsert` GraphQL mutation
4. Trigger redeploy

Long-term: move all of these to a 1Password vault under "Class IV
Internal" and source them at deploy time rather than persisting on disk.

## Local dev

Not supported by this overlay. Use `docker/docker-compose.yml` upstream
for local iteration if needed.

## Upstream tracking

```bash
git fetch upstream
git rebase upstream/master
```

Rebase conflicts should only touch `deploy/`, the root `Dockerfile`, and
maybe `.gitignore` — never upstream files. If upstream files conflict,
that signals scope creep.
