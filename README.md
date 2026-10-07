# Strafe points API

This service owns the live StrafeSMPCore point balances in Supabase. It runs independently from the Minecraft plugin and the web application. The HTTP listener uses port `5000` by default and reads `PORT` at startup.

The API keeps live balances in `point_balances`, display metadata in `point_profiles`, and match records in `point_matches`. The Minecraft plugin sends point changes and match settlements live through this API when configured. A team uses its team UUID as the subject ID; a player uses the Minecraft UUID. Point values and win/loss totals are integers from 0 through 2,147,483,647.

## HTTPS deployment on a VPS (recommended)

The running API calls Supabase's HTTPS Data API through the existing transactional,
scoped functions in `strafe_api`. It requires no PostgreSQL password, certificate file,
or direct database port. Node verifies HTTPS certificates through its normal trust store.
Plugin and website Strafe API keys and endpoints stay unchanged.

1. Use the automatic migration instructions below, or run `pnpm migrate:prod --sql` in this repository. It generates `migrations-prod.sql`
   without connecting to a database or reading administrator credentials. Paste/run the
   complete generated file in Supabase SQL Editor as `postgres`. It applies pending SQL
   under one transaction and the same migration advisory lock; existing checksums, missing
   files and out-of-order migrations are checked. Retain applied migration files unchanged.
   This command generates SQL only; it does not apply migrations until you run the file.
2. In Supabase Data API settings, append `strafe_api` to **Exposed schemas**, preserving
   existing schemas. The new migration grants `service_role` only the API entry points;
   it adds no anonymous/authenticated access or table permissions. Leave helper functions
   and private tables unexposed to those roles. Ensure the Data API is enabled.
3. Create a server secret in Supabase Settings → API Keys. Put `SUPABASE_URL` and
   `SUPABASE_SECRET_KEY=sb_secret_...` in the API `.env`. Keep this elevated secret only
   in the API server; it must never reach Minecraft, Velocity, the website or browsers.
   Supabase secret keys use `service_role` and can access other project resources granted
   to that role; use a dedicated Supabase project for Strafe where practical.
4. Keep the existing Discord, ports, limiter and proxy settings. `HOST=0.0.0.0` inside
   Docker; publish `127.0.0.1:5000:5000`. In HTTPS mode omit `DATABASE_URL`,
   `DATABASE_SSL_CA_PATH` and `DATABASE_POOL_MAX` from the runtime `.env`.
5. Build `docker build -t strafemc-api:latest .` and run:

```sh
docker run -d --name strafemc-api --restart unless-stopped \
  --env-file .env -e HOST=0.0.0.0 \
  --publish 127.0.0.1:5000:5000 \
  --mount type=volume,source=strafe-account-portraits,target=/data/account-portraits \
  strafemc-api:latest
```

HTTPS RPC calls have a 10-second timeout and bounded response size, use fixed function
names, reject redirects, and do not automatically retry writes. Database idempotency and
plugin outbox retries remain responsible for safely repeating mutations. `/readyz` calls
Supabase's readiness function, while `/healthz` remains a local liveness check.

