# OneDrive MCP (repo home)

A zero-dependency (Python stdlib only) Microsoft Graph client exposed as an
MCP server over stdio, plus a device-code login, a raw Graph CLI, and
self-contained tests. Lives in the NixOS repo so the wiring
(`hermes/mcp/onedrive.nix`, owned by the nixos card) points at a versioned,
rebuild-proof location instead of loose scripts in `~/.hermes/bin/`.

## Files

| File | Purpose |
|---|---|
| `mcp_server.py` | MCP server (NDJSON JSON-RPC 2.0 over stdio). Tools: `onedrive_status`, `onedrive_list`, `onedrive_read`, `onedrive_write`, `onedrive_search`, `onedrive_delete`. Includes the **self-login** flow (see below). |
| `login.py` | One-time device-code login, run by hand. Client id from `ONEDRIVE_CLIENT_ID` env (preferred) or argv; token path from `ONEDRIVE_TOKEN` env or default. Writes the token file 0600 under the token-refresh lock. |
| `api_cli.py` | Raw Graph REST passthrough CLI + silent refresh. `api_cli.py token` forces a refresh; `api_cli.py METHOD /path [json-body]` proxies a single request. |
| `lock_test.py` + `lock_child.py` | Hermetic concurrency test for the token-refresh `fcntl.flock` guard (fake local Microsoft endpoint; no real calls). Guard-ON arm + guard-OFF sensitivity control. |
| `test_harness.py` | Stdio harness driving `mcp_server.py` like a real MCP client: full live acceptance (write/read exact-echo, binary round-trip, search, delete, out-of-scope `itemNotFound` negative test) plus the self-login section (device-code URL+code returned immediately; second call reports "login in progress"; no real login completed). |

## Environment

| Var | Meaning | Default |
|---|---|---|
| `ONEDRIVE_CLIENT_ID` | Microsoft app **client id** (an identifier, not a secret — but it still lives in the agenix-encrypted `~/.hermes/.env`, never in code). Required only for the self-login / `login.py`; normal operation uses the stored token's own `client_id`. | *(unset)* |
| `ONEDRIVE_TOKEN` | Token file path (multi-account support). The lock sidecar is `TOKEN_PATH + ".lock"`, so per-token-path locks never contend across accounts. | `~/.hermes/onedrive_token.json` |

The `.env` is rendered by the agenix `hermes-karl.age` secret at activation;
Hermes loads it into the gateway and its MCP children's environment, so
`ONEDRIVE_CLIENT_ID` is present in the server's env at runtime.

## Security model

- **Scopes**: `Files.Read Files.ReadWrite.AppFolder offline_access openid profile`
  (device-code / public-client flow, **no client secret**).
- **Reads/searches** cover the whole drive (`Files.Read`).
- **Writes are API-enforced to the app folder** (`Files.ReadWrite.AppFolder`):
  a PUT/DELETE outside the app folder is rejected by Microsoft itself
  (`itemNotFound`) — the server never needs (and has no) code-level path
  filtering. The harness asserts this every run (section 9).
- **Token file**: `0600`, atomic write under an advisory `fcntl.flock`
  (`_TokenLock`, LOCK_NB, ~3×1 s retry, fall-through-without-lock) so
  concurrent profiles/processes can't clobber or observe a partial file, and
  no process ever deadlocks the request queue.
- **Retries**: transient 401/429 and network errors only; deterministic 4xx
  (400, 404 itemNotFound, 403) are never retried. `NET_TIMEOUT` (30 s) is
  applied to every `urlopen`.

## Self-login (the frictionless connect)

When any tool is called and **no usable token exists** (no token file, or the
silent refresh failed — e.g. a revoked refresh token):

1. `mcp_server.py` checks `ONEDRIVE_CLIENT_ID` is present; if not, it returns
   a clear setup error (set it in the agent's `.env`).
2. It POSTs Graph `/devicecode` (tenant `consumers`), spawns a **daemon
   background thread** that polls `/token` at Microsoft's `interval` until
   `expires_in`, and **returns immediately** with the verification URL, the
   user code, and the instruction "open the URL, sign in, enter the code;
   then just re-run this tool / ask again".
   (The call does **not** block on the poll: an MCP stdio call is
   synchronous, and the client can only show the user the link+code once the
   call returns.)
3. While the login is pending, further calls return "login in progress —
   enter the code at <url>" (`isError=true`; the drive is genuinely unusable
   until the code is entered, and the message says exactly what to do).
   A single process-level state machine (`_LOGIN_LOCK`) guarantees two
   concurrent calls start exactly ONE device-code flow; later calls report
   that pending one's URL+code.
4. When the daemon thread completes, it writes the token file under the
   `_TokenLock` (atomic, 0600), so the very next call just works. On
   expiry/failure the thread resets state and the next call offers a FRESH
   code. The daemon does HTTP + file writes only — the main thread
   exclusively owns stdin/stdout.

So "connect to OneDrive" is one agent action: ask → get link+code → user
enters code → done. No separate script run by hand (though `login.py`
remains for interactive/manual use).

## Adding another account

1. Register a second Azure app (public client, device-code capable), or reuse
   the same app.
2. `ONEDRIVE_CLIENT_ID=<id> ONEDRIVE_TOKEN=~/.hermes/onedrive_token_second.json python3 login.py`
   (or set both in the agent's `.env` for that profile and call any tool —
   the self-login flow starts automatically).
3. Every subsequent use (MCP or CLI) targets that account by exporting the
   same `ONEDRIVE_TOKEN`. Per-path lock sidecars mean accounts never contend.

## Re-auth procedure

Token refresh is automatic (silent refresh via `refresh_token`, 0600 file,
locked). Re-auth is only needed when the refresh token is revoked/expired or
scopes change:

- **Automatic**: any tool call detects the unusable token and starts the
  device-code flow itself (see above).
- **Manual**: `ONEDRIVE_TOKEN=<path> python3 login.py` — same device-code
  dance, foreground, with progress output.

## Graph endpoint quirks (verified 2026-09-17)

- PUT `/content` with **raw body bytes** stores the content verbatim
  (byte-exact). The `{"@content.bytes": ...}` JSON envelope is stored
  VERBATIM as the file content instead — writes must send raw bytes.
  `Content-Type: application/json` is required on writes (header check only).
- Item paths (`/.../folder/name`) are rejected on content/mutation calls for
  this app's token; the **children/ form** (`/.../folder/children/name`) is
  the only form that works for PUT/DELETE — `child_form()` applies it.
- GET `/content` on approot items 401s (SharePoint routing) even with a fresh
  token; reads fall back to the item's `@microsoft.graph.downloadUrl`
  (raw bytes, verified exact).
- `$search` is a NO-OP on this drive (returns children unfiltered); name
  search is done client-side against the listed children of the scope
  (default: the app folder).

## Tests

```sh
# full live acceptance + self-login (uses the real token; no real login is
# completed — the device-code flow is started and left unattended):
python3 test_harness.py
# concurrency guard (hermetic, no Microsoft calls):
python3 lock_test.py
```
