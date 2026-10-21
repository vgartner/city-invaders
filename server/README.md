# City Invaders API

Backend for the City Invaders game. One small Node service:

- **Bah**: the in-game AI assistant on the tablet (any OpenAI-compatible chat API - OpenRouter by default, like Synaptia and Horario IA).
- **Feedback**: bug reports and ideas sent from the released game, with an optional screenshot.
- **Mods**: players upload mod zips; an admin approves them; the game lists and downloads them.
- **MCP**: an admin endpoint so Claude (Claude Code, Claude Desktop) can triage feedback,
  approve mods, read Bah conversations and see usage.

## Architecture

```
game (Godot) ──HTTPS + X-Game-Key──┐
                                   ▼
                      nginx-proxy (TLS, VGData)
                                   ▼
              city-invaders-api (Fastify, Node 22)
               ├─ /api/bah/chat ──────► LLM_BASE_URL (OpenRouter, BAH_MODEL)
               ├─ /api/feedback, /api/mods
               ├─ /api/admin/*  (Bearer ADMIN_TOKEN)
               ├─ /mcp          (Bearer ADMIN_TOKEN, MCP Streamable HTTP, stateless)
               └─ /data volume: city-invaders.db (SQLite, WAL), screenshots/, mods/, tmp/
```

| Path | What |
|---|---|
| `src/index.ts` | entry point: config, listen, graceful shutdown |
| `src/app.ts` | Fastify app: auth hook, error format, route registration |
| `src/config.ts` | every environment variable and its default |
| `src/db.ts` | SQLite schema (created on start) and queries |
| `src/bah.ts` | Bah's system prompt (built from `knowledge/`), OpenAI-compatible client |
| `src/ratelimit.ts` | in-memory sliding-window limiter |
| `src/routes/*.ts` | `bah`, `feedback`, `mods` (public + admin) |
| `src/mcp.ts` | MCP tools and the `/mcp` endpoint |
| `knowledge/` | copies of `docs/GAMEPLAY.md` and the tablet FAQ, baked into the image |
| `infra/city-invaders.yml` | compose extension for the VGData server |
| `infra/vhost.d/…` | nginx-proxy per-host settings (upload size) |
| `test/routes.test.ts` | route tests (`node:test`, fake LLM, temp data dir) |

Design notes:

- **SQLite** in one file on the data volume (`better-sqlite3`, WAL). Tables: `sessions`,
  `conversations`, `messages` (with per-reply token usage), `feedback`, `feedback_notes`, `mods`.
- **Rate limits** are in memory (lost on restart; that is fine for one container).
- **Bah's prompt** = role/safety rules + the full `GAMEPLAY.md` + the FAQ, sent with a prompt-cache
  breakpoint so repeated calls read it from the cache. The game state the client sends is wrapped in
  a `<game_state>` block in the user turn; only the raw player message is stored as the message text.
- **Conversations**: a reply returns `conversation_id`. Send it back to continue that conversation;
  without it the server continues the session's latest conversation if it was active in the last
  6 hours, otherwise it starts a new one. The last `BAH_HISTORY_TURNS` exchanges are sent as history.
- **MCP** runs in stateless Streamable HTTP mode with JSON responses (no SSE, no session id):
  every POST builds a fresh server, which suits a reverse proxy and a single container.

## Refreshing Bah's knowledge

The image is self-contained: `knowledge/GAMEPLAY.md` and `knowledge/bah_faq.json` are copies of
`docs/GAMEPLAY.md` and `godot/assets/rio_grande_do_sul/gadgets/tablet/bah_faq.json`. After the docs
change, refresh the copies (from the repository root) and redeploy:

```bash
cp docs/GAMEPLAY.md server/knowledge/GAMEPLAY.md
cp godot/assets/rio_grande_do_sul/gadgets/tablet/bah_faq.json server/knowledge/bah_faq.json
```

`BAH_GAMEPLAY_PATH` / `BAH_FAQ_PATH` can point elsewhere (e.g. a bind-mounted file) without a rebuild;
the prompt is built at start-up, so restart the container after changing them.

## API

Base URL in production: `https://api.cityinvaders.vgdata.net`.

### Auth

| Routes | Header |
|---|---|
| `GET /healthz` | none |
| `/api/*` except `/api/admin/*` | `X-Game-Key: <GAME_CLIENT_KEY>` (the admin bearer is accepted too) |
| `/api/admin/*`, `/mcp` | `Authorization: Bearer <ADMIN_TOKEN>` |

