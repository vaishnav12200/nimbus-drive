# Nimbus Drive

**Personal cloud storage backed by your own Telegram channel.**

Nimbus Drive turns a private Telegram channel into unlimited personal cloud storage, with a
proper file manager on top: folders, search, sharing, offline cache, streaming and optional
client-side encryption.

Your files live in *your* Telegram channel. The backend stores only metadata — never file
bytes. You self-host the backend, so nobody else is in the loop.

---

## Table of Contents

- [Why](#why)
- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Core Flows](#core-flows)
- [Data Model](#data-model)
- [API Reference](#api-reference)
- [Security Model](#security-model)
- [Repository Layout](#repository-layout)
- [Getting Started](#getting-started)
- [Tech Stack](#tech-stack)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## Why

Commercial cloud storage is metered, expensive and reads your files. Telegram gives every
account effectively unlimited storage with a 2 GB per-file limit — but it is a chat app, not
a drive. There are no folders, no real search, no offline cache, no share links.

Nimbus Drive is the missing file-manager layer:

| | Google Drive / Dropbox | Raw Telegram | Nimbus Drive |
|---|---|---|---|
| Storage cost | Paid past ~15 GB | Free | Free |
| Folders & search | Yes | No | Yes |
| Who holds your bytes | The vendor | You (your channel) | You (your channel) |
| Who holds your metadata | The vendor | — | You (your server) |
| End-to-end encryption | No | No | Optional, client-side |

---

## How It Works

1. You create a **private Telegram channel** — this is your storage bucket.
2. You create a **Telegram bot** via [@BotFather](https://t.me/BotFather) and add it to the
   channel as an administrator — this is your write credential.
3. The Flutter app uploads files into that channel and records the resulting
   `message_id` / `file_id` in your self-hosted backend.
4. Everything a "drive" needs — folder tree, names, tags, favourites, trash, share links —
   lives as **metadata in PostgreSQL**. Telegram has no idea folders exist.
5. Downloads resolve metadata back to a Telegram message and pull the bytes.

The key property: **the backend is stateless with respect to file content.** A backend breach
leaks a file listing, not your files.

---

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                          CLIENT LAYER                             │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐   │
│  │ Flutter App  │  │ Local SQLite │  │ Flutter Secure Storage │   │
│  │ (UI + Logic) │  │ (Offline DB) │  │ (Tokens, Keys, Config) │   │
│  └──────┬───────┘  └──────────────┘  └────────────────────────┘   │
│         │                                                         │
│  ┌──────▼────────┐                                                │
│  │ Telegram Bot  │  ── direct upload/download, files ≤ 20 MB ──┐  │
│  │ API Client    │                                             │  │
│  └───────────────┘                                             │  │
└──────────────────────┬─────────────────────────────────────────┼──┘
                       │ HTTPS / JSON                            │
                       ▼                                         │
┌───────────────────────────────────────────────────────────────┐│
│                    BACKEND LAYER (FastAPI)                    ││
│  ┌──────────────┐  ┌────────────────┐  ┌───────────────────┐  ││
│  │ Auth Service │  │  Metadata API  │  │  Storage Router   │  ││
│  │ (JWT/OAuth)  │  │ (CRUD + Search)│  │ (Provider Abstr.) │  ││
│  └──────────────┘  └───────┬────────┘  └─────────┬─────────┘  ││
│                            │                     │            ││
│  ┌──────────────┐  ┌───────▼──────┐  ┌───────────▼─────────┐  ││
│  │  Encryption  │  │  PostgreSQL  │  │  Telegram MTProto   │  ││
│  │   Service    │  │  (Metadata)  │  │ (Large File Handler)│  ││
│  └──────────────┘  └──────────────┘  └──────────┬──────────┘  ││
└──────────────────────────────────────────────────┼────────────┘│
                                                   ▼             ▼
                                        ┌────────────────────────────┐
                                        │  Your private Telegram     │
                                        │  channel (file bytes)      │
                                        └────────────────────────────┘
```

### Deployment model

| Component | Where it runs |
|---|---|
| **Client** | Flutter app — GitHub Releases + F-Droid |
| **Backend** | FastAPI (Docker) on Render |
| **Database** | PostgreSQL on Supabase (Docker locally) |
| **Storage** | Your own Telegram channel — zero backend persistence of bytes |

### Why two upload paths

The Telegram **Bot API** caps uploads at 20 MB, but **MTProto** (the underlying protocol,
used via Telethon) allows up to 2 GB. So:

| File size | Path | Reason |
|---|---|---|
| ≤ 20 MB | App → Telegram Bot API (direct) | Fastest — backend never touches the bytes |
| > 20 MB | App → Backend → MTProto | Only route that can exceed 20 MB; backend chunks into 19 MB segments |

---

## Core Flows

### 1. Onboarding

```
Register (email / Google / GitHub)
   ↓
Create a private Telegram channel          (guided, in-app instructions)
   ↓
Create a bot via @BotFather → paste token  (validated: GET /bot<token>/getMe)
   ↓
Add bot as channel admin
   ↓
Get channel ID via @userinfobot → paste    (e.g. -1001234567890)
   ↓
Connection test: bot posts "Nimbus Drive connected" to the channel
   ↓
Initial sync — pull any existing channel files into the local SQLite cache
   ↓
Onboarding complete
```

Bot token and channel ID are stored in **Flutter Secure Storage** (Keychain / Keystore),
never in plain preferences.

### 2. Upload — small files (≤ 20 MB)

```
Select file → read bytes
   ↓
If encryption enabled → AES-256-GCM encrypt on device
   ↓
Compute SHA-256
   ↓
Hash already in local SQLite for this user?
   ├── Yes → skip the upload, just write a metadata row pointing at the existing message
   └── No  → continue
   ↓
POST api.telegram.org/bot<token>/sendDocument
   ↓
Telegram returns { message_id, file_id, file_unique_id }
   ↓
POST /api/files with the metadata  →  backend validates, writes to PostgreSQL
   ↓
Backend returns the file UUID  →  app inserts into local SQLite  →  notify complete
```

### 3. Upload — large files (> 20 MB)

```
Select file → compute SHA-256 → dedup check
   ↓
POST /api/files/{id}/upload (multipart) to the backend
   ↓
Backend streams to temp storage, splits into 19 MB chunks
   ↓
For each chunk: upload via Telethon (MTProto), capture its message_id
   ↓
Backend writes a manifest: { is_chunked: true, chunk_count: N, chunks: [...] }
   ↓
Backend returns the file UUID → app syncs metadata to local SQLite
```

Reassembly on download is the reverse: fetch chunks in `chunk_index` order and concatenate.

### 4. Upload state machine

```
[QUEUED] → [UPLOADING] → [VERIFYING] → [COMPLETED]
                ↓
            [PAUSED] → [UPLOADING]
                ↓
            [FAILED] → [RETRY] → [UPLOADING]
                ↓
           [CANCELLED]
```

Queue lives in a local SQLite `upload_queue` table with `retry_count` and `next_retry_at`.
Backoff is exponential: 5s, 10s, 20s, 40s, 80s … capped at 1 hour.

### 5. Download

```
Tap download / open
   ↓
Cached locally?  ── Yes ──→ serve from cache
   ↓ No
GET /api/files/{id}/download
   ↓
≤ 20 MB with a file_id  → backend returns a Bot API download URL (or app fetches directly)
> 20 MB or chunked      → backend streams from MTProto and proxies to the app
   ↓
If encrypted → decrypt with the derived key
   ↓
Save to sandbox → update local_cache (cache_path, cached_at) → open in viewer
```

### 6. Streaming (video / audio)

```
Tap play → GET /api/files/{id}/stream with an HTTP Range header
   ↓
Backend translates the Range header into an MTProto file offset
   ↓
Backend streams chunks from Telegram → HTTP 206 Partial Content → player buffers
```

### 7. Metadata sync

Source of truth is **PostgreSQL**; SQLite is a cache. Sync is pull-based with optimistic
local updates.

```
App start / foreground / pull-to-refresh / every 15 min in background
   ↓
GET /api/sync?since=<last_sync_timestamp>
   ↓
Backend returns deltas: new/updated/deleted files, new/updated/deleted folders
   ↓
App applies them to SQLite in one transaction → advances last_sync_timestamp
```

**Optimistic updates:** rename / move / favourite apply to the UI immediately, the API call
fires in the background, and the UI reverts with an error toast if the call fails.

**Conflict resolution:**

| Scenario | Resolution |
|---|---|
| Renamed locally and remotely | Last-write-wins (timestamp comparison) |
| Moved to different folders | Last-write-wins, notify the user |
| Deleted locally, modified remotely | Prompt: restore or keep deleted |
| Offline edits on two devices | Merge if possible, otherwise a manual conflict UI |

### 8. Folders

Folders exist **only in PostgreSQL** — Telegram knows nothing about the hierarchy. Each
folder stores a materialized `path` (e.g. `/Documents/Work/2026`) so breadcrumbs and subtree
queries stay cheap. Moving a folder updates `parent_id` and recalculates the path for every
descendant.

| Folder | ID | Behaviour |
|---|---|---|
| Root | `NULL` (implicit) | Default location, cannot be deleted |
| Trash | System folder | Soft-deleted files, auto-purged after 30 days |
| Favorites | Virtual | `is_favorite = true`, spans folders |

### 9. Search

All search runs against PostgreSQL metadata — Telegram message search is never used.

```
GET /api/search?q=<query>&filters=<json>&sort=<field>&order=<asc|desc>&limit=50&offset=0
```

Filters: `type`, `folder_id`, `date_from`, `date_to`, `size_min`, `size_max`, `tags`,
`is_favorite`, `is_deleted`.

Backed by a trigram GIN index on `name`, plus composite indexes on
`(user_id, folder_id, is_deleted, created_at)` and `(user_id, size)`.

### 10. Background tasks

| Task | Schedule | Notes |
|---|---|---|
| Auto-upload photos | On new camera-roll / MediaStore item | Selected albums only; Wi-Fi only (configurable), battery > 20%; SHA-256 dedup |
| Metadata sync | Every 15 min, on foreground, manual pull | Metadata only, delta via `since` |
| Cache cleanup | Daily | LRU eviction down to the limit; never evicts favourites |

Android uses WorkManager; iOS uses background `URLSession` (~30s, best effort).

### 11. Offline cache

Cached in the sandboxed app documents directory, default limit 500 MB (user-configurable),
evicted **LRU**:

```sql
CREATE TABLE local_cache (
    file_id       TEXT PRIMARY KEY,
    local_path    TEXT,
    size_bytes    INTEGER,
    cached_at     TIMESTAMP,
    last_accessed TIMESTAMP,
    access_count  INTEGER DEFAULT 1
);
```

---

## Data Model

```
users ||--o{ files                  : owns
users ||--o{ folders                : owns
users ||--o{ user_telegram_configs  : has
users ||--o{ activity_logs          : generates
folders ||--o{ files                : contains
files ||--o{ file_tags              : tagged
files ||--o{ file_chunks            : chunked
files ||--o{ shared_links           : shared
files ||--o{ activity_logs          : referenced
```

Tables: `users`, `user_telegram_configs`, `folders`, `files`, `file_chunks`, `file_tags`,
`shared_links`, `activity_logs`. Full column definitions live in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §12.

The `files` table is the centre of gravity — it carries the Telegram pointers
(`telegram_message_id`, `telegram_file_id`, `telegram_channel_id`), the dedup hash
(`sha256`), and the state flags (`is_chunked`, `is_encrypted`, `is_favorite`, `is_deleted`).

---

## API Reference

All responses share one envelope:

```json
{ "success": true, "data": { }, "meta": { "page": 1, "limit": 50, "total": 247 } }
```

```json
{ "success": false, "error": { "code": "FILE_NOT_FOUND",
                               "message": "The requested file does not exist",
                               "details": { "file_id": "uuid" } } }
```

**Auth**

| Method | Endpoint | Body |
|---|---|---|
| POST | `/api/auth/register` | `{email, password}` |
| POST | `/api/auth/login` | `{email, password}` |
| POST | `/api/auth/google` | `{id_token}` |
| POST | `/api/auth/github` | `{code}` |
| POST | `/api/auth/refresh` | `{refresh_token}` |
| POST | `/api/auth/logout` | auth required |
| GET | `/api/auth/me` | auth required |

**Files**

| Method | Endpoint | Notes |
|---|---|---|
| GET | `/api/files` | `?folder_id=&page=&limit=` |
| GET | `/api/files/{id}` | |
| POST | `/api/files` | metadata → returns file UUID |
| POST | `/api/files/{id}/upload` | multipart, large files |
| GET | `/api/files/{id}/download` | redirect or stream |
| GET | `/api/files/{id}/stream` | `?range=` for video/audio |
| PATCH | `/api/files/{id}` | `{name, folder_id, is_favorite, tags}` |
| DELETE | `/api/files/{id}` | soft delete |
| POST | `/api/files/{id}/restore` | from trash |
| POST | `/api/files/{id}/copy` | `{target_folder_id}` |
| POST | `/api/files/{id}/move` | `{target_folder_id}` |

**Folders** — `GET /api/folders?parent_id=`, `GET /api/folders/{id}`,
`POST /api/folders {name, parent_id, color}`, `PATCH /api/folders/{id} {name, color}`,
`DELETE /api/folders/{id}` (cascade or restrict).

**Search** — `GET /api/search?q=&filters=&sort=&order=&limit=&offset=`

**Sync** — `GET /api/sync?since=timestamp`

**Share links** — `POST /api/shares {file_id, expires_in, max_downloads, password}`,
`GET /api/shares/{token}` (public metadata), `GET /api/shares/{token}/download` (public
stream), `DELETE /api/shares/{id}` (auth required).

---

## Security Model

| Threat | Mitigation |
|---|---|
| File intercepted in transit | HTTPS everywhere, TLS 1.3 |
| Backend breach | Backend never stores file bytes — metadata only |
| Device theft | App lock (PIN / biometric), encrypted local cache |
| Telegram account compromised | Files encrypted with user-held keys |
| Man-in-the-middle | Certificate pinning on the API domain |
| Replay attacks | JWT `jti` claim + short expiry |

### Tokens

- **Access token** — 15 minutes, RS256 signed. Claims: `sub`, `email`, `iat`, `exp`, `jti`.
- **Refresh token** — 7 days, httpOnly cookie on web / secure storage on mobile.
- **Revocation** — optional Redis blacklist.

### Optional client-side encryption

```
key       = PBKDF2(password, salt, iterations=100_000, sha256)
salt      = random(32 bytes), stored in the backend
ciphertext= AES-256-GCM(plaintext, key, iv), iv = random(16 bytes) prepended
```

The password is **never stored anywhere**. The key is derived on demand in memory, and may
optionally be cached in secure storage for the session. Forgetting the password means the
data is unrecoverable — that is the design, not a bug.

### Bot token handling

Stored in Flutter Secure Storage. Never logged, never sent to analytics. The backend only
ever sees it on the large-file path, and encrypts it at rest (AES-256-GCM, app-level key)
when it does.

---

## Repository Layout

```
nimbus-drive/
├── README.md
├── LICENSE
├── docker-compose.yml
├── backend/
│   ├── app/
│   │   ├── api/          # Route handlers
│   │   ├── core/         # Config, security, logging
│   │   ├── models/       # SQLAlchemy models
│   │   ├── schemas/      # Pydantic schemas
│   │   ├── services/     # Business logic
│   │   └── providers/    # StorageProvider implementations
│   ├── alembic/          # Database migrations
│   ├── tests/
│   ├── Dockerfile
│   └── requirements.txt
├── mobile/
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app.dart
│   │   ├── core/         # Constants, theme, router
│   │   ├── data/         # Repositories, API clients
│   │   ├── domain/       # Models, entities
│   │   ├── presentation/ # Screens, widgets, providers
│   │   └── services/     # Local DB, encryption, file handling
│   ├── android/
│   ├── ios/
│   └── pubspec.yaml
└── docs/
    ├── ARCHITECTURE.md
    ├── API.md
    └── SETUP.md
```

> **Status:** the backend is built and tested; `mobile/` is still the bare Flutter scaffold.
> See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the backend as implemented and
> [`docs/SETUP.md`](docs/SETUP.md) for self-hosting it.

---

## Getting Started

### Prerequisites

| Backend | Mobile |
|---|---|
| Python 3.11+ | Flutter 3.22+ |
| FastAPI + Uvicorn | Dart 3.4+ |
| PostgreSQL 15+ | Android SDK 34+ |
| Redis (optional, caching) | Xcode 15+ (iOS) |
| Docker + docker-compose | |

### Backend

```bash
cp .env.example .env          # set JWT_SECRET, DATABASE_URL, TELEGRAM_API_ID/HASH
docker compose up -d
docker compose exec api alembic upgrade head
```

The API comes up on `http://localhost:8000`, with OpenAPI docs at `/docs`.

### Mobile

```bash
cd mobile
flutter pub get
flutter run
```

On first launch the app asks for your backend URL, then walks you through the Telegram
onboarding described above.

### Telegram setup (in-app, summarised)

1. Create a **private channel** in Telegram.
2. Message [@BotFather](https://t.me/BotFather) → `/newbot` → copy the HTTP API token.
3. Add the bot to your channel **as an administrator**.
4. Forward any channel message to [@userinfobot](https://t.me/userinfobot) to get the
   channel ID (looks like `-1001234567890`).
5. Paste the token and channel ID into the app and run the connection test.

---

## Tech Stack

**Mobile** — Flutter, Riverpod (state), sqflite/drift (local cache),
flutter_secure_storage (secrets), dio (HTTP), WorkManager (background upload).

State is split across focused providers: `auth`, `telegram_config`, `folder_tree`,
`current_folder`, `file_list`, `upload_queue`, `download_cache`, `search`, `settings`,
`sync`.

**Backend** — FastAPI, SQLAlchemy + Alembic, PostgreSQL, Telethon (MTProto), Redis
(optional), Pydantic, structlog.

### Storage provider abstraction

Telegram is one implementation behind an interface, so other backends can be dropped in:

```python
class StorageProvider(ABC):
    @abstractmethod
    async def upload(self, file_stream, metadata, credentials): ...
    @abstractmethod
    async def download(self, ref, offset=0, limit=None): ...
    @abstractmethod
    async def delete(self, ref): ...
    @abstractmethod
    async def get_info(self, ref): ...
```

Planned: `S3Storage` (S3 / R2 / MinIO), `LocalStorage` (NAS), `IPFSStorage`. Migration is
lazy — flip `provider_type` and move each file on next access.

### Error handling

| Category | Handling |
|---|---|
| Network | Queue for retry, show offline banner |
| Telegram API | Exponential backoff, user notification |
| Auth | Refresh-token flow, else redirect to login |
| Validation | Inline field errors, block submission |
| Storage | Graceful degradation, prompt to clear cache |
| Unknown | Log to backend, generic error, allow retry |

Telegram-specific: `FLOOD_WAIT_X` (wait X seconds), `BOT_BLOCKED` (prompt to unblock),
`CHANNEL_INVALID` (reconfigure), `CHAT_WRITE_FORBIDDEN` (bot needs admin),
`FILE_TOO_LARGE` (chunk it).

Retry schedule: immediate → 5s → 15s → 45s → 2 min (max 10 attempts).

### Privacy

No third-party analytics — no Google Analytics, no Firebase. Optionally self-host PostHog or
Plausible. Collected: feature usage and error rates. Never collected: file names, content
metadata, Telegram IDs. Logs carry hashed user IDs only, rotate at 10 MB, keep 5 files.

---

## Roadmap

| Phase | Scope |
|---|---|
| **1 — Foundation** | Repo restructure, Docker, schema + migrations, auth |
| **2 — Telegram core** | Onboarding, bot binding, small-file upload/download |
| **3 — Drive UX** | Folders, trash, favourites, rename/move/copy, search |
| **4 — Large files** | MTProto chunked upload, reassembly, streaming with Range |
| **5 — Sync & offline** | Delta sync, SQLite cache, LRU eviction, conflict handling |
| **6 — Extras** | Share links, client-side encryption, photo auto-backup, app lock |
| **7 — Release** | Hardening, tests, CI, F-Droid + GitHub Releases |

Detailed task breakdown lives in the project TODO (local, not tracked in git).

---

## Contributing

- **Code style** — `black` + `ruff` (Python), `dart format` (Flutter)
- **Pre-commit hooks** — `ruff`, `mypy`, `flutter analyze`
- **Issues** — use the bug report / feature request templates
- **PRs** — include a description, testing steps and screenshots for UI changes

---

## License

[MIT](LICENSE) © 2026 Vaishnav K M. Assets: CC-BY-SA.

---

*Architecture reference: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) is the canonical
technical spec. Update it whenever architecture changes.*
