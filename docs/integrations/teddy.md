# Teddy / Class IV automation integration

How to wire a scheduled job into checks.classiv.com so that "did the cron
run?" becomes a single dashboard question.

## Per-job pattern

For each scheduled job (LaunchAgent on the Mac Mini, Railway cron, ad-hoc
sync service, etc.):

1. Create a check in the dashboard:
   - **Name:** match the job's logical name (e.g., `teddy-ticket-sync`)
   - **Tags:** the host or service group (e.g., `mac-mini`, `railway`,
     `classiv-internal`)
   - **Schedule:** cron expression matching the job's actual schedule
   - **Grace period:** ~2× expected runtime, minimum 5 min
   - **Notifications:** Slack `#alerts` + Telegram for time-sensitive
     jobs; webhook for routing into ClickUp tasks
2. Copy the check's UUID. Store as an env var in the job's secret store
   (e.g., `~/.openclaw/.env` for Mac Mini LaunchAgents per
   `reference_mini_launchagents.md`):
   ```
   HC_PING_TEDDY_TICKET_SYNC=https://checks.classiv.com/ping/<uuid>
   ```
   **Never** inline UUIDs in plist `EnvironmentVariables` or commit them
   to repos — same hygiene rule as any other secret.
3. Wrap the job:

### Bash / shell jobs

```bash
#!/usr/bin/env bash
set -euo pipefail
source ~/.openclaw/.env

curl -fsS --retry 3 "$HC_PING_TEDDY_TICKET_SYNC/start" >/dev/null || true

if /path/to/actual-job; then
    curl -fsS --retry 3 "$HC_PING_TEDDY_TICKET_SYNC" >/dev/null || true
else
    rc=$?
    curl -fsS --retry 3 --data "exit=$rc" "$HC_PING_TEDDY_TICKET_SYNC/fail" >/dev/null || true
    exit $rc
fi
```

### Node / TypeScript jobs

```typescript
const PING = process.env.HC_PING_TEDDY_TICKET_SYNC!;

async function ping(suffix: '' | '/start' | '/fail' = '', body?: string) {
  try {
    await fetch(`${PING}${suffix}`, { method: 'POST', body });
  } catch { /* swallow — monitoring must never crash the job */ }
}

await ping('/start');
try {
  await runJob();
  await ping();
} catch (err) {
  await ping('/fail', String(err));
  throw err;
}
```

### Python jobs

```python
import os, requests
PING = os.environ["HC_PING_TEDDY_TICKET_SYNC"]

def ping(suffix: str = "", body: str | None = None) -> None:
    try:
        requests.post(f"{PING}{suffix}", data=body, timeout=5)
    except requests.RequestException:
        pass  # monitoring must never crash the job

ping("/start")
try:
    run_job()
    ping()
except Exception as e:
    ping("/fail", body=str(e))
    raise
```

## Failure routing

The webhook channel POSTs to a single URL on failure. Recommended target:
a thin Worker / Lambda that:

1. Posts a Slack message to `#alerts` with the check name + last log lines
2. Creates a ClickUp task in the relevant list (Class IV ClickUp MCP) for
   any check that fails twice in a row
3. Pages on-call via Telegram for checks tagged `priority:p1`

The webhook target itself is out of scope for this repo — it lives in the
Class IV automation infra. Document the URL in 1P once configured.

## Anti-patterns

- **Don't ping at the start of cron itself, before the job runs.** That
  defeats the point — you want to know whether the *work* succeeded, not
  whether cron fired.
- **Don't use `curl -f`** for the success ping if your job already
  succeeded — failed pings should never propagate exit codes back into a
  job that did its work correctly.
- **Don't share UUIDs across jobs.** Each logical job gets its own check
  even if scheduled together.
- **Don't enable Cloudflare proxy mode** on `checks.classiv.com` without
  whitelisting `/ping/*` — challenges silently break ping delivery from
  cron's bare `curl`.