`GAME_CLIENT_KEY` ships inside the game, so it is not a secret: it only keeps scanners out.

### Errors

Every error is JSON `{"error": "<code>", "message": "<text>"}`:

| HTTP | `error` | When |
|---|---|---|
| 400 | `invalid_request` | validation failed (message names the field), bad JSON, missing file part |
| 400 | `invalid_screenshot` | screenshot is not base64 or not a PNG |
| 401 | `unauthorized` | missing/wrong `X-Game-Key` or bearer token |
| 404 | `not_found` | unknown id, unpublished mod, unknown route |
| 413 | `payload_too_large` / `screenshot_too_large` / `file_too_large` | size limits |
| 415 | `not_a_zip` / `unsupported_media_type` | mod is not a zip; wrong content type |
| 429 | `rate_limited` | rate limit hit; `Retry-After` header in seconds |
| 502 | `bah_upstream_error` | the language model call failed (retry later) |
| 503 | `bah_unavailable` | no `LLM_API_KEY` configured |
| 503 | `daily_budget_exhausted` | the daily token budget is used up (`Retry-After: 3600`) |
| 500 | `internal_error` | bug; see the container log |

### `POST /api/bah/chat`

```http
POST /api/bah/chat
X-Game-Key: <key>
Content-Type: application/json

{
  "session_id": "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f",
  "message": "Como acho as torres?",
  "lang": "pt-BR",
  "conversation_id": "optional uuid from a previous reply",
  "context": { "map": "gasometro", "phase": 1, "difficulty": "normal", "health": 40,
               "weapon": "pistol", "parts": 3, "has_glasses": false }
}
```

```json
200 { "reply": "Bah! Elas ficam em telhados altos...", "conversation_id": "9b2e...uuid" }
```

- `session_id`: a UUID the game generates once per install and keeps.
- `message`: 1-500 characters (`BAH_MESSAGE_MAX_CHARS`).
- `lang`: optional language tag; Bah answers in the language of the message, falling back to `lang`,
  then Brazilian Portuguese.
- `context`: optional flat-ish object, at most 2000 bytes of JSON, keys up to 40 chars.
- Limits: `CHAT_LIMIT_PER_SESSION` and `CHAT_LIMIT_PER_IP` messages per `CHAT_LIMIT_WINDOW_SEC`
  (default 20 / 10 min each), plus the daily token budget.

### `POST /api/feedback`

```http
POST /api/feedback
X-Game-Key: <key>
Content-Type: application/json

{
  "session_id": "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f",
  "kind": "bug",
  "text": "Fell through the floor next to the Gasômetro chimney",
  "map": "gasometro",
  "position": { "x": 12.5, "y": 0.0, "z": -40.2 },
  "game_version": "0.9.0",
  "os": "Windows 11 (10.0.22631)",
  "screenshot_png_base64": "iVBORw0KGgo..."
}
```

```json
201 { "id": 42 }
```

- `kind`: `bug` | `idea` | `other`; `text` 1-4000 chars; `map` ≤ 64; `game_version` ≤ 32; `os` ≤ 64.
- `position`: `{x,y,z}` numbers or an array of 2-4 numbers.
- `screenshot_png_base64`: optional, PNG only, ≤ 3 MB decoded (a `data:image/png;base64,` prefix is
  accepted). Stored as `/data/screenshots/feedback-<id>.png`.
- Limit: `FEEDBACK_LIMIT_PER_IP` per `FEEDBACK_LIMIT_WINDOW_SEC` (default 10 / hour).
- Status workflow (admin/MCP): `new` → `triaged` → `done` | `wontfix`; each change can carry a note
  (kept as history in `feedback_notes`).

### `POST /api/mods` (multipart/form-data)

Fields: `name` (≤ 80), `author` (≤ 60), `description` (≤ 2000, optional), `version` (≤ 32),
`game_version` (≤ 32), `session_id` (uuid), and one file part named `file` (`*.zip`, ≤ 25 MB, must
start with the zip signature).

```bash
curl -H "X-Game-Key: $KEY" \
  -F name="Lajeado Night" -F author="Tchê" -F description="Night sky" \
  -F version=1.0 -F game_version=0.9.0 -F session_id=3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f \
  -F file=@night.zip https://api.cityinvaders.vgdata.net/api/mods
```

```json
201 { "id": 7, "status": "pending", "sha256": "e3b0c4..." }
```

New mods are `pending` until an admin sets them `published` (or `rejected`). Limit:
`MOD_UPLOAD_LIMIT_PER_IP` per `MOD_UPLOAD_LIMIT_WINDOW_SEC` (default 5 / hour).