References: [custom schemas](https://supabase.com/docs/guides/api/using-custom-schemas)
and [server API keys](https://supabase.com/docs/guides/getting-started/api-keys).

## Automatically apply migrations over HTTPS

`pnpm migrate:prod` now loads the API `.env` and applies pending migrations through
Supabase's Management API. It needs no database password or certificate file. It uses
our existing SQL migration files and `strafe_migrations` checksums, including migrations
previously applied through the generated SQL Editor bundle. No Prisma schema or second
migration history is introduced.

Create a Supabase personal access token scoped to this project with Database Write
permission. This deployment-only `SUPABASE_ACCESS_TOKEN` is different from the runtime
`SUPABASE_SECRET_KEY`. Keep it out of the runtime `.env` passed to Docker; provide it
only to the migration command. The project reference is inferred from `SUPABASE_URL`
in `.env`; set `SUPABASE_PROJECT_REF` only for a custom Supabase domain.

On the VPS in Bash:

```sh
read -rs -p "Supabase migration access token: " SUPABASE_ACCESS_TOKEN
printf '\n'
export SUPABASE_ACCESS_TOKEN
pnpm migrate:prod
unset SUPABASE_ACCESS_TOKEN
```

The migration command applies the bundle in a transaction with an advisory lock and
then verifies every recorded checksum. No destructive schema diff, reset or automatic
retry is performed. If the HTTPS request times out, rerun the same command: migration
history ensures completed migrations are skipped. Do not edit applied migrations.
The Management API query endpoint is currently documented as beta; the `--sql` export
remains available if that service is unavailable. See [query API](https://supabase.com/docs/reference/api/v1-run-a-query)
and [personal access tokens](https://supabase.com/docs/guides/platform/personal-access-tokens).

For Docker, build the existing `migrator` target and run it without a CA mount:

```sh
docker build --target migrator -t strafemc-api-migrator:latest .
# Supply SUPABASE_ACCESS_TOKEN temporarily as above.
docker run --rm --env-file .env -e SUPABASE_ACCESS_TOKEN \
  strafemc-api-migrator:latest
unset SUPABASE_ACCESS_TOKEN
```

## Direct PostgreSQL deployment (optional)

Requirements: Node.js 22.9 or newer and pnpm 10. The `start:prod` script uses Node's optional environment file loader.

1. Apply pending migrations with `pnpm migrate:postgres` as the Supabase database administrator (`postgres`). Provide `MIGRATIONS_DATABASE_URL` for this command through the deployment secret manager or a protected `.env.migrate` file. It is intentionally separate from `DATABASE_URL`, which is the restricted API runtime login. Set `DATABASE_SSL_CA_PATH` to the Supabase database root certificate for verified TLS. The command serializes concurrent runs, tracks applied migrations and checksums in the private `strafe_migrations` schema, and rejects changed or missing applied migration files. Run it in a controlled deployment step and do not put the administrator URL in the API server's permanent environment. The second migration creates the restricted `strafe_points_runtime` permission role and a disabled `strafe_points_api` login.
2. In the Supabase SQL Editor, run `select public.issue_points_database_password();` as `postgres`. The function enables `strafe_points_api`, sets a randomly generated password, and returns it once. Each call rotates the password, so save the result directly to the API server's secret manager before calling it again. To disable database login during an incident, run `alter role strafe_points_api nologin;`.
3. Copy `.env.example` to `.env` for local deployment. In the Supabase Dashboard's **Connect** panel, choose Direct Connection for an IPv6-capable persistent host, or Session Pooler for an IPv4-only host. Use `strafe_points_api` as the direct connection username; for the shared session pooler use `strafe_points_api.<project-ref>`. Keep the dashboard's host and port, set the issued password in `DATABASE_URL`, download the Supabase database root certificate, and set its file path in `DATABASE_SSL_CA_PATH`. Leave SSL query parameters out of `DATABASE_URL`; the API verifies the certificate and server name itself. The pooler username format and reachable connection methods depend on the selected Supabase connection mode. [Supabase connection documentation](https://supabase.com/docs/guides/database/connecting-to-postgres) describes the modes and username formats.
4. Set `point_settings.starting_points` to match the plugin's `competitive.starting-points` setting before the first season begins. The database default is 1000. Set `PORT` if the deployment needs a different port.
5. Install and build with `pnpm install --frozen-lockfile` and `pnpm build:prod`.
6. Run `pnpm start:prod`. The start script loads `.env` when present; environment variables supplied by the process manager take precedence. Production deployments can provide secrets directly through their secret manager and omit the file.

`GET /healthz` is a liveness check. `GET /readyz` checks that PostgreSQL is reachable. The API listener speaks plain HTTP and binds to `127.0.0.1` by default. Keep port 5000 private behind a TLS-terminating reverse proxy or load balancer; do not expose the raw listener publicly. If the API runs in a container, bind to `0.0.0.0` inside its private network and restrict ingress to the proxy. Plugin and webapp clients must use HTTPS for non-local API base URLs.

### Docker deployment

Build this image from the API Server directory. The runtime image contains only the compiled API and production dependencies, runs as the unprivileged `node` user, and includes a `/healthz` container health check.

```sh
docker build -t strafemc-api:latest .
docker run -d \
  --name strafemc-api \
  --restart unless-stopped \
  --env-file .env \
  -e HOST=0.0.0.0 \
  --publish 127.0.0.1:5000:5000 \
  --mount type=bind,source=/etc/strafe/supabase-root.crt,target=/run/secrets/supabase-prod-root.crt,readonly \
  --mount type=volume,source=strafe-account-portraits,target=/data/account-portraits \
  strafemc-api:latest
```

Set `DATABASE_SSL_CA_PATH=/run/secrets/supabase-prod-root.crt` in `.env`. The example `.env` binds to loopback for a host process, so the Docker command explicitly sets `HOST=0.0.0.0` inside the container. The published port remains on host loopback for a TLS reverse proxy. Do not add `MIGRATIONS_DATABASE_URL` to this runtime environment.

For an optional direct PostgreSQL migration container, build the separate target and run it with the protected administrator environment file and CA certificate:

```sh
docker build --target migrator -t strafemc-api-migrator:latest .
docker run --rm \
  --env-file .env.migrate \
  --mount type=bind,source=/etc/strafe/supabase-root.crt,target=/run/secrets/supabase-prod-root.crt,readonly \
  strafemc-api-migrator:latest node scripts/migrate-prod.mjs --postgres
```

Keep `.env.migrate` out of the long-running API container and source control. The migrator target contains the SQL migration files and PostgreSQL client but does not start the HTTP service.

The API rate limits by source IP and API key and caps concurrent in-flight requests with `MAX_IN_FLIGHT_REQUESTS` (default 200). Other limits are controlled by `RATE_LIMIT_WINDOW_MS`, `RATE_LIMIT_MAX_PER_IP`, `RATE_LIMIT_MAX_PER_KEY`, and `DATABASE_POOL_MAX`. `DATABASE_POOL_MAX` is per API process; budget the sum across all replicas under your Supabase connection limit. The limiter is process-local, so deployments with multiple API replicas should also apply a shared limit at the load balancer or gateway. The service does not trust proxy headers by default. Set `TRUST_PROXY=true` only when the front proxy strips client-supplied `X-Forwarded-For` and writes its own value. Busy requests receive `503 server_busy` with `Retry-After: 1`; retry writes using their original idempotency key.

The service is intended for server-to-server use. It sends no CORS allow-origin headers. The web application should fetch leaderboard data during SSR with its own read-only API key; the key must never reach browser JavaScript or HTML.

## API key administration

Use the authenticated Supabase dashboard as the admin console. This avoids adding a second login system, password reset flow, session cookie, CSRF surface, and custom permission UI to a service whose keys already live in Supabase. Restrict Supabase organization and database access to trusted administrators and enable MFA on those accounts.

To issue a key, run this once in the Supabase SQL Editor as an administrator:

```sql
select *
from public.issue_api_key(
  'minecraft-plugin',
  array['points:read', 'points:write']::text[]
);
```

The result contains the raw key once, its identifying prefix, and its row ID. Copy the key directly to the server-side Minecraft plugin configuration. The database stores only its SHA-256 hash, so the raw key cannot be recovered later. Do not save the SQL result in a shared query or document. Issue the SSR webapp a separate, leaderboard-only key:

```sql
select *
from public.issue_api_key('webapp-ssr', array['leaderboards:read']::text[]);
```

Issue a separate SMP moderation key for tier bans:

```sql
select *
from public.issue_api_key('smp-tier-moderation', array['tiers:moderate']::text[]);
```

In Supabase Table Editor, the `api_keys` table shows the label, prefix, hash, scopes, creation time, expiry, and revocation time. Change `scopes` there to manage permissions. Revoke a key by setting `revoked_at` to the current time or delete its row. The API checks the table on every request, so changes take effect without waiting for a cache to expire. `key_prefix` is only an identifier and cannot authenticate a request.

The helper `pnpm api-key:generate -- --label minecraft-plugin --scopes points:read,points:write` can generate a key and hash locally for manual Table Editor entry. It prints the raw key once and does not write it to a file.

## Authentication and errors

Send API keys in the `Authorization: Bearer <key>` header. Keys have the `ssmp_live_` prefix and are generated with 256 bits of random data. Supported scopes are `leaderboards:read`, `points:read`, `points:write`, `accounts:read`, `accounts:write`, `accounts:admin`, and `tiers:moderate`. Use separate keys for leaderboard reads, Velocity account operations, SMP account status reads, staff recovery, and SMP tier moderation. Velocity needs both `accounts:read` and `accounts:write`; the website's server-side leaderboard key needs only `leaderboards:read` for leaderboards and the public skin appearance lookup. Never expose an API key to browser JavaScript or HTML. A write-only points key can mutate points, but mutation responses omit balance rows unless the same key also has `points:read`.

Errors use this shape:

```json
{"error":{"code":"invalid_request","message":"...","requestId":"..."}}
```

The server returns `401` for a missing, unknown, expired, or revoked key; `403` for a missing scope; `409 idempotency_conflict` when a UUID is reused with a different request, `subject_deleted` when a later write targets a tombstoned subject, or `season_mismatch` when a new match began before the active season; `429` with `Retry-After` when rate limited; and `503` for an unavailable database or a saturated request limit. Error bodies and logs never include API key material or database response text.

All mutation requests that can change balances require an `Idempotency-Key` UUID. The key is global across API credentials and remains unique in `point_mutations`. Replaying the same key and normalized request returns the first successful result with `duplicate: true`. Reusing it for different content returns `409`. Every successful mutation response includes the event's `eventSeason` and active `currentSeason` IDs, including write-only responses. The plugin should persist the complete request and UUID in its local outbox before sending, retry network errors, `429`, and `5xx` with backoff, and remove the entry only after a `2xx` response. Keep a `season_mismatch` match in the outbox for audited operator resolution; retries of matches already recorded before rollover continue to return their stored response.

## Routes

| Method and path | Scope | Purpose |
| --- | --- | --- |
| `GET /v1/points/:subjectType/:subjectId` | `points:read` | Read one team or player balance and profile. |
| `GET /v1/points/snapshot?subjectType=team\|player&limit=500&after=<uuid>` | `points:read` | Page through existing balance rows in UUID order. |
| `GET /v1/leaderboards/smp-teams?limit=50&offset=0` | `leaderboards:read` | Team leaderboard. |
| `GET /v1/leaderboards/smp-solo?limit=50&offset=0` | `leaderboards:read` | Solo player leaderboard. |
| `GET /v1/leaderboards/seasons` | `leaderboards:read` | Current and completed SMP seasons for the season selector. |
| `GET /v1/leaderboards/smp-teams?season=season-1` | `leaderboards:read` | Team leaderboard for a selected season. Omit `season` to use the current season. |
| `GET /v1/leaderboards/smp-solo?season=season-1` | `leaderboards:read` | Solo leaderboard for a selected season. Omit `season` to use the current season. |
| `GET /v1/leaderboards/pvp?limit=50&offset=0` | `leaderboards:read` | Returns an empty list until a PVP point source is configured. |
| `POST /v1/points/adjust` | `points:write` | Add or subtract points for one subject. |
| `POST /v1/points/set` | `points:write` | Set one subject's points. |
| `POST /v1/points/bulk` | `points:write` | Adjust or set all existing balances for one subject type in one transaction. |
| `POST /v1/points/delete` | `points:write` | Remove one subject's balance/profile and add a permanent tombstone. |
| `POST /v1/matches/settle` | `points:write` | Atomically settle both sides and record a match. |
| `POST /v1/points/snapshot` | `points:write` | Insert initial balances without overwriting rows already owned by the API. |
| `POST /v1/points/profiles` | `points:write` | Idempotently sync public display metadata. |
| `POST /v1/accounts/session` | `accounts:write` | Register or heartbeat a trusted Velocity session. |
| `POST /v1/accounts/session/end` | `accounts:write` | End only the matching session nonce. |
| `GET /v1/accounts/:playerId` | `accounts:read` | Read link, premium, authenticated presence, and canonical skin state. |
| `POST /v1/accounts/link` | `accounts:write` | Start Discord link or controlled link change from the current session. |
| `GET /v1/accounts/link/:requestId` | `accounts:write` plus session headers | Poll an account link request for the same player session. |
| `POST /v1/accounts/link/:requestId/confirm` | `accounts:write` | Confirm Discord proof from the active Minecraft session. |
| `GET /v1/accounts/skins?ids=<uuid,...>` | `accounts:read` or `leaderboards:read` | Return public skin appearance URLs for up to 100 UUIDs. |
| `POST /v1/accounts/skin/prepare` | `accounts:write` | Reserve a five-minute skin change before proxy-side resolution. |
| `POST /v1/accounts/skin/commit` | `accounts:write` | Persist a canonical signed texture returned by the trusted resolver. |
| `POST /v1/accounts/skin/cancel` | `accounts:write` | Cancel a failed or abandoned skin resolution. |
| `GET /v1/accounts/portraits/:hash/:model.png` | Public, registered skin only | Fetch and cache a bounded transparent front-body PNG portrait. |
| `POST /v1/accounts/admin/recover` | `accounts:admin` | Audited staff recovery of a Discord link. |
| `GET /v1/tiers/players?name=<minecraft-name>` | `tiers:moderate` | Resolve an exact case-insensitive stored Minecraft name to UUID; returns 404 when unknown or 409 with matches when ambiguous. |
| `GET /v1/tiers/status?ids=<uuid,...>` | `accounts:read` | Return effective tier-ban booleans for 1–100 UUIDs without account or Discord data. |
| `POST /v1/tiers/ban` | `tiers:moderate` | Persist a UUID ban and, for a linked non-premium account, capture its Discord identity as an alternate-account blocker. |
| `POST /v1/tiers/unban` | `tiers:moderate` | Revoke only the target UUID ban and its captured Discord blocker. |

### Account identity and skins

The new account migration adds only private tables and fixed database functions; it grants the API runtime no direct table access. Applied migrations remain immutable and checksum-verified. Issue a Velocity key with `accounts:read,accounts:write`, an SMP account-read key with `accounts:read`, and a website SSR key with `leaderboards:read`. Keep `accounts:admin` on a separate staff-only key.

Configure `ACCOUNT_SESSION_TTL_SECONDS` from 90 to 600 (default 180). Velocity should POST the same random 32-byte hexadecimal `sessionToken` and original `sessionStartedAt` epoch milliseconds at connect and on its 60-second heartbeat. The response is the account status object used by the proxy cache. The API hashes the token, binds its ownership to the authenticated API key, and accepts a replacement nonce only when its connection start time is later, or when the previous nonce was explicitly ended. End requests affect only that exact nonce. Link confirmation and skin changes hold a database lock on the matching active session while they commit.

For key rotation, end each active player session with the old key before revoking it, then register the replacement session with its original, later `sessionStartedAt`. If the old proxy is unavailable, wait for the session TTL to expire before rotating; a different key cannot take over a live session. Pending link and skin operations are bound to the key that started them and should be restarted after rotation.

Discord OAuth is optional. To enable it, set `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET`, and `ACCOUNT_PUBLIC_URL` to the public HTTPS API origin (HTTP localhost is allowed for local development). Register `${ACCOUNT_PUBLIC_URL}/v1/accounts/oauth/callback` as the Discord application's redirect URI. If any required OAuth setting is absent, account session and skin APIs remain available and link-start requests return `account_oauth_disabled`. OAuth uses `identify`, a 10-minute single-use state bound to an HttpOnly SameSite cookie, and does not return Discord IDs in account read responses. A controlled link change requires proof of the old Discord, then the new Discord, then confirmation by the current Minecraft session. Staff recovery records the old/new Discord IDs, staff API-key row, reason, and timestamp in an audit table.

`POST /v1/accounts/session` accepts `{ "playerId", "playerName", "premium", "sessionToken", "sessionStartedAt" }`. Only the trusted Velocity proxy should call it; `premium` is the proxy's verified connection result. `GET /v1/accounts/:playerId` returns `{ "playerId", "playerName", "premium", "linked", "sessionAvailable", "sessionExpiresAt", "nextSkinChangeAt", "tiersBanned", "skin" }`; premium is `null` until the first trusted session and `tiersBanned` is always a boolean. `skin` contains `status`, model, the Mojang texture URL, resolver-signed texture value/signature for server use, portrait URL, and update time. The endpoint never returns a Discord identifier. `GET /v1/accounts/link/:requestId` also requires `X-Account-Player` and `X-Account-Session` headers, so session tokens never appear in URLs or request logs.

Skin changes use a reserve/resolve/commit flow. The proxy first calls `POST /v1/accounts/skin/prepare` with `{ "playerId", "sessionToken", "requestId", "input" }`, resolves the input with SkinsRestorer, then commits `{ "playerId", "sessionToken", "requestId", "textureValue", "textureSignature" }`. A reservation lasts five minutes. Explicit `/account skin` selections save immediately, with three new reservations per player per rolling 60 seconds; resolver failures count, idempotent retries do not. This limit is stored in the database and survives reconnects and restarts. Automatic mirroring uses the reserved input `skinsrestorer-current` and retains its rolling 24-hour cooldown and 10-second request throttle. Premium skins are managed through Minecraft Accounts; cracked skin selection does not require Discord linking. The API decodes the resolver value and accepts only an exact `textures.minecraft.net` texture path, with a 40–64 hexadecimal hash and `classic`/`slim` model. It stores the canonical URL and signed property. The supplied signature is trusted because only the authenticated proxy resolver writes it; the API does not independently validate Mojang's RSA signature.

Skin prepare/commit errors include stable codes. Cooldown and throttle responses use HTTP 429 with `Retry-After` and top-level `retryAfterSeconds`; cooldown also includes `nextSkinChangeAt`. The proxy should cache that deadline and avoid asking the player to retry before it.

The bulk skin endpoint returns only `{ "skins": { "<uuid>": { "model", "textureUrl", "portraitUrl" } } }` for accounts with a selected skin. The public PNG route accepts only hashes currently present in `account_skins`; it fetches from the fixed Mojang host with redirects disabled, an 8-second timeout, a 1 MiB response cap, and 64×64/64×32 image-dimension checks. It renders a transparent front-body portrait with `sharp`, coalesces in-flight generation, caches up to 10,000 files under `ACCOUNT_PORTRAIT_CACHE_DIR`, and prunes old entries. Mount that directory as persistent storage in production. Leaderboard requests do not fetch textures; clients receive a cached portrait URL.

The skin batch response also includes `premium` and `linked` booleans. `resolvePremium=false` skips resolving premium textures through Mojang and returns only those flags for premium accounts; cracked accounts still include their selected texture. The website uses this mode to render premium UUIDs and cracked texture hashes through SkinRender. Omitting the parameter preserves the existing premium texture lookup behavior for other consumers.

Staff can recover a link through the audited admin route using `pnpm account:recover -- --player-id <uuid> --discord-id <snowflake> --display-name <name> --reason <reason>`. Set `ACCOUNT_ADMIN_API_KEY` and `ACCOUNT_API_BASE_URL` in the operator's environment; the CLI sends the key only in the Authorization header and never writes it to disk.

Tier moderation uses a separate `tiers:moderate` key. Ban and unban requests accept `{ "playerId": "<uuid>", "actor": "<staff sender>" }` and return `{ "playerId", "playerName", "banned", "changed", "tiersBanned" }`; `banned` is this UUID's state and `tiersBanned` is the effective state after considering independent Discord blockers. Repeating an already-applied action does not add another audit row. UUID bans work even when the account has not connected to the API. At ban time, the API snapshots the linked Discord ID only when the canonical account is known and premium is false. The captured blocker remains attached to that UUID ban after unlink or recovery; unbanning that UUID removes only its blocker, leaving any other active ban snapshots intact. Ban audit rows retain the API-key row, sender, action, and private captured identity. Active bans remove solo rows before ranks, totals, search, or pagination are computed, including for historical seasons; unbanning makes the unchanged points/history visible again. Team rows remain visible because the API does not have membership metadata to identify which team contains a banned player. The account GET and session heartbeat responses include a `tiersBanned` boolean when the UUID itself is banned or its currently linked Discord matches an active captured blocker. The `GET /v1/tiers/status` endpoint uses an `accounts:read` key for one batched check of up to 100 UUIDs and returns only a `{ "bans": { "<uuid>": boolean } }` map. The SMP applies the same flag to duel and team-battle tier eligibility.

`GET /v1/leaderboards/seasons` returns the active season and every available season, newest first:

```json
{"currentSeason":"season-2","seasons":[{"id":"season-2","name":"Season 2","current":true,"completedAt":null},{"id":"season-1","name":"Season 1","current":false,"completedAt":"2026-10-03T00:00:00Z"}]}
```

The leaderboard response identifies the selected and active season and has one collection property, `items`:

```json
{
  "mode": "smp-teams",
  "season": "season-2",
  "seasonName": "Season 2",
  "currentSeason": "season-2",
  "limit": 50,
  "offset": 0,
  "total": 1,
  "nextOffset": null,
  "items": [
    {
      "subjectType": "team",
      "subjectId": "00000000-0000-4000-8000-000000000001",
      "displayName": "Example",
      "prefix": "EX",
      "memberCount": 3,
      "region": "AS",
      "points": 1000,
      "rank": 1,
      "wins": 0,
      "losses": 0
    }
  ]
}
```

Rows sort by points descending, then display name, then UUID. Equal point totals share a rank. Team `memberCount` is optional and nullable; solo rows return `null`. `nextOffset` is `null` when there are no more rows. The PVP route returns the same envelope with `total: 0` and `items: []`.

### Read and profile sync

`GET /v1/points/:subjectType/:subjectId` returns `{ "balance": { "subjectType", "subjectId", "displayName", "prefix", "memberCount", "points", "wins", "losses" } }`. An unseen subject reads as the configured `point_settings.starting_points` with zero wins and losses; no row is written by the read.

The GET snapshot route accepts up to 500 rows per page and returns `{ "subjectType", "currentSeason", "items": [...], "nextCursor" }`. `currentSeason` is the active season ID, read in the same database snapshot as the page. It includes existing balance rows only. Pin the season ID on the first page and discard/restart reconciliation if it changes between pages or subject types. Pass `nextCursor` as `after` until it is `null`.

`POST /v1/points/snapshot` accepts `{ "balances": [{ "subjectType", "subjectId", "points", "wins", "losses", "displayName", "prefix", "memberCount" }] }`, up to 500 rows. It inserts a balance only when that UUID has no API balance yet. It may update the supplied profile fields, and returns `{ "insertedCount", "existingCount", "deletedCount", "items" }` with current non-deleted API rows. Replaying an old snapshot never restores old points over a newer API balance or a tombstoned team.

`POST /v1/points/profiles` accepts `{ "profiles": [{ "subjectType", "subjectId", "displayName", "prefix", "memberCount", "region" }] }`, up to 500 rows. It upserts metadata without changing points. Names can be `null` or up to 255 characters; team prefixes can be `null` or empty; `memberCount` is a nullable integer from 0 to 1000 and is only valid for teams. Region is nullable and accepts `AS`, `EU`, `NA`, `SA`, `OC`, or `AF`; the StrafeSMPCore deployment sets this in its config and sends it for players and teams.

### Individual and bulk mutations

`POST /v1/points/adjust` accepts `{ "subjectType": "team|player", "subjectId": "<uuid>", "delta": 25, "reason": "admin", "displayName": "Example", "prefix": "EX", "memberCount": 3 }`. Negative deltas are allowed and the resulting balance is clamped to zero. `POST /v1/points/set` has the same fields but uses `points` from 0 to 2,147,483,647 instead of `delta`. Optional display fields are only changed when included. Both return `{ "eventId", "duplicate", "items": [<current balance>] }`.

`POST /v1/points/bulk` accepts `{ "subjectType": "team|player", "operation": "adjust|set", "amount": 25, "reason": "admin all" }`. A negative `amount` with `operation: "adjust"` deducts points; `operation: "set"` requires a non-negative amount. It changes existing balance rows only and returns `{ "eventId", "duplicate", "affectedCount" }`. This covers ADD, DEDUCT, SET, RESET (set to the configured starting points), and `all` without one request per player.

`POST /v1/points/delete` accepts `{ "subjectType": "team|player", "subjectId": "<uuid>", "reason": "team disbanded" }` with an `Idempotency-Key` UUID. It returns `{ "eventId", "duplicate", "deletedCount" }`. The API removes the balance and profile while retaining all match history. A permanent tombstone prevents old snapshots, profile sync, and later point writes from reviving a deleted UUID; writes for a tombstoned subject return `409 subject_deleted`.

### Match settlement

SMP team and solo standings are stored per season in `point_season_balances`; each row carries its season ID. The API keeps live gameplay balances in `point_balances` and mirrors changes into the active season. Existing balances become `season-1` when this migration is first applied. The season list endpoint returns display labels, IDs, and the current-season marker.

To start a new season, update the single `point_settings` row in Supabase Table Editor (`singleton = true`) and set `current_season` to a new lowercase ID such as `season-2`. The database creates its display label, marks the previous season complete, archives its standings in place, and resets team and solo points, wins, and losses to zero in the same transaction. Completed season IDs cannot be activated again. Rename a label by editing `point_seasons.display_name`. The API key table and season setting can be managed through Supabase; no season environment variable or redeploy is needed. The initial season keeps a one-time compatibility exception for matches queued before the API was connected; each season created by an administrator enforces the match start cutoff.

Before changing seasons, let the plugin's `/strafe points queue` drain. The API serializes season changes against point writes and rejects a new match settlement with `409 season_mismatch` if its `startedAt` predates the active season's `started_at`. This prevents delayed matches from changing the new season. The plugin must preserve that outbox record for an administrator to decide whether to discard it or resolve it separately; do not change its timestamp or replay it under a new ID. Already-recorded match IDs remain safely replayable after rollover. After the setting change, run `/strafe points all refresh` on the server or wait for its configured sync interval before starting ranked SMP matches. PVP leaderboards remain empty and are not assigned to these SMP seasons.

`POST /v1/matches/settle` requires `Idempotency-Key` to equal the `matchId` UUID in its JSON body:

```json
{
  "matchId": "00000000-0000-4000-8000-000000000010",
  "subjectType": "team",
  "subjectAId": "00000000-0000-4000-8000-000000000001",
  "subjectBId": "00000000-0000-4000-8000-000000000002",
  "winnerId": "00000000-0000-4000-8000-000000000001",
  "ranked": true,
  "startedAt": 1790928000000,
  "endedAt": 1790928300000,
  "durationSeconds": 300,
  "battleSize": 2,
  "deltaA": 20,
  "deltaB": -20,
  "displayA": {"displayName": "Example A", "prefix": "A", "memberCount": 3},
  "displayB": {"displayName": "Example B", "prefix": "B", "memberCount": 2}
}
```

Times are epoch milliseconds; `endedAt` may be at most five minutes ahead of API time to tolerate clock skew. `subjectType` is `team` or `player`; `battleSize` is required for teams and omitted for players. `winnerId` is `null` for a draw or one of the two subject IDs. Unranked matches must have zero deltas. The API derives W/L increments from `winnerId`, applies both point deltas, refreshes provided profiles, and inserts match history in one PostgreSQL transaction. Match responses include `{ "eventId", "duplicate", "eventSeason", "currentSeason", "items": [...] }`. `eventSeason` is the season stored with the event; `currentSeason` is the non-null active season when the response is produced. A duplicate from an older season returns its cached result and those two fields will differ; acknowledge it without merging its old balance rows, then reconcile after the outbox drains. A draw adds no win or loss. A non-draw updates W/L even for unranked matches, matching the plugin's current behavior.

## Manual team roster publication

Apply `20261011000000_manual_season_team_rosters.sql` using `pnpm migrate:prod`, then update the Minecraft plugin. `/strafe tiers team push` publishes all local team member names and roles to the active season. Ordinary plugin saves continue syncing competitive/profile metadata without member lists. No new API-key permission is required: publication uses the existing `points:write` profiles endpoint.

Explicit team profile publications include `members`, `rosterSeason` (the known active season ID) and `rosterPublishedAt` (a positive epoch millisecond integer, unchanged on retries). They are stored in `point_season_team_rosters`; leaderboards join rosters by both team ID and viewed season. The runtime role has no direct table access. Duplicate and older publication timestamps are skipped under the same team identity lock; delayed pushes for a season that has ended return an acknowledged no-op and cannot block subsequent point events. A subsequent push is needed for the new season. Legacy automatic profiles containing members without publication metadata have those members ignored. Previously automatic, unversioned member lists are not backfilled into seasons; an administrator must explicitly publish them.

## Season kit images

Apply `20261010000000_season_kit_images.sql` with `pnpm migrate:prod`. In Supabase Table Editor, set `point_seasons.kit_image_url` to a public HTTPS image URL for each season; leave it null when no recommendation is available. Use a trusted image host (for example a public Supabase Storage object), since visitors load the artwork directly from that host. No storage credentials belong in the URL.

`GET /v1/leaderboards/seasons` includes `kitImageUrl` on each season and keeps its existing `leaderboards:read` permission. Runtime API credentials cannot modify season artwork. The website selects artwork using the viewed season, including historical seasons; its existing season metadata cache refreshes in 15 seconds.

## Storage retention and maintenance

- `point_mutations` is the permanent idempotency ledger. Keep every event UUID, request hash, and stored response indefinitely: the plugin may replay an old outbox item after a long outage, and removing an event identity could apply that mutation twice. This table grows with successful writes; it has an age index for operations and appears in the storage metrics.
- Active match rows remain in `point_matches` for 180 days. The administrator-only `archive_point_matches_before` function copies each row to `point_matches_archive` and removes it from the active table in the same transaction. The archive keeps all match history indefinitely, and the permanent mutation receipt remains available for replay. The batch limit is 10,000; call repeatedly until it reports fewer than 10,000 rows archived.
- Run the archive function from the SQL Editor as `postgres`, for example:

```sql
select public.archive_point_matches_before(now() - interval '180 days', 10000);
```

- Use `select public.get_points_storage_metrics();` to inspect row counts, oldest timestamps, and total table/index bytes for the ledger and active/archive match tables. Exact row counts scan the tables, so run this during a quiet period and avoid high-frequency polling.
- The active 180-day window is a starting policy; adjust the cutoff if product or audit requirements need a longer active history. Archive rows and the mutation ledger currently have no deletion policy, so overall database storage still grows.

## Security notes

- The API does not use a Supabase service-role key. Its database connection uses a dedicated `strafe_points_api` login that inherits only the `strafe_points_runtime` role. That role has schema usage and execute rights on scoped API wrapper functions, with no direct access to point tables or inner mutation functions.
- Supabase Studio's administrative `service_role` can manage `api_keys`, `point_settings`, and season display labels; it has no grants on live/seasonal balance, profile, mutation, match, or tombstone tables. The HTTPS migration grants only the explicit `strafe_api` runtime entry points. Keep service-role credentials out of this API process.
- API keys are looked up by SHA-256 hash and are never stored in plaintext. Required scopes are checked both in the HTTP server and in the database wrapper functions, including on each read/write RPC; key revocation and scope changes apply to the next request.
- Database connections to remote Supabase projects verify TLS using the root certificate at `DATABASE_SSL_CA_PATH`. Do not place the runtime database password or API keys in browser code or source control.
- The mutation RPC records the event UUID, request hash, API key row ID, response, and match summary in the same transaction as point changes. It rejects a reused UUID with a different request.
- Team deletion is serialized against match writes, balance mutations, initial snapshots, and profile sync. Its tombstone is retained after match history remains available.
- `leaderboards:read` exposes leaderboard IDs, names, team prefixes/member counts, points, ranks, and W/L totals. `points:read` additionally exposes individual UUID balances and a full paginated balance snapshot. Keep the website key server-side with only `leaderboards:read`.
- Older plugin versions could create `strafesmp_*_archive` tables outside this API migration. The current plugin no longer writes those snapshots, and this API does not read those tables. If an earlier version created them, review their grants and policies and drop them if they are no longer needed; they may contain member UUIDs and roster data.
- The key provisioning function is executable only by the Supabase `postgres` role, which is used by the authenticated SQL Editor administrator. It returns plaintext only at issuance; changing or revoking a key never reveals it.

## Proxy-managed skin selection

Apply migrations through `20261017000000_account_skin_command_rate_limit.sql` with `pnpm migrate:prod`, then rebuild/restart the API before deploying the new StrafeVelocity plugin. The prepare/commit RPCs accept authenticated cracked identities and reject premium identities with `premium_skin_managed_by_minecraft`. Explicit selections use an atomic three-per-minute rolling limit; automatic mirroring retains the rolling 24-hour cooldown. `nextSkinChangeAt` describes the automatic mirror deadline, not the explicit command limit. Request UUID idempotency is preserved. Linking is required for cracked competitive participation, not for skin selection.

Velocity resolves and saves skins through its local SkinsRestorer API, then sends signed canonical textures through the existing prepare/commit endpoints. Native SkinsRestorer changes are independent; Velocity checks its current saved selection after the API cooldown expires, and updates the website/NPC mirror only when the appearance differs. Premium leaderboard skins remain sourced from Minecraft. No new endpoint, permission scope, or shared SkinsRestorer database is needed.
