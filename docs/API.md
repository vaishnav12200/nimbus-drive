# API Reference

Base URL: `https://your-server/api`. Interactive docs (generated from the running
code) are at `/docs`; this file covers the parts a schema cannot express.

---

## Envelope

Every response, success or failure, uses one of two shapes.

```json
{ "success": true, "data": { }, "meta": { "page": 1, "limit": 50, "total": 247, "pages": 5 } }
```

```json
{ "success": false,
  "error": { "code": "FILE_NOT_FOUND",
             "message": "The requested file does not exist",
             "details": { "file_id": "…" } } }
```

`meta` is present only on paginated responses. **Switch on `error.code`, never on
`error.message`** — messages are written for humans and will change.

Every response carries an `X-Request-ID` header. Send it back in a bug report and
it will match a log line.

---

## Authentication

`Authorization: Bearer <access_token>` on everything except `/health` and the two
public share routes.

Access tokens are RS256 JWTs that live 15 minutes. Refresh tokens are opaque and
live 7 days.

### Rotation

`POST /api/auth/refresh` consumes the presented refresh token and returns a new
pair. **The old one stops working immediately.** Store the new one before you use
it.

Presenting an already-consumed refresh token returns `TOKEN_REUSE_DETECTED` and
revokes *every* session descended from that login — including the one that legitimately
rotated. That is deliberate: a replayed token means either theft or a client bug,
and neither is safe to keep alive. The client's only correct response is to
discard its tokens and ask the user to sign in again.

| Method | Endpoint | Notes |
|---|---|---|
| POST | `/auth/register` | `{email, password, display_name?}` → token pair |
| POST | `/auth/login` | `{email, password}` → token pair |
| POST | `/auth/google` | `{id_token}` — verified against Google's JWKS |
| POST | `/auth/github` | `{code, redirect_uri?}` |
| POST | `/auth/refresh` | `{refresh_token}` → new pair |
| POST | `/auth/logout` | `{refresh_token?}`, auth required |
| POST | `/auth/logout-all` | Revokes every session |
| GET | `/auth/me` | Current account |
| GET | `/auth/sessions` | Live sessions, for a "signed-in devices" screen |

Rate limits: login 10 per 5 minutes (per IP *and* per account), registration 5
per hour per IP. Exceeding either returns `429` with `Retry-After`.

---

## Telegram binding

| Method | Endpoint | Notes |
|---|---|---|
| POST | `/telegram/config` | `{bot_token, channel_id, channel_name?}` |
| GET | `/telegram/config` | Token is **masked**, never returned in full |
| POST | `/telegram/test` | `getMe` + `getChat` + posts a test message |
| DELETE | `/telegram/config` | Deactivates the binding; file metadata is kept |

`channel_id` must be negative (`-1001234567890`); a positive value is rejected as
a pasted user id.

`POST /telegram/test` returns **200 with `ok: false`** when Telegram refuses —
a misconfigured channel is user feedback, not a server error. The `detail` field
is written to be shown directly in the onboarding UI.

---

## Files

### Two upload paths

| Size | Path |
|---|---|
| ≤ 20 MB | Client → Telegram Bot API directly, then `POST /files` with the resulting metadata. The bytes never touch this server. |
| > 20 MB | `POST /files/reserve` → `POST /files/{id}/upload`. The backend streams, chunks and forwards over MTProto. |

`POST /files` rejects anything over 20 MB with `USE_BACKEND_UPLOAD`.

`telegram_channel_id` is **not** accepted in any request body — it is read from
the caller's own binding.

### Large uploads

```
POST /api/files/reserve
{"name": "movie.mp4", "size": 524288000, "mime_type": "video/mp4", "sha256": "…"}
→ 201 {"data": {"id": "…", "telegram_message_id": null}}

POST /api/files/{id}/upload
Content-Type: application/octet-stream
<raw bytes>
→ 200 {"data": {"is_chunked": true, "chunk_count": 27, "chunks": [...]}}
```

