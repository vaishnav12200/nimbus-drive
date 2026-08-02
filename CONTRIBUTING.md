# Contributing to Nimbus Drive

Thanks for taking an interest. This is a self-hosted personal cloud drive backed
by a Telegram channel — the kind of project where a subtle bug can lose somebody
else's files, so a few of the rules below are stricter than you might expect.

- [Getting set up](#getting-set-up)
- [Running things](#running-things)
- [Rules that are not negotiable](#rules-that-are-not-negotiable)
- [Code style](#code-style)
- [Commits and pull requests](#commits-and-pull-requests)
- [Reporting security issues](#reporting-security-issues)

---

## Getting set up

**Backend** — Python 3.11, Docker.

```bash
git clone https://github.com/vaishnav12200/nimbus-drive
cd nimbus-drive
cp .env.example .env

cd backend
python3.11 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt

cd ..
docker compose up -d db redis
cd backend && .venv/bin/alembic upgrade head
```

**Mobile** — Flutter 3.22+.

```bash
cd mobile && flutter pub get
```

**Hooks** — please install these; they run what CI runs, only sooner.

```bash
pre-commit install --install-hooks
```

Fast checks (formatting, lint, private-key detection) run on commit. The slow
ones (mypy, `flutter analyze`, migration drift) run on push.

---

## Running things

```bash
# API with reload
cd backend && .venv/bin/uvicorn app.main:app --reload

# Everything in Docker
docker compose up -d
```

The API is on `http://localhost:8000`, interactive docs at `/docs`. Compose
publishes Postgres on **55432** so it cannot collide with a local install.

### Tests

```bash
cd backend
.venv/bin/pytest                        # whole suite (needs Postgres)
.venv/bin/pytest tests/test_config.py   # pure unit tests, no database
.venv/bin/pytest -k encryption -x       # one area, stop at first failure
```

Tests run against **real PostgreSQL, not SQLite.** The schema depends on
`pg_trgm`, `INET`, `JSONB` and partial indexes, so another engine would leave
exactly the interesting parts unverified. Point `TEST_DATABASE_URL` at a
throwaway database — it is created, rebuilt and truncated automatically.

```bash
cd mobile && flutter test
```

---

## Rules that are not negotiable

These are invariants, not preferences. A PR that breaks one will not be merged
even if every test passes.

**1. Ownership on every query.** Every file and folder read or write filters by
the `user_id` from the JWT. A `file_id` in a URL is never sufficient
authorisation. Another user's resource must read as **404, not 403** — a 403
confirms the id exists, which is itself a leak. See `tests/test_ownership.py`.

**2. The backend never persists file bytes.** Large uploads are staged in one
temp file deleted in a `finally`, on success, failure and cancellation alike.

**3. The bot token is a credential.** Never logged, never in an API response,
never in analytics, encrypted at rest. The logging pipeline redacts
credential-shaped keys itself — do not rely on remembering.

**4. Soft delete everywhere.** `is_deleted` + `deleted_at`. Hard deletion only
via the 30-day purge job.

**5. Dedup hashes plaintext, uploads ciphertext.** Otherwise encrypted files
never deduplicate.

**6. All timestamps are UTC**, `TIMESTAMPTZ` in the database.

**7. The error envelope is uniform.** Clients switch on `error.code`, never on
the message. Raise a typed error from `app/core/errors.py`; never build an error
response by hand.

**8. Never break an existing encryption key.** Changing the KDF, its parameters
or the salt for an existing account makes that user's files permanently
unreadable. There is no recovery path — that is the design. New defaults apply
to new accounts only.

---

## Code style

**Python** — `ruff` for lint and formatting, `mypy` in strict mode. Both are
configured in `backend/pyproject.toml` so they behave identically on your
machine and in CI.

```bash
cd backend
.venv/bin/ruff check app tests --fix
.venv/bin/ruff format app tests
.venv/bin/mypy app
```

**Dart** — `dart format`, `flutter analyze --fatal-infos`.

**Comments explain *why*, not *what*.** The code already says what it does.
A comment earns its place by recording a constraint, a trade-off, or the bug
that made the line necessary:

```python
# MTProto only accepts 4 KiB-aligned offsets, so start at the block that
# contains `offset` and discard the leading bytes we did not ask for.
aligned = (offset // MTPROTO_BLOCK) * MTPROTO_BLOCK
```

**Layering.** `api/` → `services/` → `models/`, and `providers/` never imports
`models/`. A storage backend deals in bytes and references; it has no idea
folders exist.

### Database changes

A model change needs a migration in the same commit:

```bash
cd backend
.venv/bin/alembic revision --autogenerate -m "what changed"
# then read it — autogenerate misses index types, constraints and data moves
.venv/bin/alembic upgrade head
.venv/bin/alembic downgrade base && .venv/bin/alembic upgrade head
```

CI runs `alembic check` and a full down-and-up cycle. A migration nobody can
roll back is one you cannot deploy safely.

### Tests

New behaviour needs a test. More usefully: **test through the path production
uses.** A settings bug shipped once because the test passed the value to the
constructor while production loaded it from an environment variable — the test
was green and the container would not boot.

Prefer tests that pin *why* something is the way it is. `tests/test_chunking.py`
checks byte ranges against the original file because an off-by-one at a chunk
boundary produces a corrupt download rather than an error.

---

## Commits and pull requests

**Commits** are small and scoped, prefixed by area:

```
backend(files): reject an encrypted upload before encryption is set up
mobile(upload): retry with exponential backoff on a dropped connection
docs: explain the Supabase session-pooler choice
```

The body explains *why*, and states the failure mode if it is fixing a bug. If
you cannot describe a commit in one line, it is probably two commits.

**Pull requests** should describe what changed and why, list how you tested it,
and include screenshots for UI work. Fill in the template — it exists to save a
review round-trip.

Before opening one:

```bash
cd backend && .venv/bin/pytest && .venv/bin/ruff check app tests && .venv/bin/mypy app
cd ../mobile && flutter analyze && flutter test
```

CI runs all of it plus a Docker build and a migration round-trip.

---

## Reporting security issues

**Please do not open a public issue.** This project handles Telegram bot tokens,
JWT signing keys and users' encrypted files.

Email the maintainer directly with the details and a reproduction. You will get
an acknowledgement within a few days.

Particularly interested in: anything that crosses the ownership boundary between
users, anything that leaks a bot token, and anything that could make an
encrypted file readable without its password.