### `GET /api/mods`, `GET /api/mods/:id`, `GET /api/mods/:id/download`

Only `published` mods are visible (others answer 404).

```json
GET /api/mods?limit=100
200 { "items": [ { "id": 7, "name": "Lajeado Night", "author": "Tchê", "description": "Night sky",
                   "version": "1.0", "game_version": "0.9.0", "size_bytes": 182734,
                   "sha256": "e3b0c4...", "downloads": 12,
                   "created_at": "2026-10-18T09:00:00.000Z", "updated_at": "2026-10-18T10:00:00.000Z" } ] }
```

`GET /api/mods/:id` returns one such object. `/download` streams the zip
(`Content-Type: application/zip`, `Content-Disposition: attachment`, `X-Sha256: <hex>`) and counts
the download. The game should verify the sha256 before installing.

### Admin REST (Bearer `ADMIN_TOKEN`)

| Method | Path | Body / query |
|---|---|---|
| GET | `/api/admin/feedback` | `?status=&kind=&limit=` |
| GET | `/api/admin/feedback/:id` | report + notes |
| GET | `/api/admin/feedback/:id/screenshot` | PNG |
| PATCH | `/api/admin/feedback/:id` | `{"status":"triaged","note":"..."}` |
| GET | `/api/admin/mods` | `?status=&limit=` (all statuses) |
| PATCH | `/api/admin/mods/:id` | `{"status":"published"}` |

### `GET /healthz`

`200 {"ok": true, "bah": true}` (`bah` is false when no `LLM_API_KEY` is set).

### MCP: `POST /mcp`

Streamable HTTP, stateless, JSON responses, `Authorization: Bearer <ADMIN_TOKEN>`. Tools:

| Tool | Arguments |
|---|---|
| `list_feedback` | `status?`, `kind?`, `limit` (default 50) |
| `get_feedback` | `id` (screenshot attached as image content) |
| `update_feedback` | `id`, `status`, `note?` |
| `list_mods` | `status?`, `limit` |
| `get_mod` | `id` |
| `set_mod_status` | `id`, `status` (`pending` / `published` / `rejected`) |
| `list_conversations` | `limit`, `since?` (ISO date) |
| `get_conversation` | `id` |
| `stats` | none: counts, tokens used today vs. the budget |

Connect Claude Code:

```bash
claude mcp add --transport http city-invaders https://api.cityinvaders.vgdata.net/mcp \
  --header "Authorization: Bearer <ADMIN_TOKEN>"
```

(Add `--scope user` to have it in every project. Locally: `http://localhost:8080/mcp`.)

## Environment variables

See `.env.example` for the full annotated list.

| Variable | Default | Purpose |
|---|---|---|
| `GAME_CLIENT_KEY` | (required) | value of the `X-Game-Key` header the game sends |
| `ADMIN_TOKEN` | (required, ≥ 24 chars) | admin REST + MCP bearer token |
| `LLM_BASE_URL` | `https://openrouter.ai/api/v1` | OpenAI-compatible chat endpoint |
| `LLM_API_KEY` | empty | its API key; empty disables chat (503) |
| `BAH_MODEL` | `openai/gpt-4o-mini` | model (OpenRouter slug `provider/model`) |
| `BAH_MAX_OUTPUT_TOKENS` | 400 | max tokens per reply |
| `BAH_HISTORY_TURNS` | 12 | exchanges of history sent to the model |
| `BAH_MESSAGE_MAX_CHARS` | 500 | max player message length |
| `BAH_DAILY_TOKEN_BUDGET` | 2000000 | per UTC day, all players; 0 = unlimited |
| `BAH_GAMEPLAY_PATH`, `BAH_FAQ_PATH` | `knowledge/…` | knowledge files |
| `CHAT_LIMIT_PER_SESSION`, `CHAT_LIMIT_PER_IP`, `CHAT_LIMIT_WINDOW_SEC` | 20, 20, 600 | chat limits |
| `FEEDBACK_LIMIT_PER_IP`, `FEEDBACK_LIMIT_WINDOW_SEC` | 10, 3600 | feedback limit |
| `MOD_UPLOAD_LIMIT_PER_IP`, `MOD_UPLOAD_LIMIT_WINDOW_SEC` | 5, 3600 | upload limit |
| `FEEDBACK_SCREENSHOT_MAX_BYTES` | 3145728 | decoded PNG size |
| `MOD_MAX_BYTES` | 26214400 | zip size |
| `PORT`, `HOST` | 8080, 0.0.0.0 | listen address |
| `TRUST_PROXY_HOPS` | 1 | proxies trusted for `X-Forwarded-For` |
| `DATA_DIR`, `DB_PATH` | `./data`, `$DATA_DIR/city-invaders.db` | storage |
| `LOG_LEVEL` | info | pino log level |

