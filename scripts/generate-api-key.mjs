import { createHash, randomBytes } from 'node:crypto';

const allowedScopes = new Set([
  'leaderboards:read', 'points:read', 'points:write',
  'accounts:read', 'accounts:write', 'accounts:admin', 'tiers:moderate',
]);
const args = process.argv.slice(2);
const values = new Map();

for (let index = 0; index < args.length; index += 1) {
  const argument = args[index];
  if (!argument?.startsWith('--')) {
    throw new Error(`Unexpected argument: ${argument ?? ''}`);
  }
  const name = argument.slice(2);
  const value = args[index + 1];
  if (!value || value.startsWith('--')) {
    throw new Error(`Missing value for --${name}`);
  }
  values.set(name, value);
  index += 1;
}

const label = values.get('label')?.trim();
const scopesText = values.get('scopes') ?? 'points:read,points:write';
const scopes = [...new Set(scopesText.split(',').map((scope) => scope.trim()).filter(Boolean))].sort();

if (!label || label.length > 80) {
  throw new Error('Pass --label with 1 to 80 characters.');
}
if (!scopes.length || scopes.some((scope) => !allowedScopes.has(scope))) {
  throw new Error('Scopes must be a comma-separated list of leaderboards:read, points:read, points:write, accounts:read, accounts:write, accounts:admin, and/or tiers:moderate.');
}

const token = `ssmp_live_${randomBytes(32).toString('hex')}`;
const hash = createHash('sha256').update(token, 'utf8').digest('hex');
const prefix = token.slice(0, 21);
const pgArray = `{${scopes.join(',')}}`;

process.stdout.write([
  'Copy this API key into the server-side client configuration. It cannot be recovered later:',
  token,
  '',
  'Add one row to public.api_keys in the Supabase Table Editor with these values:',
  `label: ${JSON.stringify(label)}`,
  `key_prefix: ${JSON.stringify(prefix)}`,
  `key_hash: ${JSON.stringify(hash)}`,
  `scopes: ${JSON.stringify(pgArray)}`,
  '',
].join('\n'));