`multipart/form-data` with a field named `file` also works, but prefer the raw
body: the multipart parser spools the part to disk before the backend copies it,
costing twice the staging space.

The upload is verified before it is recorded. A byte count that disagrees with
the reserved `size` returns `SIZE_MISMATCH`; a digest that disagrees with a
supplied `sha256` returns `CHECKSUM_MISMATCH`. In both cases nothing is stored,
so a retry is safe.

If the server is already staging its configured maximum of concurrent uploads,
you get `503 UPLOAD_CAPACITY` with `Retry-After`.

### Deduplication

```
GET /api/files/dedup?sha256=<hex>
→ {"data": {"found": true, "file_id": "…", "name": "original.bin"}}
```

Hash the **plaintext**, even when uploading encrypted — that is what makes an
encrypted upload match its unencrypted twin.

### Download

| Endpoint | Use |
|---|---|
| `GET /files/{id}/ticket` | Ask whether the client can fetch straight from Telegram |
| `GET /files/{id}/download` | Stream through the backend; honours `Range` |
| `GET /files/{id}/stream` | Same, `Content-Disposition: inline`, for players |

`ticket` returns `mode: "direct"` plus a `telegram_file_path` when the file is a
single message under 20 MB. Combine it with the bot token the client already
holds:

```
https://api.telegram.org/file/bot<token>/<telegram_file_path>
```

The token is deliberately absent from the response; the path alone is useless
without it. Chunked and oversized files return `mode: "proxy"` — Telegram will
not serve those directly, so the bytes must come through `proxy_url`.

### Range and seeking

Both byte endpoints accept `Range` and answer `206` with `Content-Range`. For a
chunked file the requested offset is mapped onto the chunk that holds it and an
offset within that chunk, so seeking works without downloading the whole file.

An open-ended `bytes=0-` is capped at 8 MB per response. Players ask for
everything and then stop reading; without the cap the server keeps pulling from
Telegram for a client that has gone away. Issue further ranges to continue.

### Other file operations

| Method | Endpoint | Notes |
|---|---|---|
| GET | `/files` | `?folder_id=&root=&trash=&favorites=&sort=&order=&page=&limit=` |
| GET | `/files/{id}` | Includes the chunk manifest |
| PATCH | `/files/{id}` | `{name?, folder_id?, is_favorite?, tags?}` |
| DELETE | `/files/{id}` | Soft delete. `?permanent=true` also deletes the bytes |
| POST | `/files/{id}/restore` | Out of the trash |
| POST | `/files/{id}/move` | `{target_folder_id}` |
| POST | `/files/{id}/copy` | `{target_folder_id?, name?}` |
| POST | `/files/trash/empty` | Permanent, for everything in the trash |

**`folder_id: null` means "move to the root".** Omitting the field leaves the
file where it is. The two are distinguished by whether the key is present in the
JSON body.

**Copies share their bytes.** `POST /files/{id}/copy` creates a second metadata
row pointing at the *same* Telegram message. Deleting one copy never removes
bytes another row still needs — the remote message goes only when the last row
referencing it is purged.

---

## Folders

| Method | Endpoint | Notes |
|---|---|---|
| GET | `/folders` | `?parent_id=` for one level, `?tree=true` for all |
| POST | `/folders` | `{name, parent_id?, color?}` |
| GET | `/folders/{id}` | With breadcrumbs and child counts |
| PATCH | `/folders/{id}` | `{name?, color?, parent_id?}` |
| DELETE | `/folders/{id}` | `?cascade=true` to include contents |

Delete is **restrict by default**: a non-empty folder returns `409
FOLDER_NOT_EMPTY` with the counts in `details`. With `cascade=true` the subtree
is removed and its files are moved to the trash — soft-deleted, never destroyed.
A file restored afterwards reappears at the root, since its folder no longer
exists.

Moving a folder rewrites the materialized `path` of every descendant. Moving one
into its own subtree returns `FOLDER_CYCLE`.

