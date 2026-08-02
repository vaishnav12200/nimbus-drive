# Architecture

The canonical technical description of the Nimbus Drive backend **as built**.
Update it when the architecture changes.

The README is the overview; this file is the detail — the schema, the decisions
that are not obvious from the code, and the failure modes.

---

## 1. The core property

> **The backend is stateless with respect to file content.**

File bytes live in the user's own Telegram channel. This server stores metadata:
names, the folder tree, tags, share links, and the Telegram message ids that
point at the bytes. A breach of this server leaks a file *listing*, not files.

Two consequences run through everything:

* Bytes that pass through the backend (the large-file path) are staged in one
  temporary file and deleted in a `finally`. Nothing else writes file content to
  disk.
* Deleting a file here does not delete it from Telegram unless we are explicitly
  purging and no other metadata row still references that message.

---

## 2. Layers

```
app/
├── api/routes/    HTTP surface. Parses, authorises, delegates. No SQL.
├── services/      Business logic. Owns transactions' contents, not their boundary.
├── providers/     StorageProvider implementations. Bytes only, no database.
├── models/        SQLAlchemy models. The schema is the source of truth.
├── schemas/       Pydantic request/response contracts.
├── core/          Config, DB, security, crypto, errors, logging, rate limits.
└── jobs/          Out-of-process scheduled work.
```

The rule that keeps this honest: **`providers/` never imports `models/`**. A
storage backend deals in bytes and references; it has no idea folders exist.
That is what makes `S3Storage` a drop-in.

### Transaction boundary

One transaction per request, opened and closed by the `get_session` dependency.
It commits when the handler returns and rolls back on any exception. Services
`flush()`; they do not `commit()`.

The single deliberate exception is refresh-token reuse detection, which commits
the family revocation *before* raising — otherwise the rollback would undo the
security action the error is reporting.

**Streaming caveat.** FastAPI tears down dependencies before a streaming body is
sent, so the session is closed by the time bytes flow. Every streaming endpoint
therefore resolves everything it needs (the chunk plan, the credentials) into
plain dataclasses while the session is still open. Touching an ORM object inside
a stream generator raises `MissingGreenlet`.

---

## 3. Storage: why two transports

| | Bot API | MTProto (Telethon) |
|---|---|---|
| Upload limit | 20 MB | 2 GB |
| Download limit | 20 MB | 2 GB |
| Arbitrary byte ranges | No | Yes |
| Complexity | One HTTPS call | Session, auth key, peer resolution |

Small files go client → Telegram directly and never touch this server. Large
files must go through the backend, because only MTProto can carry them and only
MTProto can serve the byte ranges that make video seeking work.

### Bots and MTProto

Two things about bot accounts shaped the implementation:

* **Bots cannot browse channel history.** They *can* fetch a message by explicit
  id, which is exactly why every file row stores `telegram_message_id`. This
  resolves the "does the backend need a user session?" question: it does not.
* **Bots often cannot resolve a channel id from cache**, having no dialog list.
  Telegram accepts `access_hash=0` from a bot for a channel it belongs to, which
  is the documented fallback `_resolve_peer` uses.

Telethon sessions are held in memory (`StringSession`), not on disk. Telethon's
default `*.session` file is a live credential; keeping it out of the filesystem
means a container image or a stray backup cannot leak one. The cost is one
handshake per bot after a restart.

### Chunking

Files over 20 MB are split into 19 MB segments, each sent as its own Telegram
message, recorded in `file_chunks` with an `offset`. Segments upload
**sequentially** — Telegram rate-limits a bot hard enough that parallel uploads
trade a modest speed-up for `FLOOD_WAIT` responses that stall the whole file.

If a segment fails permanently, the segments already sent are deleted before the
error propagates. Otherwise a retry would accumulate orphaned messages in the
user's channel with nothing referencing them.

Reads are the reverse: a requested byte range is mapped onto the chunks it
touches and an offset within each. MTProto requires 4 KiB-aligned offsets, so
reads start at the containing block and discard the leading bytes.

---

## 4. Schema

Eight tables from the spec, plus two additions justified below.

### `users`
`id`, `email` UNIQUE, `password_hash` (nullable — OAuth-only accounts have none),
`display_name`, `google_id` UNIQUE, `github_id` UNIQUE, `encryption_enabled`,
`encryption_salt`, `encryption_kdf`, `encryption_kdf_params` JSONB,
`encryption_verifier`, `is_active`, `last_login_at`, timestamps.

