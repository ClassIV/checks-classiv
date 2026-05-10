# checks.classiv.com — backlog

Items deferred from initial deploy. None are blocking site operation;
all can be picked up in any order.

## SMTP2GO — debug delivery from Class IV checks instance

**Symptom:** Magic-link login emails do not arrive at `becker@classiv.com`
when initiated from `https://checks.classiv.com/accounts/login/`.

**Why it matters:** Magic-link login is the intended primary auth path.
Password login is a fallback. Until SMTP works, also no failure-alert
emails (Slack/Telegram still work for alerts; only email is degraded).

**Likely causes (ordered by probability):**

1. **SMTP2GO sender not authorized.** `DEFAULT_FROM_EMAIL=checks@classiv.com`
   is set, but SMTP2GO requires the sender domain (or the specific
   address) to be configured/verified in their dashboard. SMTP2GO
   silently drops mail from unconfigured senders for some account tiers.
   **Check:** SMTP2GO dashboard → Sending → Authorized senders. Add
   `checks@classiv.com` or the parent domain.

2. **SPF/DKIM not aligned for `classiv.com` from SMTP2GO.** Even if SMTP
   accepts, downstream mailservers (Gmail/M365) may reject or quarantine.
   **Check:** SMTP2GO dashboard → Sending → DNS Settings; compare against
   DNS records on `classiv.com` in Cloudflare. Add CNAMEs/TXT as needed.

3. **Wrong SMTP credentials.** The 1P entry `SMTP2GO (Class IV)` was
   used (item id `r2a37yexujrilqsyjzd2pjit7m`). If those creds were
   rotated post-storage, healthchecks would just silently fail to send.
   **Check:** SMTP2GO dashboard → SMTP & API → SMTP Users. Confirm the
   stored username matches a live user with active password.

4. **Outbound 2525 blocked from Railway egress.** Unlikely (Railway has
   no egress restrictions documented), but worth a packet-level check.
   **Check:** Railway shell → `nc -vz mail.smtp2go.com 2525`.

**Diagnostic recipe (run after picking up):**

```bash
# 1. Capture SMTP2GO event log for sends from this instance
#    https://app-eu.smtp2go.com/events/ → filter by Subject contains "Class IV Checks"

# 2. Tail healthchecks deploy logs while triggering a magic-link send
RAILWAY_API_TOKEN="$(cat deploy/.secrets-railway | cut -d= -f2)"
SERVICE_ID=4d5407ed-b469-48d8-b5e1-56df14b4e2ea

DEP_ID=$(curl -sS -X POST https://backboard.railway.com/graphql/v2 \
  -H "Authorization: Bearer $RAILWAY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"{ service(id: \\\"$SERVICE_ID\\\") { deployments(first:1) { edges { node { id } } } } }\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["service"]["deployments"]["edges"][0]["node"]["id"])')

# Trigger a magic link send by hitting the login form, then:
curl -sS -X POST https://backboard.railway.com/graphql/v2 \
  -H "Authorization: Bearer $RAILWAY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"{ deploymentLogs(deploymentId: \\\"$DEP_ID\\\") { timestamp message severity } }\"}" \
  | python3 -c 'import json,sys; [print(l["message"]) for l in json.load(sys.stdin)["data"]["deploymentLogs"] if "smtp" in l["message"].lower() or "email" in l["message"].lower()]'
```

**Done when:** A login attempt from a fresh browser produces a magic-link
email in becker@classiv.com inbox within 60 seconds.

---

## Other deferred items (from spec)

- Move `deploy/.secrets-*` files into a 1P "Class IV Internal" vault
  (or a new "checks.classiv.com" vault) and source them at deploy time
  rather than persisting on disk.
- pg_dump → R2 backup cron (Neon PITR is enough for v1, but a cold
  belt-and-suspenders is cheap insurance once check inventory grows past
  trivial recreation).
- Cloudflare WAF in front of dashboard with `/ping/*` Page Rule exempting
  challenges. Deferred until there's actual abuse signal.
- 2FA (TOTP) on the superuser. Already supported upstream; just enable
  from the user's profile after first login.
- Migrate one canary Teddy job onto the system, observe for 48h, roll
  out to remaining jobs. See `docs/integrations/teddy.md` for the wrapper
  patterns.
- Disable the `set_password()` step in `preDeployCommand` once
  password is finalized — otherwise every redeploy resets the password
  to the value of `DJANGO_SUPERUSER_PASSWORD`. Either keep that env var
  in sync with whatever the live password is, or strip the
  `manage.py shell -c "...set_password..."` clause from the
  preDeployCommand.