Sibling names must be unique. Names may not contain `/ \ : * ? " < > |` or
control characters.

---

## Search

```
GET /api/search?q=report&type=document&tags=work,2026&size_min=1000&sort=size&order=desc
```

Filters may also be passed as the spec's JSON blob, `?filters={"type":["image"]}`.
When both are given the flat parameters win.

| Filter | Notes |
|---|---|
| `q` | Case-insensitive substring on the name; `%` and `_` are literal |
| `type` | `image`, `video`, `audio`, `document`, `archive`, `other` |
| `folder_id`, `date_from`, `date_to`, `size_min`, `size_max` | |
| `tags` | Comma-separated. A file must carry **all** of them |
| `is_favorite`, `is_deleted` | `is_deleted=true` searches the trash |

`GET /api/search/tags` lists every tag the account has used, with counts.

---

## Sync

```
GET /api/sync?since=2026-08-01T10:00:00Z&limit=200
```

```json
{ "data": {
    "server_time": "2026-08-01T10:05:00Z",
    "next_since": "2026-08-01T10:04:55Z",
    "full_resync_required": false,
    "has_more": false,
    "next_cursor": null,
    "new_files": [], "updated_files": [], "deleted_files": [],
    "new_folders": [], "updated_folders": [], "deleted_folders": [] } }
```

Rules for a client that wants to converge correctly:

1. **Apply every list as an upsert.** `next_since` deliberately lags
   `server_time` by a few seconds so a row committed mid-request cannot fall
   through the boundary, which means you will occasionally re-receive a change
   you already have.
2. **Store `next_since`, not `server_time`.**
3. **While `has_more`, call again with `next_cursor` and the same `since`.**
   Only store `next_since` once `has_more` is false. The cursor is a keyset over
   `(updated_at, id)`, because a bulk operation stamps many rows with an
   identical timestamp.
4. **Honour `full_resync_required`.** It means you have been offline longer than
   deletions are tracked, so a delta can no longer tell you what disappeared.
   Discard the local cache and sync from scratch.

Soft-deleted files arrive in `deleted_files`. Folders are hard-deleted, so their
removal is reported from tombstones — which is why an absent row never means
"deleted".

`GET /api/sync/snapshot` returns server-side row counts to verify a completed
resync.

---

## Share links

| Method | Endpoint | Auth |
|---|---|---|
| POST | `/shares` | Yes — `{file_id, expires_in?, max_downloads?, password?}` |
| GET | `/shares` | Yes — your links |
| DELETE | `/shares/{id}` | Yes — revoke |
| GET | `/shares/{token}` | **No** — public metadata |
| GET | `/shares/{token}/download` | **No** — public bytes |

Password goes in `X-Share-Password` (preferred) or `?password=`. The header keeps
it out of proxy logs and `Referer` headers.

**Encrypted files cannot be shared** (`CANNOT_SHARE_ENCRYPTED`). The recipient
has no key, so the link would deliver unreadable ciphertext.

The public endpoints reveal only name, size, MIME type, and whether a password is
needed — nothing about the owner or their other files. A revoked link, an expired
link and a nonexistent token are deliberately hard to tell apart. Both are rate
limited by IP.

---

## Error codes

