# Proxy Balancer API v2.0

Deploy the SQL migration and API before enabling the Velocity module. No player points/teams/inventories are rewritten.

## Operator setup

Configure Redis once on the API, after deploying migrations `20261103000000_proxy_balancer.sql` and `20261113000000_proxy_discovery.sql`:

```dotenv
PROXY_REDIS_URL=redis://username:password@redis.internal:6379/0
PROXY_REDIS_PREFIX=strafe:proxy:
PROXY_DISCOVERY_POOLS=as
```

Use authenticated private Redis, or `rediss://` for TLS. All API replicas must share the same Redis database, prefix and allowed pools. Allowed pools are an explicit self-registration opt-in; API keys with `accounts:write` are trusted to advertise a proxy in these pools. Keep database/API/Redis clocks synchronized. Redis needs GET, MGET, SET, EVAL and TIME (and normal client handshake commands) for the configured key prefix. No client or Paper backend receives Redis credentials.

Every proxy reuses its existing **individual** Strafe API key with `accounts:read,accounts:write` scopes. Use that same key for its account client and balancer client; do not share one key across proxies. For a new proxy, generate its credential with `pnpm api-key:generate --label "Proxy sg1" --scopes accounts:read,accounts:write --region AS`, following the normal key installation instructions. There is no longer a manual `proxy_nodes` insert or a peer list to copy.

On Velocity, replace the old `proxies` array with a `self` object in `proxy-balancer.json`. Set only the node's own public endpoint, display information and local logical backend mappings. The shared `pool` and bridge secret are identical across the pool. An empty `proxyId` derives a stable ID from the public host and port; set a stable explicit ID if the endpoint may change. When migrating an existing node, retain its old `proxyId` and API key so saved preferences survive. Registration cannot change that credential's ID/pool, take another key's ID, or re-enable an administratively disabled node.

The first accepted heartbeat registers the node and publishes its endpoint, instance, READY/DRAINING state, player count, CPU/heap load, scheduler delay and reachable backend roles to Redis. Heartbeats run every five seconds; each health key expires 20 seconds after the accepted database heartbeat. Late/out-of-order updates cannot extend expired health or overwrite a newer process. A proxy with missing/inconsistent Redis health is UNHEALTHY even if its durable SQL catalog row remains. Redis keys require no polling cleanup job. Saved preferences and account handoff transactions remain durable in PostgreSQL.

Pools support up to 54 enabled identities, including ten-proxy deployments. The companion inventory grows in rows of nine. Historical rows preserve preferences; disable retired identities administratively to free capacity. Registered endpoints are supplied by trusted proxy credentials. Logical `backends` maps stable roles to registered Velocity names; matching roles across nodes must refer to the same physical backend. Head textures are optional base64 properties, maximum 2048 characters.

Legacy `proxies` configurations and manually provisioned rows remain supported. Without `PROXY_REDIS_URL`, legacy deployments keep their previous SQL health path; self-registration requires Redis and an allowed pool. Once Redis is configured, it gates health and new handoff creation for all nodes served by that API. Redis failures return 503 for discovery/new handoffs and leave established player connections alone; in-flight destination completion can still finish the SQL account ownership transaction. Offline command queues are disabled and Redis operations have a two-second deadline. After recovery, fresh heartbeats repopulate health automatically.

Set `advanced.accepts-transfers=true` on destination Velocity instances. Keep all proxies on the same LimboAuth database and UUID/premium policy, with synchronized clocks. Native transfers/cookies require Java 1.20.5+. The ticket is a routing hint only; it does not bypass LimboAuth. Test actual premium and cracked logins before enabling automatic failover.

The API will not steal a live proxy identity on a changed process instance: a replacement starts reporting after the old instance's heartbeat is 20 seconds stale. The first-ever registration starts immediately.

## HTTP contract

For backend `/proxy` commands with fresh estimates on every opening, apply
`20261115010000_proxy_menu_refresh.sql` and update both Velocity and the Paper companion.
The authenticated `probe-create` call reuses a matching active job, and creates a new
job immediately after expiry instead of imposing the previous 30-second cooldown.
The 32-active-job source cap, API rate limits, and account-session checks remain.
Opening the selector does not change the player's saved proxy preference.

All routes are `POST /v1/proxy-balancer/<action>` with JSON and a bearer `ssmp_live_...` API key. The database binds each key to one enabled proxy node, creating the row on the first permitted self-registration heartbeat. Requests are limited to 32 KiB; balancer control traffic has a separate 1800/key budget, probe actions have their own 600/key budget, and all balancer traffic shares a 7200/IP fixed-window ceiling. Probe polling cannot exhaust control/heartbeat/drain budgets. Optional `PROXY_RATE_LIMIT_MAX_PER_KEY`, `PROXY_PROBE_RATE_LIMIT_MAX_PER_KEY`, and `PROXY_RATE_LIMIT_MAX_PER_IP` tune these limits; the existing global in-flight limit still applies. Error details never expose raw session tokens, IP addresses or tickets in logs.

Every action carries the immutable running-process `instanceId` UUID. Non-heartbeat calls must match the registered generation and a fresh heartbeat; register with heartbeat before making other requests. Late callbacks from a former process are rejected even when the API key is unchanged.

Successful domain results use `ok:true`; safe rejections use `ok:false,code:<reason>` with HTTP 200. Invalid input returns HTTP 400; unbound/unauthorized keys return 401/403. Callers must test `ok`, not only HTTP status.