## Running locally

```bash
cd server
cp .env.example .env        # set GAME_CLIENT_KEY, ADMIN_TOKEN (openssl rand -hex 32), LLM_API_KEY
npm install                 # behind a TLS-inspecting proxy: NODE_EXTRA_CA_CERTS=<CA bundle> npm install
npm run build
node --env-file=.env dist/src/index.js     # or: npm run dev (rebuilds and restarts on change)
npm test                    # builds, then runs node:test with a fake LLM
```

```bash
curl -s localhost:8080/healthz
curl -s -H "X-Game-Key: $GAME_CLIENT_KEY" -H 'content-type: application/json' \
  -d '{"session_id":"3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f","message":"Como me curo?"}' \
  localhost:8080/api/bah/chat
```

With Docker: `docker build -t city-invaders-api .` then
`docker run --env-file .env -p 8080:8080 -v ci-data:/data city-invaders-api`.

## Deploying on VGData

Follow `vgdata-infra/SERVER.md` and `vgdata-infra/runbooks/new-project.md`. Run `vgdata-status`
first. The compose project on the server is the shared `nginx-proxy`: always name the service,
never `down`, never `--remove-orphans`, never prune.

1. **DNS**: A record `api.cityinvaders.vgdata.net` → `167.86.67.205` (or CNAME to
   `contabo1.vgdata.net`).
2. **Code**: from the repository root on the Mac,
   `rsync -az --delete --exclude node_modules --exclude dist --exclude data --exclude '.env*' --exclude '*.pem' server/ root@167.86.67.205:/srv/city-invaders/`
3. **Env file**: create `/srv/city-invaders/.env` from `.env.example` with real values,
   `chmod 600` (scp it; never commit it). Generate `ADMIN_TOKEN` with `openssl rand -hex 32`.
4. **Compose + vhost**:
   `scp server/infra/city-invaders.yml root@167.86.67.205:/srv/docker/nginx-proxy/city-invaders.yml` and
   `scp server/infra/vhost.d/api.cityinvaders.vgdata.net root@167.86.67.205:/srv/docker/nginx-proxy/vhost.d/`
   (raises nginx's body limit to 30 MB for mod uploads; without it uploads over 1 MB fail with 413
   from nginx).
5. **Build and start** (on the server):
   ```bash
   cd /srv/docker/nginx-proxy
   docker compose -f docker-compose.yml -f city-invaders.yml build city-invaders-api
   docker compose -f docker-compose.yml -f city-invaders.yml up -d city-invaders-api
   ```
   The "orphan containers" warning is expected: ignore it.
6. **Smoke test**: `curl -fsS https://api.cityinvaders.vgdata.net/healthz` (wait for the certificate),
   then one chat call with the game key, then the MCP tools from Claude (`stats`).
7. **Record it** in `vgdata-infra`: a row in `SERVER.md` section 2 (project City Invaders, container
   `city-invaders-api`, host, compose `nginx-proxy/city-invaders.yml` + `/srv/city-invaders`, source
   `City_Invaders/server/infra/city-invaders.yml`), an entry in `CHANGELOG.md`, then `scripts/publish.sh`.
8. Check with `vgdata-status`: container healthy, memory limit set, certificate issued.

**Updates**: repeat steps 2, 5 and 6 (and 4 if the yml or vhost changed). The data lives in the
volume `nginx-proxy_city_invaders_data` and survives rebuilds.

**Backups**: the volume holds everything (SQLite + files). A consistent copy of the DB:
`docker exec city-invaders-api node -e "require('better-sqlite3')('/data/city-invaders.db').backup('/data/backup.db')"`.

## LFS storage (lfs.cityinvaders.vgdata.net)

The game's big files (models, textures, sounds) are stored with Git LFS on the
project's own server, not on GitHub: a small Forgejo (`infra/city-invaders-lfs.yml`,
deployed with `deploy-city-invaders-lfs.sh`) holds the repository `vilson/city-invaders`
for LFS only. Anyone can download (no sign-in); uploading needs an access token from
the owner. Registration is closed; new contributors with upload rights are added by hand
(`docker exec -u git city-invaders-lfs forgejo admin user create ...`).