| Code | Status | Meaning |
|---|---|---|
| `VALIDATION_ERROR` | 422 | Body failed validation; `details.fields` names each one |
| `INVALID_CREDENTIALS` | 401 | Wrong email or password — indistinguishable by design |
| `INVALID_TOKEN` | 401 | Expired or malformed token; refresh |
| `TOKEN_REUSE_DETECTED` | 401 | Refresh token replayed; all sessions revoked, re-login |
| `PERMISSION_DENIED` | 403 | Includes `SHARE_PASSWORD_REQUIRED` / `SHARE_PASSWORD_INVALID` |
| `FILE_NOT_FOUND` / `FOLDER_NOT_FOUND` | 404 | Also returned for another user's resources |
| `TELEGRAM_NOT_CONFIGURED` | 404 | No channel bound; run onboarding |
| `FOLDER_NOT_EMPTY` | 409 | Retry with `?cascade=true` |
| `ALREADY_UPLOADED` | 409 | That row already has bytes; reserve a new one |
| `SHARE_EXPIRED` | 410 | Expired or download limit reached |
| `FILE_TOO_LARGE` | 413 | Over Telegram's 2 GB per-file cap |
| `RANGE_NOT_SATISFIABLE` | 416 | Requested range lies outside the file |
| `RATE_LIMITED` | 429 | Back off for `details.retry_after` seconds |
| `FLOOD_WAIT` | 429 | Telegram is limiting the bot; wait `details.retry_after` |
| `SIZE_MISMATCH` / `CHECKSUM_MISMATCH` | 400 | Upload did not match what was reserved |
| `BOT_TOKEN_MALFORMED` | 400 | Not a `<digits>:<secret>` token |
| `CHANNEL_INVALID` | 502 | Wrong channel id, or the bot was removed |
| `CHAT_WRITE_FORBIDDEN` | 502 | The bot is not a channel administrator |
| `BOT_BLOCKED` | 502 | Unblock the bot in Telegram |
| `BOT_TOKEN_INVALID` | 502 | Token revoked; re-bind |
| `BOT_TOKEN_UNREADABLE` | 502 | Server's encryption key changed; re-bind |
| `MTPROTO_UNAVAILABLE` | 503 | Server lacks `TELEGRAM_API_ID`/`HASH`; no files > 20 MB |
| `UPLOAD_CAPACITY` | 503 | Too many concurrent uploads, or staging disk is full |

---

## Client-side encryption

The server never sees a password, a key, or plaintext. It holds only the public
values a second device needs to arrive at the same key, and refuses the two
operations that would silently destroy data.

| Method | Endpoint | Notes |
|---|---|---|
| GET | `/api/encryption/recommended` | KDF parameters to use. Unauthenticated |
| GET | `/api/encryption` | Salt, KDF, params, verifier for this account |
| POST | `/api/encryption` | Enable. Mints the salt |
| PUT | `/api/encryption/verifier` | Attach a password-check blob later |
| DELETE | `/api/encryption` | Disable. `?force=true` to override the guard |

### The flow a client implements

```
1. GET  /api/encryption/recommended     → kdf, params, iv_bytes, cipher
2. user chooses a password              → never leaves the device
3. POST /api/encryption {kdf, params}   → server returns a 32-byte salt
4. key = KDF(password, salt, params)    → derived locally, held in memory
5. verifier = AES-256-GCM(known text)   → PUT /api/encryption/verifier
```

On a new device: `GET /api/encryption`, prompt for the password, derive the key,
and decrypt `verifier` to check it before fetching anything.

### Rules the server enforces

**Enabling twice returns 409.** A second salt would orphan every file encrypted
under the first, and there is no recovery path.

**Disabling with encrypted files returns 409**, including files in the trash,
since those are restorable. `?force=true` accepts that they become unreadable —
it deletes nothing.

**Uploading with `is_encrypted: true` before enabling returns 400.** The row
would describe a file whose key nothing on the server can reproduce.

**Encrypted files cannot be shared** (`CANNOT_SHARE_ENCRYPTED`). A recipient has
no key.

### Parameters

Defaults are Argon2id `m=65536, t=3, p=1` with a 12-byte IV and AES-256-GCM.
A client may choose `pbkdf2-sha256` instead, or stronger parameters, but values
below the OWASP minimum are rejected with 422 — the user cannot tell weak
parameters from strong ones, and cannot recover from the difference.

`kdf` and `kdf_params` are stored per account so the defaults can be raised
later without changing the key that opens anyone's existing files.

### Two things that are not the server's job

Dedup hashes the **plaintext**, so `sha256` is computed before encryption —
otherwise identical files would never deduplicate.

The password is stored nowhere. Forgetting it means the data is unrecoverable,
which is the design.
