# Conditional reads: production rollout

This release reduces Supabase response bytes while keeping existing Minecraft,
Velocity and website request/response contracts. Those clients need no update or
restart. Deploy the API code and its additive database migration using the current
deployment process. No live service or production database was changed during local verification.

## How it works

- Point snapshots, season leaderboards, season metadata and tier-ban batches are
  recomputed and authorized in Supabase on every request. If their SHA-256 digest
  matches the API's bounded local copy, only a small confirmation leaves Supabase.
- Proxy heartbeat/catalog/probe polling still executes the existing fenced SQL
  operation on every request. An unchanged descriptive catalog reuses names,
  addresses, head textures and backend definitions. Every health value, player
  count, instance ID, last-seen time, probe job and server timestamp is sent fresh.
- The API reconstructs the existing public response before sending it to clients.
  This also reduces the Supabase cost of repeated uncached website tier requests.
- API keys are still authenticated on every HTTP request, and the original scoped
  SQL function executes before the digest comparison. Bans, key revocations,
  deletes, season changes, region isolation and transfer ownership remain current.
- There is no successful stale-cache response during a database failure. Cache
  entries expire after 15 minutes of inactivity, with at most 512 entries and a
  32 MiB serialized-value budget per API process. Tiny results use the original RPC
  so a digest envelope does not make recurring small responses more expensive.

This reduces **transfer bytes**, not query frequency. SQL still computes the result
and adds hashing work. Each API instance has its own cache and starts cold after a
restart. Actual billed savings depend on payload sizes, traffic and compression.

## Apply

1. Use `pnpm migrate:prod --sql` to generate the complete history-aware
   `migrations-prod.sql`, then run that file as `postgres` in Supabase SQL Editor.
   The new migration is `20261125000000_conditional_api_reads.sql`. Use the normal
   migration runner instead if it is already part of deployment. Do not run the
   single new migration manually outside the tracked history.
2. Build with `pnpm build:prod` and roll out the API through the existing service or
   container deployment. `API_CONDITIONAL_READS=true` is the default; existing
   environment files work without adding it.
3. Keep the existing plugin JARs, keys, endpoints, Redis configuration, rates and
   website deployment. Check `/healthz` and `/readyz`, open a leaderboard and
   `/proxy`, and confirm ordinary account/point requests in the API logs.

The SQL adds one scoped function and no data updates, table rewrites or changes to
existing RPCs. Either deployment order works: new code automatically uses legacy
RPCs when the new function is unavailable and checks again after 60 seconds.
Database migrations still need the usual administrator access. A single API process
restart has a brief service interruption; use the established rolling deployment
if continuous API availability is required. The game servers can remain running.

## Observe and roll back

The HTTPS transport emits `supabase_rpc_traffic` summaries every 60 seconds with
operation name, call count and `decodedResponseBytes`. These contain no credentials,
player IDs or response content. The byte count measures decoded JSON bodies, not
Supabase's billed on-wire bytes. Compare the summaries and the next hourly Supabase
usage update against the previous workload. A renamed conditional operation appears
as `api_read_if_changed:<operation>` in these summaries.

Set `API_CONDITIONAL_READS=false` and roll the API to use the original paths, or
roll back the API image. The additive database function can stay installed.

## Verification

- TypeScript production build.
- `pnpm verify:conditional-reads`: cache bounds, authorization failures, region and
  page partitioning, updates/deletes/season resets, immediate ban changes, missing
  migration fallback, real local HTTP routes and legacy client response shapes.
- With `PROXY_SQL_ENGINE_PATH` pointing to an isolated PGlite `dist/index.js`, the
  conditional suite runs its PostgreSQL checks, and `verify:proxy-balancer` runs
  the existing proxy/session/handoff suite plus transport reconstruction checks.
  Without that test-only engine, the SQL-specific checks are reported as skipped.
- The local 500-row snapshot fixture fell from 75,063 bytes to 111 bytes when
  unchanged. The two-proxy fixture used 16,209 instead of 48,478 bytes over repeated
  polls (about 67% less). These are test JSON payload measurements, not a prediction
  of production billing.
