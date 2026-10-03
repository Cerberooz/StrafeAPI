import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { mkdir, readFile, readdir, rename, stat, unlink, writeFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import { resolve } from 'node:path';
import { Pool } from 'pg';
import sharp from 'sharp';

const MAX_POINTS = 2_147_483_647;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const API_KEY_PATTERN = /^ssmp_live_[0-9a-f]{64}$/;
const MAX_BODY_BYTES = 512 * 1024;
const MAX_FUTURE_MATCH_SKEW_MS = 5 * 60 * 1_000;
const SNAPSHOT_BATCH_MAX = 500;
const FIXED_LOG_ROUTES = new Set([
  'GET /v1/points/snapshot',
  'POST /v1/points/snapshot',
  'POST /v1/points/profiles',
  'POST /v1/points/delete',
  'POST /v1/matches/settle',
  'POST /v1/points/adjust',
  'POST /v1/points/set',
  'POST /v1/points/bulk',
  'POST /v1/accounts/session',
  'POST /v1/accounts/session/end',
  'POST /v1/accounts/link',
  'POST /v1/accounts/skin/prepare',
  'POST /v1/accounts/skin/commit',
  'POST /v1/accounts/skin/cancel',
  'POST /v1/accounts/admin/recover',
  'GET /v1/accounts/skins',
  'GET /v1/tiers/players',
  'GET /v1/tiers/status',
  'POST /v1/tiers/ban',
  'POST /v1/tiers/unban',
]);

type SubjectType = 'team' | 'player';
type Scope = 'leaderboards:read' | 'points:read' | 'points:write' | 'accounts:read' | 'accounts:write' | 'accounts:admin' | 'tiers:moderate';
type JsonRecord = Record<string, unknown>;

interface Balance {
  subjectType: SubjectType;
  subjectId: string;
  displayName: string | null;
  prefix: string | null;
  memberCount: number | null;
  points: number;
  wins: number;
  losses: number;
}

interface ApiKey {
  id: string;
  label: string;
  scopes: string[];
  expires_at: string | null;
  key_hash: string;
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details: JsonRecord = {},
  ) {
    super(message);
  }
}

class BackendError extends Error {
  constructor(readonly responseStatus?: number, readonly backendCode?: string) {
    super('The data service request failed.');
  }
}

class RateLimiter {
  private readonly buckets = new Map<string, { startedAt: number; count: number }>();
  private cleanupTicks = 0;

  constructor(
    private readonly windowMs: number,
    private readonly maxRequests: number,
  ) {}

  take(key: string, now = Date.now()): number | null {
    let bucket = this.buckets.get(key);
    if (!bucket || now - bucket.startedAt >= this.windowMs) {
      bucket = { startedAt: now, count: 0 };
      this.buckets.set(key, bucket);
    }
    bucket.count += 1;
    this.trim(now);
    if (bucket.count <= this.maxRequests) return null;
    return Math.max(1, Math.ceil((bucket.startedAt + this.windowMs - now) / 1000));
  }

  private trim(now: number): void {
    if (this.buckets.size <= 20_000) return;
    this.cleanupTicks += 1;
    if (this.cleanupTicks % 128 !== 0) return;
    for (const [key, bucket] of this.buckets) {
      if (now - bucket.startedAt >= this.windowMs) this.buckets.delete(key);
      if (this.buckets.size <= 15_000) return;
    }
    while (this.buckets.size > 20_000) {
      const firstKey = this.buckets.keys().next().value as string | undefined;
      if (!firstKey) return;
      this.buckets.delete(firstKey);
    }
  }
}