### `user_telegram_configs`
`user_id` → users CASCADE, `bot_token_encrypted` (AES-256-GCM), `bot_token_hint`
(last 4 chars, for masked display), `bot_username`, `channel_id` BIGINT,
`channel_name`, `is_active`, `last_tested_at`, `last_test_ok`.
UNIQUE `(user_id, channel_id)`. One active binding per user.

### `folders`
`user_id` CASCADE, `parent_id` → folders CASCADE, `name`, `color`, **`path`**,
timestamps. UNIQUE `(user_id, parent_id, name)` plus a partial unique index on
`(user_id, name) WHERE parent_id IS NULL` — a composite unique index does not
constrain root folders, because NULL never equals NULL.

### `files`
`user_id` CASCADE, `folder_id` → folders **SET NULL**, `name`, `original_name`,
`size`, `mime_type`, `sha256`, `storage_provider`, `telegram_message_id`,
`telegram_file_id`, `telegram_file_unique_id`, `telegram_channel_id`,
`is_chunked`, `chunk_count`, `is_encrypted`, `is_favorite`, `is_deleted`,
`deleted_at`, timestamps.

`folder_id` is SET NULL, not CASCADE: deleting a folder must never silently
destroy the only record of where a user's bytes live. Orphans fall back to the
root.

Check constraints enforce `size >= 0`, that `chunk_count > 0` exactly when
`is_chunked`, and that `deleted_at` is set exactly when `is_deleted`.

### `file_chunks`
`file_id` CASCADE, `chunk_index`, `size`, **`offset`**, `telegram_message_id`,
`telegram_file_id`. UNIQUE `(file_id, chunk_index)`.

`offset` is stored rather than summed at read time so a Range request can jump
straight to the chunk holding a byte position.

### `file_tags`
Composite PK `(file_id, tag)`. No surrogate key.

### `shared_links`
`file_id` CASCADE, `user_id` CASCADE (denormalised so listing and authorising
need no join), `token` UNIQUE, `expires_at`, `max_downloads`, `download_count`,
`password_hash`, `revoked_at`.

### `activity_logs`
`user_id` CASCADE, `file_id` **SET NULL**, `action`, `ip_address` INET,
`user_agent`, `details` JSONB, `created_at`. SET NULL so purging a file does not
erase the record that it was purged.

### `refresh_tokens` *(addition)*
The spec asks for rotating refresh tokens with reuse detection. That is
unimplementable without server-side state, and Redis is optional here. Tokens are
stored as SHA-256 digests, so a database dump yields no usable credentials.
`family_id` links every token descended from one login.

### `sync_tombstones` *(addition)*
Files stay queryable after a soft delete, so they need no tombstone until purged.
**Folders are hard-deleted**, which leaves an offline client with no way to learn
a folder is gone — "absent from a delta" is indistinguishable from "unchanged".
Tombstones close that hole. They are swept after 90 days; a client away longer
gets `full_resync_required`.

### Indexes

| Index | Purpose |
|---|---|
| `ix_files_name_trgm` GIN `(name gin_trgm_ops)` | Makes `ILIKE '%q%'` index-backed |
| `(user_id, folder_id, is_deleted, created_at)` | Folder listing |
| `(user_id, size)` | Size filters |
| `(user_id, sha256)` | Dedup — *spec gap; the spec queried it unindexed* |
| `(user_id, updated_at)` | Sync deltas — *spec gap* |
| `(telegram_channel_id, telegram_message_id)` partial | Refcount before remote delete |
| `(deleted_at) WHERE is_deleted` | Trash purge sweep |
| `file_tags(tag)` | Tag filters |

The trigram index is raw DDL — Alembic cannot express an operator class — and is
excluded from autogenerate so it is not proposed for deletion every revision.

---

## 5. Decisions

### Copy = refcount, not copy-on-write
Copying a file creates a second metadata row pointing at the same Telegram
message. Duplicating 500 MB of bytes to give them a second name would be absurd.
The consequence is that nothing deletes a remote message casually: `purge_file`
first confirms no surviving row references that `(channel_id, message_id)`.

### Folder delete: restrict by default
`DELETE /folders/{id}` on a non-empty folder is a `409`. `?cascade=true` opts in,
and even then files are only *soft*-deleted. The destructive reading of "delete
this folder" is never the default.

