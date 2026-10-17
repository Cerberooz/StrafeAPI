# Separate regional records

## Behavior

Every points API key has an immutable `point_region`: AS, EU, NA, SA, OC, or AF.
Points reads and writes use that region. The same player UUID can have independent
AS and EU points, wins, losses, matches, season standings, and team memberships
published through regional team rosters. Values are never added together.
Balances, mutation IDs, deleted-team tombstones, import gates, and season lifecycle
are all isolated. Accounts, premium status, skins, Discord links, and tier bans
remain shared across regions.

The plugin's existing HTTP requests work unchanged. Set each deployment's
`leaderboard.region` to match its key for consistency; the key is authoritative.
Keep each region's plugin database and points outbox separate. Do not reuse a
Minecraft server's pending outbox with a key from another region: queued events
would then be delivered to that other region. Drain it before any deployment move.

## Existing data

Migration `20261024000000_isolated_region_records.sql` keeps existing records and
keys in **AS**, matching the current deployment. The other five stores start with
no point records. Only current-season metadata/settings are copied to initialize
them; their future season lifecycle is independent. Existing profiles are labelled
AS, and all subsequent profile writes automatically use their actual store region.

Previously combined historical data cannot be divided reliably by region. Do not
import a previously shared/mixed plugin cache into a new region. Restore a verified
region-specific database or initialize a clean regional deployment instead. This
migration does not delete, reset, or attempt to guess the origin of existing points.

## Deployment

1. Back up the database, then apply pending migrations from API-Server:

   ```sh
   pnpm migrate:prod
   ```

   For SQL Editor deployment, generate the tracked migration bundle instead:

   ```sh
   pnpm migrate:prod --sql
   ```

2. Rebuild/redeploy API-Server. Existing AS keys continue working.
3. For each additional region, create a new key:

   ```sh
   node scripts/generate-api-key.mjs --label "SMP EU" --region EU --scopes points:read,points:write
   ```

   Enter the printed values, **including `point_region`**, when creating the
   `public.api_keys` row. Never publish the token. Install that key in the region's
   existing `database.yml` points API configuration and restart its Minecraft
   server. The separate competitive region lock also needs the plugin rollout
   described below.
4. Rebuild/redeploy WebApp and StrafeTiers. Re-register `/tier` once to expose the
   optional `region` choice. Existing user installations do not need reinstalling.

## Reading records

Leaderboard-read keys can select a region without getting points-write access:

- `/v1/leaderboards/seasons?region=EU`
- `/v1/leaderboards/smp-solo?region=EU&season=season-1`
- `/v1/leaderboards/smp-teams?region=EU&season=season-1`
- `/v1/tiers/profile?name=Cerberooz&region=EU`

Omitting region uses the API key's region. The website and Discord command default
to AS explicitly and let users choose another region. Their caches include region.
Tier percentiles and rank positions are calculated within the selected region.
Discord still chooses the best season for each mode, within that region only.

## Database administration and maintenance

AS retains `public.point_*`. EU uses `strafe_points_eu.point_*`; other regions use
the matching suffix. For example, starting a new EU season:

```sql
update strafe_points_eu.point_settings
set current_season = 'season-2'
where singleton = true;
```

The existing season triggers reset only EU balances and preserve EU history.
Update kit/display metadata in that region's `point_seasons`. Regional schemas
are not exposed to PostgREST and grant no direct table/function access to API
roles. The one allowlisted dispatcher authenticates, checks scopes, and selects
the store; direct legacy AS points RPCs reject keys from another region.

Future SQL migrations that change points tables must apply the structural change
to every regional schema. After modifying AS points functions/triggers, call
`select public.refresh_regional_points_implementations();` in the same migration
to refresh regional implementations. Do not edit an already applied migration.

Source builds passed for API-Server, WebApp, and StrafeTiers. The migration has not
been executed against a live database in this task; deployment and live regional
data verification remain required.

## Competitive region lock

Migration `20261025000000_competitive_region_lock.sql` adds a central, atomic
player assignment. Queue checks are read-only. The first match to reach combat
claims every participant for the region fixed on that server's points API key.
The authorization endpoint accepts player UUIDs and a match UUID, plus an
expected region assertion and the match's subject IDs; it never accepts a
client-selected region. PostgreSQL verifies that assertion against the key's
immutable region before writing any player assignment, and the claim binds the
match ID, roster, and settlement subjects together. Sorted advisory locks
serialize two servers trying to claim the same player at once. Match settlement
also requires a claim for every settlement received after the migration, so a
stale or misconfigured plugin cannot post an unclaimed result into another region.

Before applying the migration, stop queues, let active matches finish, and drain
each server's point outbox. Retry or explicitly resolve dead-lettered match
settlements before migration; do not assume they can be safely discarded. This
prevents old match records from arriving after the migration, which requires a
claim for every settlement. Keep every backend offline or its queues closed
while updating; an old plugin can still start a local match, but its settlement
will be rejected by the migration's claim trigger. Deploy the API, install the
updated plugin on every region, set `competitive.region` and its matching API key
in each plugin configuration, apply the migration, verify the new API calls,
then reopen queues. A new plugin with the old API fails closed. Keep each
server's `points-api.api-key` tied to its own immutable
`point_region` value and set `competitive.region` to the same code. The existing
AS key stays AS; issue a separate key for each additional region.

The migration seeds AS assignments from existing solo points/history and from
published team rosters that predate recorded team matches. It cannot infer past
team participants when that season's roster was never published or no longer
matches the roster at match time. Those specific known players should be assigned
to AS by support before another region opens; do not bulk-lock every player on a
team, because that would lock people who have never played a match.

For a support-approved transfer, use the privileged Supabase SQL Editor function
with a case ID and reason. The operation is audited and leaves old point and match
records in their original region:

```sql
select public.transfer_competitive_player_region(
  '00000000-0000-0000-0000-000000000000', 'EU', 'support-case-123',
  'Approved permanent region transfer'
);
```

The underlying assignment, claim, and audit tables are not directly exposed to
API keys or the points runtime database role. A trusted `points:write` API key
can query assigned regions for player UUIDs through the competitive check route
because the server needs to validate opponents. The competitive queue requires
the API; an outage or failed region lookup blocks queue entry and match start.
If an authorization request commits while a local match is aborting, its player
assignment is retained because cancelling it safely requires a durable
reservation protocol. The plugin logs the match ID and participant roster for
support review; use the audited transfer function if combat did not start.