function readIntegerEnv(name: string, fallback: number, min: number, max: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer from ${min} to ${max}.`);
  }
  return value;
}

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
}

const port = readIntegerEnv('PORT', 5000, 1, 65_535);
const rateWindowMs = readIntegerEnv('RATE_LIMIT_WINDOW_MS', 60_000, 1_000, 3_600_000);
const maxPerIp = readIntegerEnv('RATE_LIMIT_MAX_PER_IP', 120, 1, 100_000);
const maxPerKey = readIntegerEnv('RATE_LIMIT_MAX_PER_KEY', 600, 1, 100_000);
const databasePoolMax = readIntegerEnv('DATABASE_POOL_MAX', 10, 1, 100);
const maxInFlightRequests = readIntegerEnv('MAX_IN_FLIGHT_REQUESTS', 200, 10, 10_000);
const accountSessionTtlSeconds = readIntegerEnv('ACCOUNT_SESSION_TTL_SECONDS', 180, 90, 600);
const trustProxy = process.env.TRUST_PROXY?.toLowerCase() === 'true';
const listenHost = process.env.HOST?.trim() || '127.0.0.1';
const portraitCacheDirectory = resolve(process.env.ACCOUNT_PORTRAIT_CACHE_DIR?.trim() || './data/account-portraits');
const discordClientId = process.env.DISCORD_CLIENT_ID?.trim() || '';
const discordClientSecret = process.env.DISCORD_CLIENT_SECRET?.trim() || '';
const accountPublicUrlRaw = process.env.ACCOUNT_PUBLIC_URL?.trim() || '';
let accountPublicOrigin: URL | null = null;
if (accountPublicUrlRaw) {
  try {
    const parsed = new URL(accountPublicUrlRaw);
    const localHost = ['localhost', '127.0.0.1', '[::1]'].includes(parsed.hostname);
    if (!['https:', ...(localHost ? ['http:'] : [])].includes(parsed.protocol)
      || parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/') {
      throw new Error();
    }
    accountPublicOrigin = parsed;
  } catch {
    throw new Error('ACCOUNT_PUBLIC_URL must be an HTTPS origin (HTTP is allowed for localhost development).');
  }
}
const accountOAuthEnabled = Boolean(discordClientId && discordClientSecret && accountPublicOrigin);

const databaseUrlRaw = requiredEnv('DATABASE_URL');
let databaseUrl: URL;
try {
  databaseUrl = new URL(databaseUrlRaw);
} catch {
  throw new Error('DATABASE_URL must be a valid PostgreSQL connection URL.');
}
if (!['postgres:', 'postgresql:'].includes(databaseUrl.protocol)) {
  throw new Error('DATABASE_URL must use the postgres or postgresql scheme.');
}
if (['sslmode', 'sslcert', 'sslkey', 'sslrootcert'].some((parameter) => databaseUrl.searchParams.has(parameter))) {
  throw new Error('Remove SSL parameters from DATABASE_URL and configure DATABASE_SSL_CA_PATH instead.');
}
const isLocalDatabase = ['localhost', '127.0.0.1', '[::1]'].includes(databaseUrl.hostname);
const databaseUsername = decodeURIComponent(databaseUrl.username);
if (!isLocalDatabase && !/^strafe_points_api(?:\.[a-z0-9-]+)?$/i.test(databaseUsername)) {
  throw new Error('Remote DATABASE_URL must use the restricted strafe_points_api login.');
}
const sslCaPath = process.env.DATABASE_SSL_CA_PATH?.trim();
let databaseTls: { ca: string; rejectUnauthorized: true } | undefined;
if (!isLocalDatabase) {
  if (!sslCaPath) throw new Error('DATABASE_SSL_CA_PATH is required for remote PostgreSQL connections.');
  try {
    databaseTls = { ca: readFileSync(sslCaPath, 'utf8'), rejectUnauthorized: true };
  } catch {
    throw new Error('DATABASE_SSL_CA_PATH could not be read.');
  }
}

const databasePool = new Pool({
  connectionString: databaseUrlRaw,
  ...(databaseTls ? { ssl: databaseTls } : {}),
  max: databasePoolMax,
  connectionTimeoutMillis: 5_000,
  idleTimeoutMillis: 30_000,
  statement_timeout: 10_000,
  application_name: 'strafe-points-api',
});
databasePool.on('error', () => process.stderr.write('Idle database connection failed.\n'));

const RPC_CALLS = {
  get_point_balance: {
    sql: 'select strafe_api.api_get_point_balance($1::text, $2::text, $3::uuid) as value',
    args: ['p_key_hash', 'p_subject_type', 'p_subject_id'],
  },
  get_points_snapshot: {
    sql: 'select strafe_api.api_get_points_snapshot($1::text, $2::text, $3::integer, $4::uuid) as value',
    args: ['p_key_hash', 'p_subject_type', 'p_limit', 'p_after'],
  },
  get_points_leaderboard: {
    sql: 'select strafe_api.api_get_points_leaderboard($1::text, $2::text, $3::integer, $4::integer, $5::text) as value',
    args: ['p_key_hash', 'p_subject_type', 'p_limit', 'p_offset', 'p_mode'],
  },
  get_smp_leaderboard_seasons: {
    sql: 'select strafe_api.api_get_smp_leaderboard_seasons($1::text) as value',
    args: ['p_key_hash'],
  },
  get_points_leaderboard_for_season: {
    sql: 'select strafe_api.api_get_points_leaderboard_for_season($1::text, $2::text, $3::integer, $4::integer, $5::text, $6::text) as value',
    args: ['p_key_hash', 'p_subject_type', 'p_limit', 'p_offset', 'p_mode', 'p_season'],
  },
  mutate_points: {
    sql: 'select strafe_api.api_mutate_points($1::text, $2::uuid, $3::text, $4::text, $5::jsonb) as value',
    args: ['p_key_hash', 'p_event_id', 'p_request_hash', 'p_operation', 'p_payload'],
  },
  seed_point_snapshot: {
    sql: 'select strafe_api.api_seed_point_snapshot($1::text, $2::jsonb) as value',
    args: ['p_key_hash', 'p_balances'],
  },
  sync_point_profiles: {
    sql: 'select strafe_api.api_sync_point_profiles($1::text, $2::jsonb) as value',
    args: ['p_key_hash', 'p_profiles'],
  },
  account_session_upsert: {
    sql: 'select strafe_api.api_account_session_upsert_with_tier_status($1::text, $2::uuid, $3::text, $4::boolean, $5::text, $6::timestamptz, $7::integer) as value',
    args: ['p_key_hash', 'p_player_id', 'p_player_name', 'p_premium', 'p_session_token_hash', 'p_session_started_at', 'p_ttl_seconds'],
  },
  account_session_end: {
    sql: 'select strafe_api.api_account_session_end($1::text, $2::uuid, $3::text) as value',
    args: ['p_key_hash', 'p_player_id', 'p_session_token_hash'],
  },
  get_account: {
    sql: 'select strafe_api.api_get_account_with_tier_status($1::text, $2::uuid) as value',
    args: ['p_key_hash', 'p_player_id'],
  },
  get_tier_players: {
    sql: 'select strafe_api.api_get_tier_players($1::text, $2::text) as value',
    args: ['p_key_hash', 'p_name'],
  },
  get_tier_ban_statuses: {
    sql: 'select strafe_api.api_get_tier_ban_statuses($1::text, $2::uuid[]) as value',
    args: ['p_key_hash', 'p_player_ids'],
  },
  moderate_tier_ban: {
    sql: 'select strafe_api.api_moderate_tier_ban($1::text, $2::uuid, $3::text, $4::boolean) as value',
    args: ['p_key_hash', 'p_player_id', 'p_actor', 'p_banned'],
  },
  get_account_skins: {
    sql: 'select strafe_api.api_get_account_skins($1::text, $2::uuid[]) as value',
    args: ['p_key_hash', 'p_player_ids'],
  },
  has_account_portrait: {
    sql: 'select strafe_api.api_has_account_portrait($1::text, $2::text) as value',
    args: ['p_texture_hash', 'p_model'],
  },
  start_account_link: {
    sql: 'select strafe_api.api_start_account_link($1::text, $2::uuid, $3::text, $4::text) as value',
    args: ['p_key_hash', 'p_player_id', 'p_session_token_hash', 'p_purpose'],
  },
  get_account_link: {
    sql: 'select strafe_api.api_get_account_link($1::text, $2::uuid, $3::text, $4::uuid) as value',
    args: ['p_key_hash', 'p_player_id', 'p_session_token_hash', 'p_request_id'],
  },
  begin_account_oauth: {
    sql: 'select strafe_api.api_begin_account_oauth($1::uuid, $2::text, $3::text) as value',
    args: ['p_request_id', 'p_step', 'p_state_hash'],
  },
  finish_account_oauth: {
    sql: 'select strafe_api.api_finish_account_oauth($1::uuid, $2::text, $3::text, $4::text, $5::text) as value',
    args: ['p_request_id', 'p_step', 'p_state_hash', 'p_discord_id', 'p_display_name'],
  },
  confirm_account_link: {
    sql: 'select strafe_api.api_confirm_account_link($1::text, $2::uuid, $3::text, $4::uuid) as value',
    args: ['p_key_hash', 'p_player_id', 'p_session_token_hash', 'p_request_id'],
  },
  admin_recover_account_link: {
    sql: 'select strafe_api.api_admin_recover_account_link($1::text, $2::uuid, $3::text, $4::text, $5::text) as value',
    args: ['p_key_hash', 'p_player_id', 'p_discord_id', 'p_display_name', 'p_reason'],
  },
  prepare_account_skin: {
    sql: 'select strafe_api.api_prepare_account_skin($1::text, $2::uuid, $3::text, $4::uuid, $5::text) as value',
    args: ['p_key_hash', 'p_player_id', 'p_session_token_hash', 'p_request_id', 'p_input'],
  },
  commit_account_skin: {
    sql: 'select strafe_api.api_commit_account_skin($1::text, $2::uuid, $3::text, $4::uuid, $5::text, $6::text, $7::text, $8::text, $9::text) as value',
    args: ['p_key_hash', 'p_player_id', 'p_session_token_hash', 'p_request_id', 'p_texture_hash', 'p_model', 'p_texture_value', 'p_texture_signature', 'p_fingerprint'],
  },
  cancel_account_skin: {
    sql: 'select strafe_api.api_cancel_account_skin($1::text, $2::uuid, $3::text, $4::uuid) as value',
    args: ['p_key_hash', 'p_player_id', 'p_session_token_hash', 'p_request_id'],
  },
} as const;

const ipLimiter = new RateLimiter(rateWindowMs, maxPerIp);
const keyLimiter = new RateLimiter(rateWindowMs, maxPerKey);
const portraitLimiter = new RateLimiter(rateWindowMs, Math.min(maxPerIp, 30));
const pendingPortraits = new Map<string, Promise<Buffer>>();
const portraitRegistrationCache = new Map<string, { checkedAt: number; registered: boolean }>();
const pendingPortraitRegistrations = new Map<string, Promise<boolean>>();
let activePortraitFetches = 0;
let portraitCacheWrites = 0;
let lastPortraitPruneAt = 0;

function mapDatabaseError(error: unknown): never {
  const message = error instanceof Error ? error.message.toLowerCase() : '';
  if (message.includes('idempotency_conflict')) {
    throw new HttpError(409, 'idempotency_conflict', 'This idempotency key was already used with a different request.');
  }
  if (message.includes('subject_deleted')) {
    throw new HttpError(409, 'subject_deleted', 'This team or player has been deleted.');
  }
  if (message.includes('leaderboard_season_not_found')) {
    throw new HttpError(404, 'season_not_found', 'The requested leaderboard season was not found.');
  }
  if (message.includes('season_mismatch')) {
    throw new HttpError(409, 'season_mismatch', 'This match started before the active leaderboard season. Keep it queued for an administrator to review.');
  }
  if (message.includes('api_key_scope_denied')) {
    throw new HttpError(403, 'forbidden', 'This API key does not have permission for this operation.');
  }
  if (message.includes('api_key_invalid')) {
    throw new HttpError(401, 'unauthorized', 'A valid API key is required.');
  }
  throw new BackendError();
}

async function rpc<T>(name: keyof typeof RPC_CALLS, parameters: JsonRecord): Promise<T> {
  const specification = RPC_CALLS[name];
  try {
    const result = await databasePool.query<{ value: T }>(
      specification.sql,
      specification.args.map((key) => parameters[key]),
    );
    if (!result.rows[0]) throw new BackendError();
    return result.rows[0].value;
  } catch (error) {
    mapDatabaseError(error);
  }
}

async function findApiKey(token: string): Promise<ApiKey | null> {
  const hash = createHash('sha256').update(token, 'utf8').digest('hex');
  try {
    const result = await databasePool.query<Omit<ApiKey, 'key_hash'>>(
      'select id, label, scopes, expires_at from strafe_api.authenticate_point_api_key($1::text)',
      [hash],
    );
    const row = result.rows[0];
    return row ? { ...row, key_hash: hash } : null;
  } catch (error) {
    mapDatabaseError(error);
  }
}

async function checkDatabaseReady(): Promise<void> {
  try {
    const result = await databasePool.query<{ ready: boolean }>('select strafe_api.points_api_ready() as ready');
    if (result.rows[0]?.ready !== true) throw new BackendError();
  } catch (error) {
    mapDatabaseError(error);
  }
}

function errorResponse(
  response: ServerResponse,
  status: number,
  code: string,
  message: string,
  requestId: string,
  details: JsonRecord = {},
): void {
  sendJson(response, status, { error: { code, message, requestId }, ...details });
}

function sendHtml(response: ServerResponse, status: number, html: string): void {
  response.writeHead(status, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(html),
    'Cache-Control': 'no-store',
    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
  });
  response.end(html);
}

function accountError(code: string, details: JsonRecord = {}): HttpError {
  const retryAfterSeconds = typeof details.retryAfterSeconds === 'number'
    ? Math.max(1, Math.ceil(details.retryAfterSeconds))
    : undefined;
  const messages: Record<string, string> = {
    session_unavailable: 'The authenticated Minecraft session has expired or been replaced.',
    stale_session: 'This Minecraft connection is older than the active session.',
    session_conflict: 'A different Minecraft session started at the same time.',
    session_owned_by_other_key: 'The active Minecraft session belongs to another API key.',
    account_not_found: 'The Minecraft account was not found.',
    account_link_required: 'A non-premium Minecraft account must be linked to Discord before changing its skin.',
    already_linked: 'This Minecraft account is already linked.',
    not_linked: 'This Minecraft account does not have a Discord link to change.',
    link_request_not_found: 'The account link request was not found.',
    link_request_expired: 'The account link request has expired.',
    oauth_step_not_expected: 'This Discord authorization step is not available now.',
    oauth_state_invalid: 'The Discord authorization state is invalid or has expired.',
    old_discord_proof_mismatch: 'The existing Discord account could not be verified.',
    new_discord_proof_invalid: 'The replacement Discord account could not be verified.',
    discord_confirmation_required: 'Confirm this Discord link from the active Minecraft session.',
    account_link_changed: 'The account link changed while this request was pending.',
    discord_already_linked: 'That Discord account is linked to another Minecraft account.',
    idempotency_conflict: 'This request ID was already used with different content.',
    skin_request_throttled: 'Wait briefly before requesting another skin change.',
    skin_cooldown: 'This account is still within its skin change cooldown.',
    skin_request_in_progress: 'A skin change is already being resolved for this account.',
    skin_reservation_expired: 'The skin reservation expired. Start a new request.',
    skin_reservation_not_found: 'The skin reservation was not found.',
    skin_reservation_not_active: 'The skin reservation is no longer active.',
    skin_request_not_active: 'The skin request is no longer active.',
    account_oauth_disabled: 'Discord account linking is not configured on this server.',
    discord_oauth_failed: 'Discord authorization could not be verified. Retry the account link.',
  };
  const rateLimited = retryAfterSeconds !== undefined;
  const status = rateLimited ? 429
    : ['session_unavailable', 'stale_session', 'session_conflict'].includes(code) ? 409
      : code === 'account_link_required' ? 403
        : code === 'link_request_not_found' ? 404
        : ['account_oauth_disabled', 'discord_oauth_failed'].includes(code) ? 503
            : code === 'session_owned_by_other_key' ? 403 : 409;
  const publicDetails: JsonRecord = {};
  if (retryAfterSeconds !== undefined) publicDetails.retryAfterSeconds = retryAfterSeconds;
  if (typeof details.nextSkinChangeAt === 'string') publicDetails.nextSkinChangeAt = details.nextSkinChangeAt;
  return new HttpError(status, code, messages[code] ?? 'The account request could not be completed.', publicDetails);
}

function accountResult(value: unknown): JsonRecord {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new BackendError();
  const result = { ...(value as JsonRecord) };
  if (result.ok === false) {
    const code = typeof result.code === 'string' ? result.code : 'account_request_failed';
    throw accountError(code, result);
  }
  delete result.ok;
  return result;
}

function requireTierStatus(value: JsonRecord): JsonRecord {
  if (typeof value.tiersBanned !== 'boolean') throw new BackendError();
  return value;
}

function publicAccountUrl(path: string): string {
  return accountPublicOrigin ? new URL(path, accountPublicOrigin).toString() : path;
}

function withPublicAccountUrls(value: JsonRecord): JsonRecord {
  const copy = { ...value };
  if (copy.skin !== null && typeof copy.skin === 'object' && !Array.isArray(copy.skin)) {
    const skin = { ...(copy.skin as JsonRecord) };
    if (typeof skin.portraitUrl === 'string' && skin.portraitUrl.startsWith('/')) {
      skin.portraitUrl = publicAccountUrl(skin.portraitUrl);
    }
    copy.skin = skin;
  }
  if (typeof copy.portraitPath === 'string') {
    copy.portraitUrl = publicAccountUrl(copy.portraitPath);
    delete copy.portraitPath;
  }
  return copy;
}

function sendJson(response: ServerResponse, status: number, body: unknown): void {
  const encoded = JSON.stringify(body);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(encoded),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
  });
  response.end(encoded);
}

function requireObject(value: unknown, label = 'Request body'): JsonRecord {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new HttpError(400, 'invalid_request', `${label} must be a JSON object.`);
  }
  return value as JsonRecord;
}

async function readJson(request: IncomingMessage): Promise<JsonRecord> {
  const mediaType = request.headers['content-type']?.split(';', 1)[0]?.trim().toLowerCase();
  if (mediaType !== 'application/json') {
    throw new HttpError(415, 'unsupported_media_type', 'Send a JSON request body.');
  }

  const contentLength = Number(request.headers['content-length'] ?? 0);
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    throw new HttpError(413, 'request_too_large', 'The request body is too large.');
  }

  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.byteLength;
    if (size > MAX_BODY_BYTES) throw new HttpError(413, 'request_too_large', 'The request body is too large.');
    chunks.push(buffer);
  }

  try {
    return requireObject(JSON.parse(Buffer.concat(chunks).toString('utf8')));
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, 'invalid_json', 'The request body is not valid JSON.');
  }
}

function parseUuid(value: unknown, label: string): string {
  if (typeof value !== 'string' || !UUID_PATTERN.test(value)) {
    throw new HttpError(400, 'invalid_request', `${label} must be a UUID.`);
  }
  return value.toLowerCase();
}

function parseSubjectType(value: unknown): SubjectType {
  if (value === 'team' || value === 'player') return value;
  throw new HttpError(400, 'invalid_request', 'subjectType must be team or player.');
}

function parseInteger(value: unknown, label: string, min: number, max: number): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < min || value > max) {
    throw new HttpError(400, 'invalid_request', `${label} must be an integer from ${min} to ${max}.`);
  }
  return value;
}

function parseText(value: unknown, label: string, maxLength: number, allowEmpty = false): string {
  if (typeof value !== 'string') throw new HttpError(400, 'invalid_request', `${label} must be text.`);
  const text = value.trim();
  if ((!allowEmpty && text.length === 0) || text.length > maxLength) {
    throw new HttpError(400, 'invalid_request', `${label} must be ${allowEmpty ? 'at most' : '1 to'} ${maxLength} characters.`);
  }
  return text;
}

function optionalProfileFields(body: JsonRecord, subjectType?: SubjectType): JsonRecord {
  const result: JsonRecord = {};
  if (Object.hasOwn(body, 'displayName')) {
    result.displayName = body.displayName === null ? null : parseText(body.displayName, 'displayName', 255);
  }
  if (Object.hasOwn(body, 'prefix')) {
    result.prefix = body.prefix === null ? null : parseText(body.prefix, 'prefix', 64, true);
  }
  if (Object.hasOwn(body, 'memberCount')) {
    if (subjectType === 'player' && body.memberCount !== null) {
      throw new HttpError(400, 'invalid_request', 'memberCount is only supported for team subjects.');
    }
    result.memberCount = body.memberCount === null ? null : parseInteger(body.memberCount, 'memberCount', 0, 1_000);
  }
  return result;
}

function queryInteger(url: URL, name: string, fallback: number, min: number, max: number): number {
  if (!url.searchParams.has(name)) return fallback;
  const raw = url.searchParams.get(name);
  if (raw === null || !/^\d+$/.test(raw)) {
    throw new HttpError(400, 'invalid_request', `${name} must be an integer from ${min} to ${max}.`);
  }
  return parseInteger(Number(raw), name, min, max);
}

function querySeason(url: URL): string | null {
  if (!url.searchParams.has('season')) return null;
  const season = url.searchParams.get('season') ?? '';
  if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(season)) {
    throw new HttpError(400, 'invalid_query', 'The season query parameter is invalid.');
  }
  return season;
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value as JsonRecord)
      .filter(([, entryValue]) => entryValue !== undefined)
      .sort(([left], [right]) => left.localeCompare(right));
    return `{${entries.map(([key, entryValue]) => `${JSON.stringify(key)}:${canonical(entryValue)}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function payloadHash(value: unknown): string {
  return createHash('sha256').update(canonical(value), 'utf8').digest('hex');
}

function eventIdFromHeader(request: IncomingMessage): string {
  const raw = request.headers['idempotency-key'];
  if (typeof raw !== 'string') throw new HttpError(400, 'missing_idempotency_key', 'Send an Idempotency-Key UUID.');
  return parseUuid(raw, 'Idempotency-Key');
}

function assertHeaderMatchesBody(eventId: string, bodyId: string): void {
  if (eventId !== bodyId) {
    throw new HttpError(400, 'idempotency_key_mismatch', 'The Idempotency-Key must match the event UUID in the request body.');
  }
}

function clientAddress(request: IncomingMessage): string {
  if (trustProxy) {
    const forwardedFor = request.headers['x-forwarded-for'];
    if (typeof forwardedFor === 'string') {
      const firstAddress = forwardedFor.split(',')[0]?.trim();
      if (firstAddress) return firstAddress.slice(0, 128);
    }
  }
  return request.socket.remoteAddress ?? 'unknown';
}

function enforceRateLimit(response: ServerResponse, key: string, limiter: RateLimiter, requestId: string): boolean {
  const retryAfter = limiter.take(key);
  if (retryAfter === null) return true;
  response.setHeader('Retry-After', String(retryAfter));
  errorResponse(response, 429, 'rate_limited', 'Too many requests. Try again shortly.', requestId);
  return false;
}

async function authenticate(request: IncomingMessage): Promise<ApiKey> {
  const authorization = request.headers.authorization;
  const match = typeof authorization === 'string' ? /^Bearer\s+(\S+)$/i.exec(authorization) : null;
  const token = match?.[1];
  if (!token || !API_KEY_PATTERN.test(token)) {
    throw new HttpError(401, 'unauthorized', 'A valid API key is required.');
  }

  const apiKey = await findApiKey(token);
  if (!apiKey) throw new HttpError(401, 'unauthorized', 'A valid API key is required.');
  return apiKey;
}

function requireScope(apiKey: ApiKey, scope: Scope): void {
  if (!apiKey.scopes.includes(scope)) {
    throw new HttpError(403, 'forbidden', 'This API key does not have permission for this operation.');
  }
}

async function requireReadKey(request: IncomingMessage): Promise<ApiKey> {
  const apiKey = await authenticate(request);
  requireScope(apiKey, 'points:read');
  return apiKey;
}

async function requireLeaderboardKey(request: IncomingMessage): Promise<ApiKey> {
  const apiKey = await authenticate(request);
  requireScope(apiKey, 'leaderboards:read');
  return apiKey;
}

async function requireWriteKey(request: IncomingMessage): Promise<ApiKey> {
  const apiKey = await authenticate(request);
  requireScope(apiKey, 'points:write');
  return apiKey;
}

function eventResult<T extends JsonRecord>(value: T): T & { duplicate: boolean } {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new BackendError();
  }
  return value as T & { duplicate: boolean };
}

function mutationResult(value: JsonRecord, apiKey: ApiKey): JsonRecord {
  const result = eventResult(value);
  if (apiKey.scopes.includes('points:read')) return result;
  return {
    ...(typeof result.eventId === 'string' ? { eventId: result.eventId } : {}),
    duplicate: result.duplicate,
    ...(typeof result.eventSeason === 'string' ? { eventSeason: result.eventSeason } : {}),
    ...(typeof result.currentSeason === 'string' ? { currentSeason: result.currentSeason } : {}),
    ...(typeof result.affectedCount === 'number' ? { affectedCount: result.affectedCount } : {}),
    ...(typeof result.deletedCount === 'number' ? { deletedCount: result.deletedCount } : {}),
  };
}

function snapshotWriteResult(value: JsonRecord, apiKey: ApiKey): JsonRecord {
  if (apiKey.scopes.includes('points:read')) return value;
  return {
    ...(typeof value.insertedCount === 'number' ? { insertedCount: value.insertedCount } : {}),
    ...(typeof value.existingCount === 'number' ? { existingCount: value.existingCount } : {}),
    ...(typeof value.deletedCount === 'number' ? { deletedCount: value.deletedCount } : {}),
  };
}

function accountKeyBucket(apiKey: ApiKey): string {
  return `key:${createHash('sha256').update(apiKey.id).digest('hex')}`;
}

async function requireAccountsReadKey(request: IncomingMessage): Promise<ApiKey> {
  const apiKey = await authenticate(request);
  requireScope(apiKey, 'accounts:read');
  return apiKey;
}

async function requireAccountsWriteKey(request: IncomingMessage): Promise<ApiKey> {
  const apiKey = await authenticate(request);
  requireScope(apiKey, 'accounts:write');
  return apiKey;
}

async function requireTierModerationKey(request: IncomingMessage): Promise<ApiKey> {
  const apiKey = await authenticate(request);
  requireScope(apiKey, 'tiers:moderate');
  return apiKey;
}

async function requireSkinReadKey(request: IncomingMessage): Promise<ApiKey> {
  const apiKey = await authenticate(request);
  if (!apiKey.scopes.includes('accounts:read') && !apiKey.scopes.includes('leaderboards:read')) {
    throw new HttpError(403, 'forbidden', 'This API key does not have permission for this operation.');
  }
  return apiKey;
}

function parseSessionToken(value: unknown, label = 'sessionToken'): { value: string; hash: string } {
  if (typeof value !== 'string' || !/^[0-9a-f]{64}$/i.test(value)) {
    throw new HttpError(400, 'invalid_request', `${label} must be a 32-byte hexadecimal token.`);
  }
  const normalized = value.toLowerCase();
  return { value: normalized, hash: createHash('sha256').update(normalized, 'utf8').digest('hex') };
}

function accountSessionHeaders(request: IncomingMessage): { playerId: string; tokenHash: string } {
  const playerId = parseUuid(request.headers['x-account-player'], 'X-Account-Player');
  const token = parseSessionToken(request.headers['x-account-session'], 'X-Account-Session');
  return { playerId, tokenHash: token.hash };
}

function accountOAuthRedirectUri(): string {
  if (!accountPublicOrigin) throw accountError('account_oauth_disabled');
  return new URL('/v1/accounts/oauth/callback', accountPublicOrigin).toString();
}

const OAUTH_COOKIE = 'strafe_account_oauth_state';

function stateCookie(request: IncomingMessage): string | null {
  const raw = request.headers.cookie;
  if (typeof raw !== 'string') return null;
  const matches = raw.split(';').map((part) => part.trim()).filter((part) => part.startsWith(`${OAUTH_COOKIE}=`));
  if (matches.length !== 1) return null;
  const value = matches[0]?.slice(OAUTH_COOKIE.length + 1) ?? '';
  return /^[0-9a-f-]{36}\.(old|new)\.[0-9a-f]{64}$/.test(value) ? value : null;
}

function safeEqualText(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left, 'utf8');
  const rightBytes = Buffer.from(right, 'utf8');
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}

function clearOAuthCookie(request: IncomingMessage, response: ServerResponse): void {
  const secure = accountPublicOrigin?.protocol === 'https:' ? '; Secure' : '';
  response.setHeader('Set-Cookie', `${OAUTH_COOKIE}=; Path=/v1/accounts/oauth/callback; Max-Age=0; HttpOnly; SameSite=Lax${secure}`);
}

async function startAccountOAuth(url: URL, response: ServerResponse): Promise<void> {
  if (!accountOAuthEnabled || !accountPublicOrigin) throw accountError('account_oauth_disabled');
  const requestId = parseUuid(url.searchParams.get('requestId'), 'requestId');
  const step = url.searchParams.get('step');
  if (step !== 'old' && step !== 'new') throw new HttpError(400, 'invalid_request', 'step must be old or new.');
  const state = `${requestId}.${step}.${randomBytes(32).toString('hex')}`;
  const stateHash = createHash('sha256').update(state, 'utf8').digest('hex');
  accountResult(await rpc<JsonRecord>('begin_account_oauth', {
    p_request_id: requestId,
    p_step: step,
    p_state_hash: stateHash,
  }));

  const authorizeUrl = new URL('https://discord.com/oauth2/authorize');
  authorizeUrl.searchParams.set('client_id', discordClientId);
  authorizeUrl.searchParams.set('redirect_uri', accountOAuthRedirectUri());
  authorizeUrl.searchParams.set('response_type', 'code');
  authorizeUrl.searchParams.set('scope', 'identify');
  authorizeUrl.searchParams.set('state', state);
  authorizeUrl.searchParams.set('prompt', 'consent');
  const secure = accountPublicOrigin.protocol === 'https:' ? '; Secure' : '';
  response.writeHead(302, {
    Location: authorizeUrl.toString(),
    'Set-Cookie': `${OAUTH_COOKIE}=${state}; Path=/v1/accounts/oauth/callback; Max-Age=600; HttpOnly; SameSite=Lax${secure}`,
    'Cache-Control': 'no-store',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
  });
  response.end();
}

async function exchangeDiscordCode(code: string): Promise<{ id: string; displayName: string }> {
  if (!accountOAuthEnabled) throw accountError('account_oauth_disabled');
  const redirectUri = accountOAuthRedirectUri();
  const controller = AbortSignal.timeout(8_000);
  const tokenResponse = await fetch('https://discord.com/api/v10/oauth2/token', {
    method: 'POST',
    redirect: 'error',
    signal: controller,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
    body: new URLSearchParams({
      client_id: discordClientId,
      client_secret: discordClientSecret,
      grant_type: 'authorization_code',
      code,
      redirect_uri: redirectUri,
    }),
  });
  if (!tokenResponse.ok) throw accountError('discord_oauth_failed');
  const tokenBody: unknown = await tokenResponse.json().catch(() => null);
  if (tokenBody === null || typeof tokenBody !== 'object' || typeof (tokenBody as JsonRecord).access_token !== 'string') {
    throw accountError('discord_oauth_failed');
  }
  const accessToken = (tokenBody as JsonRecord).access_token as string;
  const userResponse = await fetch('https://discord.com/api/v10/users/@me', {
    redirect: 'error',
    signal: controller,
    headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' },
  });
  if (!userResponse.ok) throw accountError('discord_oauth_failed');
  const user: unknown = await userResponse.json().catch(() => null);
  if (user === null || typeof user !== 'object') throw accountError('discord_oauth_failed');
  const userRecord = user as JsonRecord;
  const id = typeof userRecord.id === 'string' ? userRecord.id : '';
  const displayName = typeof userRecord.global_name === 'string' && userRecord.global_name.trim()
    ? userRecord.global_name.trim()
    : typeof userRecord.username === 'string' ? userRecord.username.trim() : '';
  if (!/^[0-9]{17,20}$/.test(id) || displayName.length < 1 || displayName.length > 100) {
    throw accountError('discord_oauth_failed');
  }
  return { id, displayName };
}

async function finishAccountOAuth(url: URL, request: IncomingMessage, response: ServerResponse): Promise<void> {
  if (!accountOAuthEnabled) throw accountError('account_oauth_disabled');
  const error = url.searchParams.get('error');
  if (error) {
    clearOAuthCookie(request, response);
    sendHtml(response, 400, '<!doctype html><meta charset="utf-8"><title>Discord link cancelled</title><p>Discord authorization was cancelled. Return to Minecraft and try again.</p>');
    return;
  }
  const state = url.searchParams.get('state') ?? '';
  const code = url.searchParams.get('code') ?? '';
  const cookie = stateCookie(request);
  if (!cookie || !/^[0-9a-f-]{36}\.(old|new)\.[0-9a-f]{64}$/.test(state)
    || !safeEqualText(cookie, state) || !/^[A-Za-z0-9._-]{1,512}$/.test(code)) {
    clearOAuthCookie(request, response);
    throw accountError('oauth_state_invalid');
  }
  const [, requestIdRaw, stepRaw] = state.match(/^([0-9a-f-]{36})\.(old|new)\.[0-9a-f]{64}$/) ?? [];
  const requestId = parseUuid(requestIdRaw, 'requestId');
  const step = stepRaw;
  const stateHash = createHash('sha256').update(state, 'utf8').digest('hex');
  const discord = await exchangeDiscordCode(code);
  const result = accountResult(await rpc<JsonRecord>('finish_account_oauth', {
    p_request_id: requestId,
    p_step: step,
    p_state_hash: stateHash,
    p_discord_id: discord.id,
    p_display_name: discord.displayName,
  }));
  clearOAuthCookie(request, response);
  if (result.status === 'awaiting_new_discord') {
    const nextUrl = new URL('/v1/accounts/oauth/start', accountPublicOrigin!);
    nextUrl.searchParams.set('requestId', requestId);
    nextUrl.searchParams.set('step', 'new');
    sendHtml(response, 200, `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Verify replacement Discord</title><p>Your existing Discord account is verified. Continue with the replacement Discord account, then confirm from the active Minecraft session.</p><p><a href="${nextUrl.toString()}">Continue to Discord</a></p>`);
    return;
  }
  sendHtml(response, 200, '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Discord verified</title><p>Discord verification is complete. Return to Minecraft and confirm the account link in game.</p>');
}

async function readLimitedBody(response: Response, maxBytes: number): Promise<Buffer> {
  const declaredLength = Number(response.headers.get('content-length') ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) throw new Error('response too large');
  if (!response.body) throw new Error('empty response');
  const reader = response.body.getReader();
  const chunks: Buffer[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel();
      throw new Error('response too large');
    }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks, size);
}

async function skinPiece(
  source: Buffer,
  crop: { left: number; top: number; width: number; height: number },
  resize: { width: number; height: number },
  mirror = false,
): Promise<Buffer> {
  let image = sharp(source, { limitInputPixels: 4096 }).extract(crop);
  if (mirror) image = image.flop();
  return image.resize(resize.width, resize.height, { kernel: 'nearest' }).png().toBuffer();
}

async function renderPortrait(skinPng: Buffer, model: 'classic' | 'slim'): Promise<Buffer> {
  const metadata = await sharp(skinPng, { limitInputPixels: 4096 }).metadata();
  if (metadata.format !== 'png' || metadata.width !== 64 || (metadata.height !== 64 && metadata.height !== 32)) {
    throw new Error('invalid texture dimensions');
  }
  const legacy = metadata.height === 32;
  const source = legacy
    ? await sharp(skinPng).extend({ top: 0, bottom: 32, left: 0, right: 0, background: { r: 0, g: 0, b: 0, alpha: 0 } }).png().toBuffer()
    : skinPng;
  const armPixels = model === 'slim' ? 3 : 4;
  const armWidth = armPixels * 10;
  const armLeft = 40 - armWidth;
  const armRight = 120;
  const bodyTop = 80;
  const legTop = 200;
  const parts: Array<{ crop: { left: number; top: number; width: number; height: number }; resize: { width: number; height: number }; left: number; top: number; mirror?: boolean }> = [
    { crop: { left: 8, top: 8, width: 8, height: 8 }, resize: { width: 80, height: 80 }, left: 40, top: 0 },
    { crop: { left: 20, top: 20, width: 8, height: 12 }, resize: { width: 80, height: 120 }, left: 40, top: bodyTop },
    { crop: { left: 4, top: 20, width: 4, height: 12 }, resize: { width: 40, height: 120 }, left: 40, top: legTop },
    { crop: { left: legacy ? 4 : 20, top: legacy ? 20 : 52, width: 4, height: 12 }, resize: { width: 40, height: 120 }, left: 80, top: legTop, mirror: legacy },
    { crop: { left: 44, top: 20, width: armPixels, height: 12 }, resize: { width: armWidth, height: 120 }, left: armLeft, top: bodyTop },
    { crop: { left: legacy ? 44 : 36, top: legacy ? 20 : 52, width: armPixels, height: 12 }, resize: { width: armWidth, height: 120 }, left: armRight, top: bodyTop, mirror: legacy },
    { crop: { left: 40, top: 8, width: 8, height: 8 }, resize: { width: 80, height: 80 }, left: 40, top: 0 },
    { crop: { left: 20, top: 36, width: 8, height: 12 }, resize: { width: 80, height: 120 }, left: 40, top: bodyTop },
    { crop: { left: 4, top: 36, width: 4, height: 12 }, resize: { width: 40, height: 120 }, left: 40, top: legTop },
    { crop: { left: 52, top: 52, width: armPixels, height: 12 }, resize: { width: armWidth, height: 120 }, left: armRight, top: bodyTop },
    { crop: { left: 44, top: 36, width: armPixels, height: 12 }, resize: { width: armWidth, height: 120 }, left: armLeft, top: bodyTop },
  ];
  if (!legacy) parts.push({
    crop: { left: 4, top: 52, width: 4, height: 12 }, resize: { width: 40, height: 120 }, left: 80, top: legTop,
  });
  const visibleParts = legacy ? parts.slice(0, 6) : parts;
  const composite = await Promise.all(visibleParts.map(async ({ crop, resize, left, top, mirror }) => ({
    input: await skinPiece(source, crop, resize, mirror), left, top,
  })));
  return sharp({
    create: { width: 160, height: 320, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite(composite).png().toBuffer();
}

async function generatePortrait(textureHash: string, model: 'classic' | 'slim'): Promise<Buffer> {
  const path = resolve(portraitCacheDirectory, `${textureHash}-${model}.png`);
  try {
    const cached = await readFile(path);
    const metadata = await sharp(cached, { limitInputPixels: 160 * 320 }).metadata();
    if (metadata.format === 'png' && metadata.width === 160 && metadata.height === 320) return cached;
  } catch {
    // A partial or old cache entry is regenerated from the fixed Mojang texture host below.
  }
  if (activePortraitFetches >= 8) throw new Error('portrait generation limit reached');
  activePortraitFetches += 1;
  let portrait: Buffer;
  try {
    const upstream = await fetch(`https://textures.minecraft.net/texture/${textureHash}`, {
      redirect: 'error',
      signal: AbortSignal.timeout(8_000),
      headers: { Accept: 'image/png' },
    });
    if (!upstream.ok || upstream.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'image/png') {
      throw new Error('texture fetch rejected');
    }
    const source = await readLimitedBody(upstream, 1024 * 1024);
    portrait = await renderPortrait(source, model);
  } finally {
    activePortraitFetches -= 1;
  }
  await mkdir(portraitCacheDirectory, { recursive: true });
  portraitCacheWrites += 1;
  if (portraitCacheWrites % 32 === 0 || Date.now() - lastPortraitPruneAt > 10 * 60 * 1000) {
    await prunePortraitCache();
    lastPortraitPruneAt = Date.now();
  }
  const temporaryPath = `${path}.${randomUUID()}.tmp`;
  await writeFile(temporaryPath, portrait, { flag: 'wx' });
  await rename(temporaryPath, path).catch(async (error: unknown) => {
    await unlink(temporaryPath).catch(() => undefined);
    // A concurrent renderer may have written the same immutable cache entry first.
    try {
      const existing = await readFile(path);
      const metadata = await sharp(existing, { limitInputPixels: 160 * 320 }).metadata();
      if (metadata.format === 'png' && metadata.width === 160 && metadata.height === 320) return;
    } catch {
      throw error;
    }
  });
  return portrait;
}