### Encrypted files cannot be shared
The key never leaves the user's device, so a recipient would download unreadable
ciphertext. Putting the key in the URL fragment would work in principle —
fragments are not sent to the server — but needs a web client to decrypt, and
this project ships mobile only. Refusing with a clear error beats handing someone
a link that silently produces garbage.

### Sync boundary and pagination
Two problems the naive implementation gets wrong:

*The boundary.* A row committed while the sync query runs can carry an
`updated_at` earlier than the timestamp we return, so the next delta filtering on
`updated_at > next_since` would never see it. `next_since` is therefore
`now() - 5s`. Clients re-apply a few seconds of already-seen changes, which is
free because deltas are applied as upserts.

*Pagination.* Bulk operations stamp many rows with an identical `updated_at` —
one `UPDATE ... SET deleted_at = now()` covers a whole subtree. Paginating on the
timestamp alone would either skip rows or loop forever inside such a group.
Pagination is keyset-based on `(updated_at, id)`, which is unique and totally
ordered.

### Spec deviations
| Spec says | Built | Why |
|---|---|---|
| AES-GCM IV = 16 bytes | **12 bytes** — resolved | 12 is the standard GCM nonce; 16 forces an extra GHASH derivation and interoperates badly for no gain. Served by `GET /api/encryption/recommended` so clients do not hard-code it |
| PBKDF2 100k iterations | **Argon2id default, floors enforced** — resolved | 100k is ~1/6 of current OWASP guidance. The server now records the KDF and its parameters per user and rejects anything below the OWASP minimum (Argon2id m=19456/t=2, or PBKDF2 600k) |
| No rate limiting | Login, registration and public share routes limited | Without it `/auth/login` is open to credential stuffing and share tokens can be swept |
| Refresh token in a JWT | Opaque random, stored hashed | Revocation needs a server-side lookup regardless; opaque means a database dump yields nothing usable |

---

## 6. Security

| Control | Where |
|---|---|
| Ownership on every query | Every file/folder read and write filters by `user_id` from the JWT. Another user's id reads as 404, not 403 — 403 confirms the resource exists. |
| Bot tokens at rest | AES-256-GCM, AAD bound to the owning `user_id`, so a row moved between users fails to decrypt rather than succeeding. |
| Passwords | Argon2id. Login verifies even for unknown accounts so timing does not enumerate addresses. |
| Access tokens | RS256, 15 min, with `jti`. Optional Redis blacklist for logout. |
| Refresh tokens | Rotating, hashed at rest, family-revoked on reuse. |
| Log hygiene | The logging pipeline scrubs credential-shaped keys and hashes user ids, whatever the call site passed. |
| Share tokens | ≥ 32 bytes CSPRNG. Public routes rate limited and deliberately vague about why a token failed. |

### What is *not* protected

* **A compromised bot token gives full access to the channel.** Nothing here can
  prevent that; users rotate it via @BotFather and re-bind.
* **Telegram sees the file bytes** unless client-side encryption is on. This is
  storage on someone else's computer, only without the folders.
* **A user deleting messages directly in their channel** leaves metadata pointing
  at nothing. `verify_remote()` detects it; a reconciliation job that marks such
  rows is not built yet.

---

## 7. Failure modes

| Failure | Behaviour |
|---|---|
| Database unreachable | `/health` 503; the orchestrator stops routing traffic |
| Redis unreachable | Degraded, not down — blacklist checks fail *open* and rate limits fall back to per-process. Failing closed would take the API down with Redis. |
| Telegram `FLOOD_WAIT` | Surfaced with `retry_after`; chunk uploads honour it and retry |
| Chunk upload fails mid-file | Already-sent messages deleted, error raised, no partial metadata |
| Upload truncated | `SIZE_MISMATCH`, nothing recorded, retry is safe |
| Staging disk full | `503 UPLOAD_CAPACITY` before any bytes are accepted |
| Encryption key changed | `BOT_TOKEN_UNREADABLE`; re-binding fixes it. There is no key-rotation migration |
| Client offline > 90 days | `full_resync_required` |

---

## 8. Known gaps

* **Resumable uploads.** A dropped connection at 90% restarts from zero.
  `Content-Range` resume is the intended fix.
* **Key rotation** for `SECRET_ENCRYPTION_KEY` requires re-binding every channel.
* **Reconciliation** for messages deleted directly in Telegram is detectable but
  not automated.
* **Files over 2 GB** are rejected rather than split across multiple messages.
* **The in-process rate limiter** is per-worker. Configure Redis for a real limit
  across replicas.
