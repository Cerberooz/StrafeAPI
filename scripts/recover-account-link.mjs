const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const API_KEY_PATTERN = /^ssmp_live_[0-9a-f]{64}$/;

function parseArguments(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (!argument?.startsWith('--')) throw new Error('Use --player-id, --discord-id, --display-name, and --reason.');
    const name = argument.slice(2);
    const value = args[index + 1];
    if (!value || value.startsWith('--') || values.has(name)) throw new Error(`Invalid or repeated --${name}.`);
    values.set(name, value);
    index += 1;
  }
  const expected = new Set(['player-id', 'discord-id', 'display-name', 'reason']);
  if ([...values.keys()].some((name) => !expected.has(name)) || [...expected].some((name) => !values.has(name))) {
    throw new Error('Use --player-id, --discord-id, --display-name, and --reason.');
  }
  return values;
}

const apiKey = process.env.ACCOUNT_ADMIN_API_KEY?.trim() ?? '';
const apiBaseRaw = process.env.ACCOUNT_API_BASE_URL?.trim() ?? '';
if (!API_KEY_PATTERN.test(apiKey)) throw new Error('Set ACCOUNT_ADMIN_API_KEY to an accounts:admin API key.');
if (!apiBaseRaw) throw new Error('Set ACCOUNT_API_BASE_URL to the API origin.');

let apiBase;
try {
  apiBase = new URL(apiBaseRaw);
  const localHost = ['localhost', '127.0.0.1', '[::1]'].includes(apiBase.hostname);
  if (!['https:', ...(localHost ? ['http:'] : [])].includes(apiBase.protocol)
    || apiBase.username || apiBase.password || apiBase.search || apiBase.hash || apiBase.pathname !== '/') {
    throw new Error();
  }
} catch {
  throw new Error('ACCOUNT_API_BASE_URL must be an HTTPS origin (HTTP is allowed for localhost).');
}

const values = parseArguments(process.argv.slice(2));
const playerId = values.get('player-id')?.trim() ?? '';
const discordId = values.get('discord-id')?.trim() ?? '';
const discordDisplayName = values.get('display-name')?.trim() ?? '';
const reason = values.get('reason')?.trim() ?? '';
if (!UUID_PATTERN.test(playerId)) throw new Error('--player-id must be a UUID.');
if (!/^[0-9]{17,20}$/.test(discordId)) throw new Error('--discord-id must be a Discord snowflake.');
if (discordDisplayName.length < 1 || discordDisplayName.length > 100) throw new Error('--display-name must be 1 to 100 characters.');
if (reason.length < 1 || reason.length > 500) throw new Error('--reason must be 1 to 500 characters.');

let response;
try {
  response = await fetch(new URL('/v1/accounts/admin/recover', apiBase), {
    method: 'POST',
    redirect: 'error',
    signal: AbortSignal.timeout(10_000),
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({ playerId: playerId.toLowerCase(), discordId, discordDisplayName, reason }),
  });
} catch {
  throw new Error('The account recovery request could not reach the API.');
}

const payload = await response.json().catch(() => null);
if (!response.ok) {
  const body = payload !== null && typeof payload === 'object' ? payload : {};
  const error = body.error !== null && typeof body.error === 'object' ? body.error : {};
  const code = typeof error.code === 'string' ? error.code : 'request_failed';
  const message = typeof error.message === 'string' ? error.message : 'The account recovery request failed.';
  process.stderr.write(`${code}: ${message}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write('Account recovery completed and audited.\n');
}