async function prunePortraitCache(): Promise<void> {
  const entries = await readdir(portraitCacheDirectory, { withFileTypes: true }).catch(() => []);
  const now = Date.now();
  for (const entry of entries.filter((candidate) => candidate.isFile() && candidate.name.endsWith('.tmp'))) {
    const path = resolve(portraitCacheDirectory, entry.name);
    const details = await stat(path).catch(() => null);
    if (details && now - details.mtimeMs > 60 * 60 * 1000) await unlink(path).catch(() => undefined);
  }
  const pngFiles = entries.filter((entry) => entry.isFile() && /^[0-9a-f]{40,64}-(classic|slim)\.png$/.test(entry.name));
  if (pngFiles.length <= 10_000) return;
  const dated = await Promise.all(pngFiles.map(async (entry) => {
    const path = resolve(portraitCacheDirectory, entry.name);
    const details = await stat(path).catch(() => null);
    return details ? { path, mtime: details.mtimeMs } : null;
  }));
  const oldest = dated.filter((entry): entry is { path: string; mtime: number } => entry !== null)
    .sort((left, right) => left.mtime - right.mtime);
  for (const entry of oldest.slice(0, Math.max(0, oldest.length - 9_000))) {
    await unlink(entry.path).catch(() => undefined);
  }
}