| Action | JSON input | Result |
| --- | --- | --- |
| heartbeat | instanceId UUID, increasing sequence, state READY/DRAINING, players, cpu/heap fractions or null, schedulerDelayMs or null, backends logical-ready list; optional registration: id/pool/region/name/host/port/priority/capacity/headTexture/backends map | proxyId, pool, regional proxies, probeJobs, serverTime |
| catalog | empty object | same catalog fields |
| preference | playerId | proxyId or null, revision (0 when absent) |
| preference-save | playerId, sessionToken, expectedRevision, proxyId (self) | preferenceSaved, proxyId, revision; initializes only an absent preference |
| probe-create | playerId, sessionToken, observed public literal ip | id |
| probe-jobs | empty object | probeJobs: id/ip/expiresAt |
| probe-result | id, pingMs (number or null) | ok |
| probe-read | id (source's own job) | done, results: proxyId/pingMs, expiresAt |
| handoff-create | playerId, sourceSessionToken, targetProxyId, optional targetInstanceId UUID, backend logical ID, reason, preferenceRevision | ticket (opaque 64 hex), handoffId UUID, expiresAt |
| handoff-consume | ticket, playerId, sessionToken (destination's new token) | handoffId, backend, sourceProxyId, reason, preferenceRevision |
| handoff-complete | handoffId, playerId, sessionToken (same destination token), playerName, premium, backend | account (normal session snapshot), preferenceSaved, sessionStartedAt milliseconds |
| handoff-cancel | handoffId, playerId, sourceSessionToken | cancelled boolean |
| handoff-status | handoffIds (maximum 50 UUIDs) | source-owned handoffs: handoffId/state pending, claimed, completed or expired |

Catalog entries contain id/pool/region/name/host/port/priority/capacity/headTexture/backends/state/players/cpu/heap/schedulerDelayMs/readyBackends/instanceId/lastSeen. Proxy readiness becomes UNHEALTHY after 20 seconds without a heartbeat. A target must be READY in both SQL and Redis, below capacity, in the same pool and able to reach the requested backend before a ticket is issued. Updated Velocity clients also bind handoff-create to the selected destination instance, rejecting selections captured before a destination restart.

## Persistence and invariants

- The `20261115000000_proxy_admin.sql` migration adds a short-lived relay for `/proxy admin`.
  Trusted Velocity instances authorize the player via OP or `strafevelocity.admin`. The API
  verifies requester session ownership and proxy generation, limits commands to matching pools,
  and accepts results only from the selected source instance. The source responds with a live
  roster page or runs a selected move or directed drain. Requests are claimed once and expire
  after 30 seconds. Roster responses contain player names and opaque connection identities.

- `proxy_preferences` is separate from current presence and scoped by player UUID plus pool. Initial saves only insert; manual completion uses the captured revision. `preferred`, `drain` and `health` handoffs never update preference. `/server` does not write this API state.
- Probe jobs require the source's live authenticated account session and a public literal IP. Jobs accept results for four seconds. Expired IPs are scrubbed on subsequent authenticated API work; results remain readable for 30 additional seconds, then bounded cleanup removes the job. These are logical expiry/cleanup intervals: if the whole API is idle or offline, physical deletion waits for the next authenticated call. No raw IP is logged; different pools cannot retrieve these jobs. At most 32 active source jobs and one per player/source per 30 seconds are admitted.
- Tickets are stored hashed, expire after 60 seconds, and bind player, pool, source/destination process instances, backend, reason and source nonce. The destination claims a ticket once for its new session nonce. Retries for that exact nonce are idempotent; a cookie replay from another connection is rejected. The destination must authenticate normally before claiming, route to the mapped backend, and complete only after that backend confirms connection.
- Completion atomically changes account-session ownership to the destination key/new nonce and permanently retires the source nonce. A late source heartbeat remains rejected even with a future local timestamp; source disconnect/end cannot clear the destination. Existing ordinary login policy remains unchanged. Tier-ban/session advisory locks use one consistent order.
- A completed handoff can be retried only with its original destination nonce. Preference updates happen in the same transaction; failed or stale arrivals do not overwrite preferences. Completed handoff records remain one day for acknowledgement, then bounded cleanup removes them. Retired nonce hashes have an indexed permanent tombstone so late callbacks can never resurrect them.
- Manual handoff cooldown is enforced across proxies: 30 seconds after successful manual completion. Emergency handoffs are exempt. `transfer_cooldown` includes `waitSeconds`.
- Source-side pre-transfer failures cancel an unclaimed ticket with the source's live nonce and process instance. Claimed/completed tickets cannot be cancelled from the source; they finish or expire. Drain status counts destination completions, not source disconnections.
- API/database failure leaves existing connections untouched; clients must suspend automatic moves. Neither health checks nor ICMP prove that the client's TCP route to the destination will connect. Native transfer does not support rolling back a disconnected source socket.

## Verification

`pnpm verify:proxy-balancer` builds TypeScript and runs input/privacy checks. `pnpm verify:proxy-discovery` checks registration validation and routing under expired/missing health. Set `PROXY_TEST_REDIS_URL` to an isolated Redis instance to also exercise the actual RESP client, Lua fencing and lease expiry; test keys use a random prefix and do not touch application keys. To run PostgreSQL-language transition tests without production credentials, install `@electric-sql/pglite` in an isolated temporary directory, set `PROXY_SQL_ENGINE_PATH` to its `dist/index.js`, and run the same command. Tests use the actual previous account-session SQL with isolated table stubs, apply this migration, and exercise ownership/CAS/replay/expiry/cancellation/late-heartbeat transitions. They do not connect to or modify production databases. Full PostgreSQL plus real Velocity/LimboAuth/client staging remains a deployment acceptance check.
