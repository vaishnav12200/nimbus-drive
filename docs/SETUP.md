# Deploying Nimbus Drive

The backend stores metadata only. Your files live in *your* Telegram channel, so
what you are deploying here is a small stateless API in front of PostgreSQL.

- [Deploy to Render](#deploy-to-render) — the supported path
- [Run locally](#run-locally)
- [Self-host elsewhere](#self-host-elsewhere)
- [Maintenance, backups, upgrades](#maintenance)
- [Troubleshooting](#troubleshooting)

---

## Deploy to Render

The pieces:

| Component | Where |
|---|---|
| API | Render web service (Docker) |
| PostgreSQL | **Supabase** |
| Redis | Render Key Value |
| File bytes | your Telegram channel |

[`render.yaml`](../render.yaml) declares the API and the Key Value instance.
PostgreSQL is Supabase, so you supply `DATABASE_URL` yourself.

### 1. Create the Supabase database

Create a project, then **Project Settings → Database → Connection string**.

**Take the Session pooler string — port 5432.** Supabase offers three and the
choice matters:

| Option | Host / port | Use it? |
|---|---|---|
| Direct | `db.<ref>.supabase.co:5432` | ❌ IPv6-only unless you buy the IPv4 add-on |
| **Session pooler** | `aws-<region>.pooler.supabase.com:5432` | ✅ IPv4, supports prepared statements |
| Transaction pooler | `aws-<region>.pooler.supabase.com:6543` | ⚠️ works, but slower here |

Session mode is right for a long-lived container like this one. Transaction mode
is built for serverless and **cannot support prepared statements** — asyncpg uses
them by default, which produces intermittent
`prepared statement "__asyncpg_stmt_N__" does not exist` failures under load.
The app detects port 6543 and disables them automatically, so it will not break,
but you pay for the lost statement caching. Prefer 5432.

Paste the string exactly as Supabase gives it. The `postgresql://` scheme and
any `sslmode` parameter are rewritten for asyncpg on load.

**If your password contains `$`, `%`, `@`, `/` or `#`, percent-encode it.**
`$` is the one that bites: written raw in a `.env` file, docker compose expands
`$2026` as a variable and the password silently becomes something shorter, so
authentication fails with no clue why. Encode `$` as `%24`, `%` as `%25`,
`@` as `%40`, `/` as `%2F`, `#` as `%23`.

You do not need to pre-create anything in the database. The migration creates
`pg_trgm` if absent and schema-qualifies the trigram operator class, so it works
whether the extension lands in `public` or Supabase's `extensions` schema.

**Connection budget.** A free Supabase project allows 60 connections, 3 reserved
for the superuser, and Supabase's own internals hold roughly 12. Session mode
gives each pooled client a server connection for its whole lifetime, so
SQLAlchemy's pool maps straight onto that budget. `render.yaml` therefore sets
`DB_POOL_SIZE=5` / `DB_MAX_OVERFLOW=5` — a peak of 10 per instance — rather than
the 30 the defaults would allow. Raise them only alongside a paid Supabase plan;
exhausting the pool shows up as requests hanging, not as a clean error.

**Free projects pause after 1 week without activity** and must be restored by
hand from the dashboard. A deployed backend polls the database often enough that
this will not trigger, but a project you set up and leave alone for a fortnight
before deploying will be asleep when you come back. Paused projects are
restorable for 90 days.

### 2. Generate the secrets Render cannot generate for you

`SECRET_ENCRYPTION_KEY` is created by Render (`generateValue: true`). The JWT
keypair is not, because it is a *pair* — generate it locally:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out jwt.pem
openssl rsa -in jwt.pem -pubout -out jwt.pub
```

Render's dashboard accepts multi-line values, so paste each PEM as-is. If you
are scripting it instead, collapse to one line with literal `\n`:

```bash
awk 'BEGIN{ORS="\\n"} {print}' jwt.pem
```

### 3. Create the Blueprint

Dashboard → **New** → **Blueprint** → select this repository. Render reads
`render.yaml` and prompts for the `sync: false` variables:

| Variable | Value |
|---|---|
| `DATABASE_URL` | Supabase session pooler string from §1 |
| `JWT_PRIVATE_KEY` | contents of `jwt.pem` |
| `JWT_PUBLIC_KEY` | contents of `jwt.pub` |
| `CORS_ORIGINS` | your client's origin, or `*` while you have no web client |
| `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` | optional — see §5 |

Apply. Render builds `backend/Dockerfile`, provisions the Key Value instance,
runs `alembic upgrade head` as the pre-deploy command, and starts the
API once `/health` returns 200.

### 4. Verify

```bash
curl -s https://nimbus-drive-api.onrender.com/health | jq
```

```json
{"success": true,
 "data": {"status": "ok", "database": true, "redis": true,
          "mtproto_configured": false}}
```

`mtproto_configured: false` is expected until you do the next step.

### 5. Telegram API credentials (optional — enables files over 20 MB)

Without these the API works, but only for files the client can send to the Bot
API itself: **20 MB maximum, and no video streaming.**

1. Sign in at <https://my.telegram.org> → **API development tools**.
2. Create an application; any name will do.
3. Set `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` in the service's environment.

These identify *your server* to Telegram, not your users — each user still
authenticates with their own bot token.

### Render specifics worth knowing

**Do not attach a Disk.** Large uploads are staged in `TEMP_DIR` and deleted in a
`finally` before the request ends, so nothing needs to survive a restart. Render's
ephemeral filesystem is writable and is exactly the right lifetime. A Disk would
buy persistence you do not want and cost you zero-downtime deploys and the
ability to run more than one instance.

**Size the staging area to the instance, not to a VPS.** `render.yaml` sets
`MAX_CONCURRENT_LARGE_UPLOADS=2` and `MAX_TEMP_DIR_BYTES=2 GiB`; two concurrent
2 GB uploads would otherwise want 4 GB of scratch space on a container that does
not have it. Past the cap the API returns `503 UPLOAD_CAPACITY` with a
`Retry-After` rather than filling the disk.

**Requests may run up to 100 minutes**, which is comfortable for a 2 GB upload
over a slow connection. Nothing needs tuning for this.

**Free instances spin down after 15 minutes of inactivity** and take roughly a
minute to wake. That is survivable for a drive app, but an upload started
against a cold instance pays the wake-up first. Pre-deploy commands — which is
where migrations run — also require a paid instance type. The Blueprint
specifies `plan: starter` for that reason; drop it to `free` only if you are
willing to run `alembic upgrade head` by hand.

**Scaling past one instance** works — the app holds no local state — provided
Key Value is attached. Rate limits and token revocation fall back to per-process
without it, which silently multiplies your effective rate limit by the instance
count.

---

## Run locally

```bash
cp .env.example .env      # defaults are fine for local work
docker compose up -d
docker compose exec api alembic upgrade head
```

API on `http://localhost:8000`, interactive docs at `/docs`.

Without Docker:

```bash
cd backend
python3.11 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
# compose publishes Postgres on 55432 so it cannot clash with a local install
export DATABASE_URL=postgresql+asyncpg://nimbus:change-me@localhost:55432/nimbus
.venv/bin/alembic upgrade head
.venv/bin/uvicorn app.main:app --reload
```

In development the server generates and caches an RSA keypair under `TEMP_DIR`
and falls back to a built-in encryption key, so neither secret is required. Both
are mandatory when `APP_ENV=production`; the app refuses to start without them.

### Tests

```bash
cd backend
.venv/bin/pytest                       # needs PostgreSQL on :55432 (docker compose)
.venv/bin/pytest tests/test_config.py  # pure unit tests, no database needed
```

Tests run against real PostgreSQL, not SQLite — the schema depends on `pg_trgm`,
`INET`, `JSONB` and partial indexes. Point `TEST_DATABASE_URL` at a throwaway
database; it is created and truncated automatically.

---

## Self-host elsewhere

The image is an ordinary FastAPI container. It binds `$PORT` (default 8000) on
`0.0.0.0` and needs PostgreSQL 15+ with permission to `CREATE EXTENSION
pg_trgm`.

Run migrations as a separate step before starting new instances, never in the
start command — N instances would race N migrations:

```bash
docker run --rm -e DATABASE_URL=... your-image alembic upgrade head
```

### Behind your own reverse proxy

The container runs with `--proxy-headers --forwarded-allow-ips '*'`, so it
trusts `X-Forwarded-For`. **Only expose it through a proxy you control** —
otherwise a client can forge that header and evade the rate limits entirely.

<details>
<summary>Caddy</summary>

```caddyfile
drive.example.com {
    request_body {
        max_size 2GB
    }
    reverse_proxy localhost:8000
}
```
</details>

<details>
<summary>Nginx</summary>

```nginx
server {
    listen 443 ssl http2;
    server_name drive.example.com;

    client_max_body_size 2G;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Uploads and streams are long-lived; do not let the proxy buffer or
        # time them out. With request buffering on, Nginx spools the entire
        # upload to its own disk before the backend sees a byte.
        proxy_request_buffering off;
        proxy_buffering         off;
        proxy_read_timeout      3600s;
        proxy_send_timeout      3600s;
    }
}
```
</details>

---

## Maintenance

Nothing purges itself. Run the maintenance job daily — it empties trash older
than `TRASH_RETENTION_DAYS`, drops expired refresh tokens, and sweeps old sync
tombstones:

```bash
python -m app.jobs.maintenance            # --dry-run to preview
```

On Render, add it as a **Cron Job** service pointing at the same Docker image
with that start command. Elsewhere, a crontab entry:

```cron
17 4 * * * cd /srv/nimbus-drive && docker compose exec -T api python -m app.jobs.maintenance >> /var/log/nimbus-maintenance.log 2>&1
```

Skipping it is not catastrophic — the trash keeps growing and deleted files keep
occupying your Telegram channel.

### Backups

Back up **the database and `SECRET_ENCRYPTION_KEY` together.** The database
without the key leaves every stored bot token unreadable; the key without the
database is worthless.

Supabase takes automatic daily backups (retention depends on your plan). For
your own dump:

```bash
pg_dump "$DATABASE_URL" | gzip > nimbus-$(date +%F).sql.gz
```

File *contents* need no backup — they are in Telegram. What you are protecting
is the folder structure, names, tags and share links.

### Upgrades

Push to the branch Render tracks; it rebuilds and re-runs migrations. Elsewhere:

```bash
git pull && docker compose build api && docker compose up -d
docker compose exec api alembic upgrade head
```

`alembic upgrade head` is idempotent.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Deploy fails, "no open ports detected" | The container is not binding `$PORT`. Only happens if the `CMD` was edited. |
| `503` from `/health` | Database unreachable. Check the connection string and that the database is in the same Render region. |
| `InvalidPasswordError` / driver errors at startup | A connection string the app could not rewrite. It accepts `postgres://`, `postgresql://` and `postgresql+asyncpg://`. |
| `prepared statement "__asyncpg_stmt_N__" does not exist`, only under load | A transaction-mode pooler the app did not recognise. Switch to Supabase's session pooler (port 5432). |
| `Network is unreachable` connecting to Supabase | The direct connection (`db.<ref>.supabase.co`) is IPv6-only. Use the session pooler host instead. |
| `Tenant or user not found` from Supabase | Either the pooler username is not `postgres.<project-ref>`, or the region in the hostname is wrong. Copy the string from the dashboard rather than assembling it. |
| Auth fails and the password looks truncated | An unencoded `$` in the password; docker compose expanded it. Percent-encode it as `%24`. |
| `invalid interpolation syntax` from Alembic | A `%` in the URL hitting configparser. Fixed in `alembic/env.py`; only reappears if that escaping is removed. |
| `operator class "gin_trgm_ops" does not exist` | Only possible on a hand-made schema; the migration resolves the extension's schema itself. Check the role may `CREATE EXTENSION`. |
| `MTPROTO_UNAVAILABLE` on a large upload | `TELEGRAM_API_ID`/`TELEGRAM_API_HASH` unset — see §4. |
| `BOT_TOKEN_UNREADABLE` | `SECRET_ENCRYPTION_KEY` changed. Users must re-bind their channel; there is no rotation migration. |
| `CHAT_WRITE_FORBIDDEN` | The bot is not an administrator of the channel. |
| `CHANNEL_INVALID` | Wrong channel id, or the bot was removed. Ids look like `-1001234567890`. |
| `FLOOD_WAIT` | Telegram is rate limiting that bot; `details.retry_after` says for how long. |
| `UPLOAD_CAPACITY` | Too many concurrent large uploads, or staging is full. Raise the caps only if the disk can take it. |
| First request after idle is slow | A free instance spinning back up. Expected; upgrade the plan to avoid it. |
| Uploads fail near 100% behind your own proxy | A proxy body-size limit. See the Nginx/Caddy snippets above. |

### Logs

`DEBUG=true` raises the level. Output is JSON when `APP_ENV=production` and
human-readable otherwise.

Bot tokens, passwords and JWTs are redacted by the logging pipeline itself, and
user ids are hashed — so logs are safe to paste into a bug report. Every response
also carries an `X-Request-ID` header that matches the log line for that request.