async function getPortrait(textureHash: string, model: 'classic' | 'slim'): Promise<Buffer> {
  const key = `${textureHash}-${model}`;
  let pending = pendingPortraits.get(key);
  if (!pending) {
    pending = generatePortrait(textureHash, model);
    pendingPortraits.set(key, pending);
  }
  try {
    return await pending;
  } finally {
    if (pendingPortraits.get(key) === pending) pendingPortraits.delete(key);
  }
}

async function hasRegisteredPortrait(textureHash: string, model: 'classic' | 'slim'): Promise<boolean> {
  const key = `${textureHash}-${model}`;
  const now = Date.now();
  const cached = portraitRegistrationCache.get(key);
  const ttlMs = cached?.registered ? 30_000 : 3_000;
  if (cached && now - cached.checkedAt < ttlMs) {
    portraitRegistrationCache.delete(key);
    portraitRegistrationCache.set(key, cached);
    return cached.registered;
  }
  let pending = pendingPortraitRegistrations.get(key);
  if (!pending) {
    pending = rpc<boolean>('has_account_portrait', { p_texture_hash: textureHash, p_model: model });
    pendingPortraitRegistrations.set(key, pending);
  }
  let registered: boolean;
  try {
    registered = await pending;
  } finally {
    if (pendingPortraitRegistrations.get(key) === pending) pendingPortraitRegistrations.delete(key);
  }
  portraitRegistrationCache.delete(key);
  portraitRegistrationCache.set(key, { checkedAt: now, registered });
  while (portraitRegistrationCache.size > 2_000) {
    const oldestKey = portraitRegistrationCache.keys().next().value as string | undefined;
    if (!oldestKey) break;
    portraitRegistrationCache.delete(oldestKey);
  }
  return registered;
}

function parseCanonicalTexture(textureValue: unknown, textureSignature: unknown): {
  textureHash: string; model: 'classic' | 'slim'; value: string; signature: string; fingerprint: string;
} {
  if (typeof textureValue !== 'string' || textureValue.length < 8 || textureValue.length > 8192
    || !/^[A-Za-z0-9+/]+={0,2}$/.test(textureValue)
    || typeof textureSignature !== 'string' || textureSignature.length < 8 || textureSignature.length > 8192
    || !/^[A-Za-z0-9+/]+={0,2}$/.test(textureSignature)) {
    throw new HttpError(400, 'invalid_texture', 'The skin resolver returned an invalid signed texture.');
  }
  let decoded: unknown;
  try {
    const bytes = Buffer.from(textureValue, 'base64');
    if (bytes.toString('base64').replace(/=+$/, '') !== textureValue.replace(/=+$/, '')) throw new Error();
    decoded = JSON.parse(bytes.toString('utf8'));
  } catch {
    throw new HttpError(400, 'invalid_texture', 'The skin resolver returned an invalid signed texture.');
  }
  if (decoded === null || typeof decoded !== 'object') throw new HttpError(400, 'invalid_texture', 'The skin resolver returned an invalid signed texture.');
  const textures = (decoded as JsonRecord).textures;
  if (textures === null || typeof textures !== 'object' || Array.isArray(textures)) throw new HttpError(400, 'invalid_texture', 'The skin resolver returned an invalid signed texture.');
  const skin = (textures as JsonRecord).SKIN;
  if (skin === null || typeof skin !== 'object' || Array.isArray(skin)) throw new HttpError(400, 'invalid_texture', 'The skin resolver returned an invalid signed texture.');
  const url = (skin as JsonRecord).url;
  if (typeof url !== 'string') throw new HttpError(400, 'invalid_texture', 'The skin resolver returned an invalid signed texture.');
  let parsedUrl: URL;
  try { parsedUrl = new URL(url); } catch { throw new HttpError(400, 'invalid_texture', 'The skin resolver returned an invalid signed texture.'); }
  const textureMatch = /^\/texture\/([0-9a-f]{40,64})$/i.exec(parsedUrl.pathname);
  if (!['https:', 'http:'].includes(parsedUrl.protocol) || parsedUrl.hostname !== 'textures.minecraft.net'
      || parsedUrl.port || parsedUrl.username || parsedUrl.password || parsedUrl.search || parsedUrl.hash || !textureMatch) {
    throw new HttpError(400, 'invalid_texture', 'The skin resolver returned a texture outside the approved Minecraft texture host.');
  }
  const metadata = (skin as JsonRecord).metadata;
  const modelValue = metadata !== null && typeof metadata === 'object' ? (metadata as JsonRecord).model : undefined;
  if (modelValue !== undefined && modelValue !== 'slim' && modelValue !== 'classic') {
    throw new HttpError(400, 'invalid_texture', 'The skin resolver returned an unsupported skin model.');
  }
  const value = textureValue;
  const signature = textureSignature;
  return {
    textureHash: (textureMatch[1] ?? '').toLowerCase(),
    model: modelValue === 'slim' ? 'slim' : 'classic',
    value,
    signature,
    fingerprint: payloadHash({ textureValue: value, textureSignature: signature }),
  };
}

function accountStatusName(status: unknown): unknown {
  if (typeof status !== 'string') return status;
  return status === 'awaiting_minecraft_confirmation' ? 'awaiting_confirmation' : status;
}

async function routeRequest(request: IncomingMessage, response: ServerResponse, requestId: string): Promise<void> {
  const host = request.headers.host ?? 'localhost';
  const url = new URL(request.url ?? '/', `http://${host}`);
  const method = request.method ?? 'GET';
  const pathname = url.pathname.replace(/\/$/, '') || '/';

  if (method === 'GET' && (pathname === '/healthz' || pathname === '/health')) {
    sendJson(response, 200, { status: 'ok' });
    return;
  }

  if (method === 'GET' && pathname === '/readyz') {
    if (!enforceRateLimit(response, clientAddress(request), ipLimiter, requestId)) return;
    await checkDatabaseReady();
    sendJson(response, 200, { status: 'ready' });
    return;
  }

  if (!pathname.startsWith('/v1/')) {
    throw new HttpError(404, 'not_found', 'The requested route was not found.');
  }

  if (!enforceRateLimit(response, clientAddress(request), ipLimiter, requestId)) return;

  if (method === 'GET' && pathname === '/v1/accounts/oauth/start') {
    await startAccountOAuth(url, response);
    return;
  }

  if (method === 'GET' && pathname === '/v1/accounts/oauth/callback') {
    await finishAccountOAuth(url, request, response);
    return;
  }

  const portraitMatch = /^\/v1\/accounts\/portraits\/([0-9a-f]{40,64})\/(classic|slim)\.png$/i.exec(pathname);
  if (method === 'GET' && portraitMatch) {
    if (!enforceRateLimit(response, clientAddress(request), portraitLimiter, requestId)) return;
    const textureHash = (portraitMatch[1] ?? '').toLowerCase();
    const model = portraitMatch[2]?.toLowerCase() as 'classic' | 'slim';
    const registered = await hasRegisteredPortrait(textureHash, model);
    if (!registered) throw new HttpError(404, 'portrait_not_found', 'The requested account portrait was not found.');
    let portrait: Buffer;
    try {
      portrait = await getPortrait(textureHash, model);
    } catch {
      throw new BackendError();
    }
    response.writeHead(200, {
      'Content-Type': 'image/png',
      'Content-Length': portrait.byteLength,
      'Cache-Control': 'public, max-age=31536000, immutable',
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
    });
    response.end(portrait);
    return;
  }

  if (method === 'GET' && pathname === '/v1/accounts/skins') {
    const apiKey = await requireSkinReadKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const rawIds = url.searchParams.get('ids');
    if (!rawIds) throw new HttpError(400, 'invalid_query', 'ids must contain between 1 and 100 UUIDs.');
    const idValues = rawIds.split(',');
    if (idValues.length < 1 || idValues.length > 100) throw new HttpError(400, 'invalid_query', 'ids must contain between 1 and 100 UUIDs.');
    const playerIds = idValues.map((value, index) => parseUuid(value, `ids[${index}]`));
    if (new Set(playerIds).size !== playerIds.length) throw new HttpError(400, 'invalid_query', 'ids cannot contain duplicate UUIDs.');
    const result = await rpc<JsonRecord>('get_account_skins', { p_key_hash: apiKey.key_hash, p_player_ids: playerIds });
    const rawSkins = result.skins;
    if (rawSkins === null || typeof rawSkins !== 'object' || Array.isArray(rawSkins)) throw new BackendError();
    const skins: JsonRecord = {};
    for (const [playerId, rawSkin] of Object.entries(rawSkins as JsonRecord)) {
      if (rawSkin === null || typeof rawSkin !== 'object' || Array.isArray(rawSkin)) continue;
      const skin = rawSkin as JsonRecord;
      if (typeof skin.textureUrl !== 'string' || typeof skin.portraitPath !== 'string'
        || (skin.model !== 'classic' && skin.model !== 'slim')) continue;
      skins[playerId.toLowerCase()] = {
        model: skin.model,
        textureUrl: skin.textureUrl,
        portraitUrl: publicAccountUrl(skin.portraitPath),
      };
    }
    sendJson(response, 200, { skins });
    return;
  }

  const linkStatusMatch = /^\/v1\/accounts\/link\/([^/]+)$/.exec(pathname);
  if (method === 'GET' && linkStatusMatch) {
    const apiKey = await requireAccountsWriteKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const { playerId, tokenHash } = accountSessionHeaders(request);
    const linkRequestId = parseUuid(decodeURIComponent(linkStatusMatch[1] ?? ''), 'requestId');
    const result = accountResult(await rpc<JsonRecord>('get_account_link', {
      p_key_hash: apiKey.key_hash,
      p_player_id: playerId,
      p_session_token_hash: tokenHash,
      p_request_id: linkRequestId,
    }));
    result.status = accountStatusName(result.status);
    sendJson(response, 200, result);
    return;
  }

  const skinStatusMatch = /^\/v1\/accounts\/([^/]+)$/.exec(pathname);
  if (method === 'GET' && skinStatusMatch) {
    const apiKey = await requireAccountsReadKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    let decodedPlayerId: string;
    try { decodedPlayerId = decodeURIComponent(skinStatusMatch[1] ?? ''); }
    catch { throw new HttpError(400, 'invalid_request', 'playerId must be a UUID.'); }
    const playerId = parseUuid(decodedPlayerId, 'playerId');
    const result = requireTierStatus(await rpc<JsonRecord>('get_account', { p_key_hash: apiKey.key_hash, p_player_id: playerId }));
    sendJson(response, 200, withPublicAccountUrls(result));
    return;
  }

  if (method === 'POST' && pathname === '/v1/accounts/session') {
    const apiKey = await requireAccountsWriteKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const body = await readJson(request);
    const playerId = parseUuid(body.playerId, 'playerId');
    const playerName = parseText(body.playerName, 'playerName', 16);
    if (!/^[A-Za-z0-9_]{1,16}$/.test(playerName)) throw new HttpError(400, 'invalid_request', 'playerName must be a Minecraft username.');
    if (typeof body.premium !== 'boolean') throw new HttpError(400, 'invalid_request', 'premium must be a boolean verified by the proxy.');
    const session = parseSessionToken(body.sessionToken);
    const sessionStartedAt = parseInteger(body.sessionStartedAt, 'sessionStartedAt', 0, 8_640_000_000_000_000);
    const result = requireTierStatus(accountResult(await rpc<JsonRecord>('account_session_upsert', {
      p_key_hash: apiKey.key_hash,
      p_player_id: playerId,
      p_player_name: playerName,
      p_premium: body.premium,
      p_session_token_hash: session.hash,
      p_session_started_at: new Date(sessionStartedAt).toISOString(),
      p_ttl_seconds: accountSessionTtlSeconds,
    })));
    sendJson(response, 200, withPublicAccountUrls(result));
    return;
  }

  if (method === 'POST' && pathname === '/v1/accounts/session/end') {
    const apiKey = await requireAccountsWriteKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const body = await readJson(request);
    const playerId = parseUuid(body.playerId, 'playerId');
    const session = parseSessionToken(body.sessionToken);
    const result = await rpc<JsonRecord>('account_session_end', {
      p_key_hash: apiKey.key_hash,
      p_player_id: playerId,
      p_session_token_hash: session.hash,
    });
    sendJson(response, 200, result);
    return;
  }

  if (method === 'POST' && pathname === '/v1/accounts/link') {
    const apiKey = await requireAccountsWriteKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    if (!accountOAuthEnabled || !accountPublicOrigin) throw accountError('account_oauth_disabled');
    const body = await readJson(request);
    const playerId = parseUuid(body.playerId, 'playerId');
    const session = parseSessionToken(body.sessionToken);
    if (body.purpose !== 'link' && body.purpose !== 'change') throw new HttpError(400, 'invalid_request', 'purpose must be link or change.');
    const result = accountResult(await rpc<JsonRecord>('start_account_link', {
      p_key_hash: apiKey.key_hash,
      p_player_id: playerId,
      p_session_token_hash: session.hash,
      p_purpose: body.purpose,
    }));
    const oauthUrl = new URL('/v1/accounts/oauth/start', accountPublicOrigin);
    oauthUrl.searchParams.set('requestId', String(result.requestId));
    oauthUrl.searchParams.set('step', body.purpose === 'change' ? 'old' : 'new');
    result.url = oauthUrl.toString();
    sendJson(response, 201, result);
    return;
  }

  const linkConfirmMatch = /^\/v1\/accounts\/link\/([^/]+)\/confirm$/.exec(pathname);
  if (method === 'POST' && linkConfirmMatch) {
    const apiKey = await requireAccountsWriteKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const body = await readJson(request);
    const playerId = parseUuid(body.playerId, 'playerId');
    const session = parseSessionToken(body.sessionToken);
    const linkRequestId = parseUuid(decodeURIComponent(linkConfirmMatch[1] ?? ''), 'requestId');
    const result = accountResult(await rpc<JsonRecord>('confirm_account_link', {
      p_key_hash: apiKey.key_hash,
      p_player_id: playerId,
      p_session_token_hash: session.hash,
      p_request_id: linkRequestId,
    }));
    result.status = accountStatusName(result.status);
    sendJson(response, 200, result);
    return;
  }

  if (method === 'POST' && pathname === '/v1/accounts/skin/prepare') {
    const apiKey = await requireAccountsWriteKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const body = await readJson(request);
    const playerId = parseUuid(body.playerId, 'playerId');
    const session = parseSessionToken(body.sessionToken);
    const skinRequestId = parseUuid(body.requestId, 'requestId');
    const input = parseText(body.input, 'input', 2048);
    const result = accountResult(await rpc<JsonRecord>('prepare_account_skin', {
      p_key_hash: apiKey.key_hash,
      p_player_id: playerId,
      p_session_token_hash: session.hash,
      p_request_id: skinRequestId,
      p_input: input,
    }));
    if (result.status === undefined) result.status = 'reserved';
    sendJson(response, 200, result);
    return;
  }

  if (method === 'POST' && pathname === '/v1/accounts/skin/commit') {
    const apiKey = await requireAccountsWriteKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const body = await readJson(request);
    const playerId = parseUuid(body.playerId, 'playerId');
    const session = parseSessionToken(body.sessionToken);
    const skinRequestId = parseUuid(body.requestId, 'requestId');
    let texture: ReturnType<typeof parseCanonicalTexture>;
    try {
      texture = parseCanonicalTexture(body.textureValue, body.textureSignature);
    } catch (error) {
      await rpc<JsonRecord>('cancel_account_skin', {
        p_key_hash: apiKey.key_hash, p_player_id: playerId, p_session_token_hash: session.hash, p_request_id: skinRequestId,
      }).catch(() => null);
      throw error;
    }
    const result = accountResult(await rpc<JsonRecord>('commit_account_skin', {
      p_key_hash: apiKey.key_hash,
      p_player_id: playerId,
      p_session_token_hash: session.hash,
      p_request_id: skinRequestId,
      p_texture_hash: texture.textureHash,
      p_model: texture.model,
      p_texture_value: texture.value,
      p_texture_signature: texture.signature,
      p_fingerprint: texture.fingerprint,
    }));
    if (result.status === undefined) result.status = 'completed';
    sendJson(response, 200, withPublicAccountUrls(result));
    return;
  }

  if (method === 'POST' && pathname === '/v1/accounts/skin/cancel') {
    const apiKey = await requireAccountsWriteKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const body = await readJson(request);
    const playerId = parseUuid(body.playerId, 'playerId');
    const session = parseSessionToken(body.sessionToken);
    const skinRequestId = parseUuid(body.requestId, 'requestId');
    const result = accountResult(await rpc<JsonRecord>('cancel_account_skin', {
      p_key_hash: apiKey.key_hash,
      p_player_id: playerId,
      p_session_token_hash: session.hash,
      p_request_id: skinRequestId,
    }));
    sendJson(response, 200, result);
    return;
  }

  if (method === 'POST' && pathname === '/v1/accounts/admin/recover') {
    const apiKey = await authenticate(request);
    requireScope(apiKey, 'accounts:admin');
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const body = await readJson(request);
    const playerId = parseUuid(body.playerId, 'playerId');
    const discordId = parseText(body.discordId, 'discordId', 20);
    if (!/^[0-9]{17,20}$/.test(discordId)) throw new HttpError(400, 'invalid_request', 'discordId must be a Discord snowflake.');
    const displayName = parseText(body.discordDisplayName, 'discordDisplayName', 100);
    const reason = parseText(body.reason, 'reason', 500);
    const result = accountResult(await rpc<JsonRecord>('admin_recover_account_link', {
      p_key_hash: apiKey.key_hash,
      p_player_id: playerId,
      p_discord_id: discordId,
      p_display_name: displayName,
      p_reason: reason,
    }));
    sendJson(response, 200, result);
    return;
  }

  if (method === 'GET' && pathname === '/v1/tiers/status') {
    const apiKey = await requireAccountsReadKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const ids = url.searchParams.getAll('ids');
    if (ids.length !== 1 || [...url.searchParams.keys()].some((key) => key !== 'ids')) {
      throw new HttpError(400, 'invalid_query', 'Provide one ids query parameter.');
    }
    const values = ids[0]?.split(',') ?? [];
    if (values.length < 1 || values.length > 100) {
      throw new HttpError(400, 'invalid_query', 'ids must contain between 1 and 100 UUIDs.');
    }
    const playerIds = values.map((value, index) => parseUuid(value, `ids[${index}]`));
    if (new Set(playerIds).size !== playerIds.length) {
      throw new HttpError(400, 'invalid_query', 'ids cannot contain duplicate UUIDs.');
    }
    const result = await rpc<JsonRecord>('get_tier_ban_statuses', {
      p_key_hash: apiKey.key_hash,
      p_player_ids: playerIds,
    });
    if (result.bans === null || typeof result.bans !== 'object' || Array.isArray(result.bans)) throw new BackendError();
    const rawBans = result.bans as JsonRecord;
    const bans: Record<string, boolean> = {};
    for (const playerId of playerIds) {
      if (typeof rawBans[playerId] !== 'boolean') throw new BackendError();
      bans[playerId] = rawBans[playerId] as boolean;
    }
    sendJson(response, 200, { bans });
    return;
  }

  if (method === 'GET' && pathname === '/v1/tiers/players') {
    const apiKey = await requireTierModerationKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const names = url.searchParams.getAll('name');
    if (names.length !== 1 || [...url.searchParams.keys()].some((key) => key !== 'name')) {
      throw new HttpError(400, 'invalid_query', 'Provide one name query parameter.');
    }
    const playerName = parseText(names[0], 'name', 16);
    if (!/^[A-Za-z0-9_]{1,16}$/.test(playerName)) {
      throw new HttpError(400, 'invalid_query', 'name must be a Minecraft username.');
    }
    const result = await rpc<JsonRecord>('get_tier_players', { p_key_hash: apiKey.key_hash, p_name: playerName });
    if (!Array.isArray(result.matches)) throw new BackendError();
    const matches: Array<{ playerId: string; playerName: string }> = [];
    for (const match of result.matches) {
      if (match === null || typeof match !== 'object' || Array.isArray(match)) throw new BackendError();
      const row = match as JsonRecord;
      if (typeof row.playerId !== 'string' || !UUID_PATTERN.test(row.playerId)
        || typeof row.playerName !== 'string' || !/^[A-Za-z0-9_]{1,16}$/.test(row.playerName)) throw new BackendError();
      matches.push({ playerId: row.playerId.toLowerCase(), playerName: row.playerName });
    }
    if (matches.length === 0) throw new HttpError(404, 'player_not_found', 'No matching Minecraft account was found.');
    if (matches.length > 1) {
      throw new HttpError(409, 'ambiguous_player_name', 'More than one Minecraft account matches that name.', { matches });
    }
    sendJson(response, 200, { matches });
    return;
  }

  if (method === 'POST' && (pathname === '/v1/tiers/ban' || pathname === '/v1/tiers/unban')) {
    const apiKey = await requireTierModerationKey(request);
    if (!enforceRateLimit(response, accountKeyBucket(apiKey), keyLimiter, requestId)) return;
    const body = await readJson(request);
    const playerId = parseUuid(body.playerId, 'playerId');
    const actor = parseText(body.actor, 'actor', 64);
    if (!/^[A-Za-z0-9_ .:@/-]{1,64}$/.test(actor)) {
      throw new HttpError(400, 'invalid_request', 'actor contains unsupported characters.');
    }
    const banned = pathname === '/v1/tiers/ban';
    const raw = await rpc<JsonRecord>('moderate_tier_ban', {
      p_key_hash: apiKey.key_hash,
      p_player_id: playerId,
      p_actor: actor,
      p_banned: banned,
    });
    if (raw.playerId !== playerId || typeof raw.banned !== 'boolean' || raw.banned !== banned
      || typeof raw.changed !== 'boolean' || typeof raw.tiersBanned !== 'boolean'
      || (raw.playerName !== null && (typeof raw.playerName !== 'string' || !/^[A-Za-z0-9_]{1,16}$/.test(raw.playerName)))) {
      throw new BackendError();
    }
    sendJson(response, 200, {
      playerId,
      playerName: raw.playerName,
      banned: raw.banned,
      changed: raw.changed,
      tiersBanned: raw.tiersBanned,
    });
    return;
  }

  if (method === 'GET' && pathname === '/v1/leaderboards/seasons') {
    const apiKey = await requireLeaderboardKey(request);
    if (!enforceRateLimit(response, `key:${createHash('sha256').update(apiKey.id).digest('hex')}`, keyLimiter, requestId)) return;
    const result = await rpc<JsonRecord>('get_smp_leaderboard_seasons', { p_key_hash: apiKey.key_hash });
    sendJson(response, 200, result);
    return;
  }

  if (method === 'GET' && pathname.startsWith('/v1/leaderboards/')) {
    const mode = pathname.slice('/v1/leaderboards/'.length);
    if (!['smp-teams', 'smp-solo', 'pvp'].includes(mode)) {
      throw new HttpError(404, 'not_found', 'The requested leaderboard was not found.');
    }
    const apiKey = await requireLeaderboardKey(request);
    if (!enforceRateLimit(response, `key:${createHash('sha256').update(apiKey.id).digest('hex')}`, keyLimiter, requestId)) return;
    const requestedLimit = queryInteger(url, 'limit', 50, 1, 100);
    const offset = queryInteger(url, 'offset', 0, 0, 10_000);
    const season = querySeason(url);
    if (mode === 'pvp') {
      sendJson(response, 200, { mode, limit: requestedLimit, offset, total: 0, nextOffset: null, items: [] });
      return;
    }
    const subjectType: SubjectType = mode === 'smp-teams' ? 'team' : 'player';
    const result = await rpc<JsonRecord>('get_points_leaderboard_for_season', {
      p_key_hash: apiKey.key_hash,
      p_subject_type: subjectType,
      p_limit: requestedLimit,
      p_offset: offset,
      p_mode: mode,
      p_season: season,
    });
    sendJson(response, 200, result);
    return;
  }

  if (method === 'GET' && pathname === '/v1/points/snapshot') {
    const apiKey = await requireReadKey(request);
    if (!enforceRateLimit(response, `key:${createHash('sha256').update(apiKey.id).digest('hex')}`, keyLimiter, requestId)) return;
    const subjectType = parseSubjectType(url.searchParams.get('subjectType'));
    const limit = queryInteger(url, 'limit', SNAPSHOT_BATCH_MAX, 1, SNAPSHOT_BATCH_MAX);
    const after = url.searchParams.has('after') ? parseUuid(url.searchParams.get('after'), 'after') : null;
    const result = await rpc<JsonRecord>('get_points_snapshot', {
      p_key_hash: apiKey.key_hash,
      p_subject_type: subjectType,
      p_limit: limit,
      p_after: after,
    });
    sendJson(response, 200, result);
    return;
  }

  const balanceMatch = /^\/v1\/points\/(team|player)\/([^/]+)$/.exec(pathname);
  if (method === 'GET' && balanceMatch) {
    const apiKey = await requireReadKey(request);
    if (!enforceRateLimit(response, `key:${createHash('sha256').update(apiKey.id).digest('hex')}`, keyLimiter, requestId)) return;
    const subjectType = parseSubjectType(balanceMatch[1]);
    let decodedSubjectId: string;
    try {
      decodedSubjectId = decodeURIComponent(balanceMatch[2] ?? '');
    } catch {
      throw new HttpError(400, 'invalid_request', 'subjectId must be a UUID.');
    }
    const subjectId = parseUuid(decodedSubjectId, 'subjectId');
    const result = await rpc<JsonRecord>('get_point_balance', {
      p_key_hash: apiKey.key_hash,
      p_subject_type: subjectType,
      p_subject_id: subjectId,
    });
    sendJson(response, 200, result);
    return;
  }

  if (method !== 'POST') throw new HttpError(404, 'not_found', 'The requested route was not found.');

  if (pathname === '/v1/points/snapshot') {
    const apiKey = await requireWriteKey(request);
    if (!enforceRateLimit(response, `key:${createHash('sha256').update(apiKey.id).digest('hex')}`, keyLimiter, requestId)) return;
    const body = await readJson(request);
    if (!Array.isArray(body.balances) || body.balances.length > SNAPSHOT_BATCH_MAX) {
      throw new HttpError(400, 'invalid_request', `balances must be an array with at most ${SNAPSHOT_BATCH_MAX} rows.`);
    }
    const seen = new Set<string>();
    const balances = body.balances.map((raw, index) => {
      const row = requireObject(raw, `balances[${index}]`);
      const subjectType = parseSubjectType(row.subjectType);
      const subjectId = parseUuid(row.subjectId, `balances[${index}].subjectId`);
      const key = `${subjectType}:${subjectId}`;
      if (seen.has(key)) throw new HttpError(400, 'invalid_request', 'balances cannot contain duplicate subjects.');
      seen.add(key);
      const profile = optionalProfileFields(row, subjectType);
      return {
        subjectType,
        subjectId,
        points: parseInteger(row.points, `balances[${index}].points`, 0, MAX_POINTS),
        wins: parseInteger(row.wins ?? 0, `balances[${index}].wins`, 0, MAX_POINTS),
        losses: parseInteger(row.losses ?? 0, `balances[${index}].losses`, 0, MAX_POINTS),
        ...profile,
      };
    });
    const result = await rpc<JsonRecord>('seed_point_snapshot', {
      p_key_hash: apiKey.key_hash,
      p_balances: balances,
    });
    sendJson(response, 200, snapshotWriteResult(result, apiKey));
    return;
  }

  if (pathname === '/v1/points/profiles') {
    const apiKey = await requireWriteKey(request);
    if (!enforceRateLimit(response, `key:${createHash('sha256').update(apiKey.id).digest('hex')}`, keyLimiter, requestId)) return;
    const body = await readJson(request);
    if (!Array.isArray(body.profiles) || body.profiles.length > SNAPSHOT_BATCH_MAX) {
      throw new HttpError(400, 'invalid_request', `profiles must be an array with at most ${SNAPSHOT_BATCH_MAX} rows.`);
    }
    const seen = new Set<string>();
    const profiles = body.profiles.map((raw, index) => {
      const row = requireObject(raw, `profiles[${index}]`);
      const subjectType = parseSubjectType(row.subjectType);
      const subjectId = parseUuid(row.subjectId, `profiles[${index}].subjectId`);
      const key = `${subjectType}:${subjectId}`;
      if (seen.has(key)) throw new HttpError(400, 'invalid_request', 'profiles cannot contain duplicate subjects.');
      seen.add(key);
      if (!Object.hasOwn(row, 'displayName')) {
        throw new HttpError(400, 'invalid_request', `profiles[${index}].displayName is required.`);
      }
      const displayName = row.displayName === null ? null : parseText(row.displayName, `profiles[${index}].displayName`, 255);
      const profile = optionalProfileFields(row, subjectType);
      return { subjectType, subjectId, displayName, ...profile };
    });
    const result = await rpc<JsonRecord>('sync_point_profiles', {
      p_key_hash: apiKey.key_hash,
      p_profiles: profiles,
    });
    sendJson(response, 200, result);
    return;
  }

  if (pathname === '/v1/points/delete') {
    const apiKey = await requireWriteKey(request);
    if (!enforceRateLimit(response, `key:${createHash('sha256').update(apiKey.id).digest('hex')}`, keyLimiter, requestId)) return;
    const body = await readJson(request);
    const eventId = eventIdFromHeader(request);
    const subjectType = parseSubjectType(body.subjectType);
    const subjectId = parseUuid(body.subjectId, 'subjectId');
    const reason = body.reason === undefined ? null : parseText(body.reason, 'reason', 128, true);
    const payload = { subjectType, subjectId, reason };
    const result = await rpc<JsonRecord>('mutate_points', {
      p_key_hash: apiKey.key_hash,
      p_event_id: eventId,
      p_request_hash: payloadHash({ operation: 'delete', payload }),
      p_operation: 'delete',
      p_payload: payload,
    });
    sendJson(response, 200, mutationResult(result, apiKey));
    return;
  }

  if (pathname === '/v1/matches/settle') {
    const apiKey = await requireWriteKey(request);
    if (!enforceRateLimit(response, `key:${createHash('sha256').update(apiKey.id).digest('hex')}`, keyLimiter, requestId)) return;
    const body = await readJson(request);
    const eventId = eventIdFromHeader(request);
    const matchId = parseUuid(body.matchId, 'matchId');
    assertHeaderMatchesBody(eventId, matchId);
    const subjectType = parseSubjectType(body.subjectType);
    const subjectAId = parseUuid(body.subjectAId, 'subjectAId');
    const subjectBId = parseUuid(body.subjectBId, 'subjectBId');
    if (subjectAId === subjectBId) throw new HttpError(400, 'invalid_request', 'A match must have two different subjects.');
    const winnerId = body.winnerId === null ? null : parseUuid(body.winnerId, 'winnerId');
    if (winnerId !== null && winnerId !== subjectAId && winnerId !== subjectBId) {
      throw new HttpError(400, 'invalid_request', 'winnerId must be null or one of the match subjects.');
    }
    if (typeof body.ranked !== 'boolean') throw new HttpError(400, 'invalid_request', 'ranked must be a boolean.');
    const deltaA = parseInteger(body.deltaA, 'deltaA', -MAX_POINTS, MAX_POINTS);
    const deltaB = parseInteger(body.deltaB, 'deltaB', -MAX_POINTS, MAX_POINTS);
    if (!body.ranked && (deltaA !== 0 || deltaB !== 0)) {
      throw new HttpError(400, 'invalid_request', 'Unranked matches must have zero point deltas.');
    }
    const startedAt = parseInteger(body.startedAt, 'startedAt', 0, 8_640_000_000_000_000);
    const endedAt = parseInteger(body.endedAt, 'endedAt', startedAt, 8_640_000_000_000_000);
    if (endedAt > Date.now() + MAX_FUTURE_MATCH_SKEW_MS) {
      throw new HttpError(400, 'invalid_request', 'Match times cannot be more than five minutes in the future.');
    }
    const durationSeconds = parseInteger(body.durationSeconds, 'durationSeconds', 0, MAX_POINTS);
    const battleSize = body.battleSize === undefined || body.battleSize === null
      ? null
      : parseInteger(body.battleSize, 'battleSize', 2, 1_000);
    if (subjectType === 'team' && battleSize === null) {
      throw new HttpError(400, 'invalid_request', 'Team matches must include battleSize.');
    }
    if (subjectType === 'player' && battleSize !== null) {
      throw new HttpError(400, 'invalid_request', 'Player matches must omit battleSize.');
    }
    const displayA = body.displayA === undefined ? null : requireObject(body.displayA, 'displayA');
    const displayB = body.displayB === undefined ? null : requireObject(body.displayB, 'displayB');
    const profileA = displayA === null ? null : optionalProfileFields(displayA, subjectType);
    const profileB = displayB === null ? null : optionalProfileFields(displayB, subjectType);
    const payload = {
      matchId,
      subjectType,
      subjectAId,
      subjectBId,
      winnerId,
      ranked: body.ranked,
      startedAt,
      endedAt,
      durationSeconds,
      battleSize,
      deltaA,
      deltaB,
      ...(profileA === null ? {} : { displayA: profileA }),
      ...(profileB === null ? {} : { displayB: profileB }),
    };
    const result = await rpc<JsonRecord>('mutate_points', {
      p_key_hash: apiKey.key_hash,
      p_event_id: eventId,
      p_request_hash: payloadHash(payload),
      p_operation: 'match',
      p_payload: payload,
    });
    sendJson(response, 200, mutationResult(result, apiKey));
    return;
  }

  const singleMutationMatch = /^\/v1\/points\/(adjust|set)$/.exec(pathname);
  if (singleMutationMatch) {
    const apiKey = await requireWriteKey(request);
    if (!enforceRateLimit(response, `key:${createHash('sha256').update(apiKey.id).digest('hex')}`, keyLimiter, requestId)) return;
    const body = await readJson(request);
    const eventId = eventIdFromHeader(request);
    const subjectType = parseSubjectType(body.subjectType);
    const subjectId = parseUuid(body.subjectId, 'subjectId');
    const profile = optionalProfileFields(body, subjectType);
    const reason = body.reason === undefined ? null : parseText(body.reason, 'reason', 128, true);
    let operation: 'adjust' | 'set';
    let payload: JsonRecord;
    if (singleMutationMatch[1] === 'adjust') {
      operation = 'adjust';
      payload = {
        subjectType,
        subjectId,
        delta: parseInteger(body.delta, 'delta', -MAX_POINTS, MAX_POINTS),
        reason,
        ...profile,
      };
    } else {
      operation = 'set';
      payload = {
        subjectType,
        subjectId,
        points: parseInteger(body.points, 'points', 0, MAX_POINTS),
        reason,
        ...profile,
      };
    }
    const result = await rpc<JsonRecord>('mutate_points', {
      p_key_hash: apiKey.key_hash,
      p_event_id: eventId,
      p_request_hash: payloadHash({ operation, payload }),
      p_operation: operation,
      p_payload: payload,
    });
    sendJson(response, 200, mutationResult(result, apiKey));
    return;
  }

  if (pathname === '/v1/points/bulk') {
    const apiKey = await requireWriteKey(request);
    if (!enforceRateLimit(response, `key:${createHash('sha256').update(apiKey.id).digest('hex')}`, keyLimiter, requestId)) return;
    const body = await readJson(request);
    const eventId = eventIdFromHeader(request);
    const subjectType = parseSubjectType(body.subjectType);
    if (body.operation !== 'adjust' && body.operation !== 'set') {
      throw new HttpError(400, 'invalid_request', 'operation must be adjust or set.');
    }
    const amount = body.operation === 'adjust'
      ? parseInteger(body.amount, 'amount', -MAX_POINTS, MAX_POINTS)
      : parseInteger(body.amount, 'amount', 0, MAX_POINTS);
    const reason = body.reason === undefined ? null : parseText(body.reason, 'reason', 128, true);
    const payload = { subjectType, operation: body.operation, amount, reason };
    const result = await rpc<JsonRecord>('mutate_points', {
      p_key_hash: apiKey.key_hash,
      p_event_id: eventId,
      p_request_hash: payloadHash({ operation: 'bulk', payload }),
      p_operation: 'bulk',
      p_payload: payload,
    });
    sendJson(response, 200, mutationResult(result, apiKey));
    return;
  }

  throw new HttpError(404, 'not_found', 'The requested route was not found.');
}

function routeForLog(request: IncomingMessage): string {
  const method = request.method ?? 'UNKNOWN';
  const pathname = (request.url ?? '/').split('?', 1)[0]?.replace(/\/$/, '') || '/';

  if (method === 'GET' && ['/healthz', '/health', '/readyz'].includes(pathname)) return pathname;
  if (method === 'GET' && pathname === '/v1/accounts/oauth/start') return pathname;
  if (method === 'GET' && pathname === '/v1/accounts/oauth/callback') return pathname;
  if (method === 'GET' && /^\/v1\/accounts\/portraits\/[^/]+\/(classic|slim)\.png$/i.test(pathname)) {
    return '/v1/accounts/portraits/:textureHash/:model.png';
  }
  if (method === 'GET' && pathname === '/v1/accounts/skins') return pathname;
  if (method === 'GET' && /^\/v1\/accounts\/link\/[^/]+$/.test(pathname)) return '/v1/accounts/link/:requestId';
  if (method === 'POST' && /^\/v1\/accounts\/link\/[^/]+\/confirm$/.test(pathname)) {
    return '/v1/accounts/link/:requestId/confirm';
  }
  if (method === 'GET' && /^\/v1\/accounts\/[^/]+$/.test(pathname)) return '/v1/accounts/:playerId';
  if (FIXED_LOG_ROUTES.has(`${method} ${pathname}`)) return pathname;
  if (method === 'GET' && pathname === '/v1/leaderboards/seasons') return pathname;
  if (method === 'GET' && /^\/v1\/leaderboards\/(smp-teams|smp-solo|pvp)$/.test(pathname)) {
    return '/v1/leaderboards/:mode';
  }
  if (method === 'GET' && /^\/v1\/points\/(team|player)\/[^/]+$/.test(pathname)) {
    return '/v1/points/:subjectType/:subjectId';
  }

  if (FIXED_LOG_ROUTES.has(`${method} ${pathname}`)) return pathname;
  return pathname.startsWith('/v1/') ? '/v1/<unmatched>' : '/<unmatched>';
}

let inFlightRequests = 0;

const server = createServer(async (request, response) => {
  const requestId = randomUUID();
  const startedAt = Date.now();
  let status = 500;
  if (inFlightRequests >= maxInFlightRequests) {
    status = 503;
    response.setHeader('Retry-After', '1');
    response.setHeader('Connection', 'close');
    errorResponse(response, 503, 'server_busy', 'The service is handling its current request limit. Retry shortly.', requestId);
    const elapsedMs = Date.now() - startedAt;
    process.stdout.write(`${JSON.stringify({ requestId, method: request.method ?? 'UNKNOWN', route: routeForLog(request), status, elapsedMs })}\n`);
    return;
  }
  inFlightRequests += 1;
  try {
    await routeRequest(request, response, requestId);
    status = response.statusCode;
  } catch (error) {
    if (error instanceof HttpError) {
      status = error.status;
      if (error.details.retryAfterSeconds !== undefined) {
        response.setHeader('Retry-After', String(error.details.retryAfterSeconds));
      }
      if (!response.headersSent) errorResponse(response, error.status, error.code, error.message, requestId, error.details);
      else response.destroy();
    } else if (error instanceof BackendError) {
      status = 503;
      if (!response.headersSent) {
        errorResponse(response, 503, 'service_unavailable', 'The data service is temporarily unavailable.', requestId);
      } else response.destroy();
    } else {
      status = 500;
      if (!response.headersSent) errorResponse(response, 500, 'internal_error', 'The request could not be completed.', requestId);
      else response.destroy();
    }
  } finally {
    inFlightRequests -= 1;
    const elapsedMs = Date.now() - startedAt;
    const route = routeForLog(request);
    process.stdout.write(`${JSON.stringify({ requestId, method: request.method ?? 'UNKNOWN', route, status, elapsedMs })}\n`);
  }
});

server.requestTimeout = 15_000;
server.headersTimeout = 10_000;
server.keepAliveTimeout = 5_000;
server.maxRequestsPerSocket = 1_000;

server.listen(port, listenHost, () => {
  const address = server.address() as AddressInfo | null;
  process.stdout.write(`Strafe points API listening on ${address?.port ?? port}\n`);
});

let closing = false;
function shutdown(signal: string): void {
  if (closing) return;
  closing = true;
  process.stdout.write(`${signal} received; closing HTTP listener\n`);
  const forceClose = setTimeout(() => server.closeAllConnections(), 10_000);
  forceClose.unref();
  server.close((error) => {
    clearTimeout(forceClose);
    void databasePool.end().catch(() => {
      process.stderr.write('Database pool shutdown failed.\n');
      process.exitCode = 1;
    });
    if (error) {
      process.stderr.write('HTTP server shutdown failed.\n');
      process.exitCode = 1;
    }
  });
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
