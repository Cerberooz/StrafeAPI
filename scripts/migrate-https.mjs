import { migrationBundle } from './export-migrations.mjs';

export async function migrateHttps() {
  const token = process.env.SUPABASE_ACCESS_TOKEN?.trim();
  if (!token || !token.startsWith('sbp_')) {
    throw new Error('Set SUPABASE_ACCESS_TOKEN to a Supabase personal access token with Database Write access. This is a deployment credential, not SUPABASE_SECRET_KEY.');
  }
  let projectRef = process.env.SUPABASE_PROJECT_REF?.trim();
  if (!projectRef && process.env.SUPABASE_URL) {
    const url = new URL(process.env.SUPABASE_URL);
    if (url.protocol === 'https:' && !url.username && !url.password && /^[a-z]{20}\.supabase\.co$/.test(url.hostname)) {
      projectRef = url.hostname.split('.')[0];
    }
  }
  if (!projectRef || !/^[a-z]{20}$/.test(projectRef)) throw new Error('Set SUPABASE_PROJECT_REF to your project reference, or set its standard SUPABASE_URL in .env.');
  const endpoint = `https://api.supabase.com/v1/projects/${projectRef}/database/query`;
  async function query(sql) {
    let response;
    try {
      response = await fetch(endpoint, {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(60_000),
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ query: sql, read_only: false }),
      });
    } catch {
      throw new Error('Supabase migration request did not complete. Its outcome may be unknown; rerun the same command to check migration history safely.');
    }
    // Avoid printing upstream query text, data or credentials on failure.
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`Supabase Management API returned HTTP ${response.status}. Check token permissions and project availability. If SQL failed, run pnpm migrate:prod --sql and inspect it in SQL Editor.`);
    }
    const reader = response.body?.getReader();
    if (!reader) throw new Error('Supabase returned no migration response');
    let size = 0;
    const chunks = [];
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 2 * 1024 * 1024) throw new Error('Supabase migration response exceeds its size limit');
        chunks.push(value);
      }
    } finally { await reader.cancel().catch(() => {}); }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  }
  const bundle = await migrationBundle();
  process.stdout.write(`Applying pending migrations to Supabase project ${projectRef} over HTTPS...\n`);
  await query(bundle.query);
  const result = await query('select pg_catalog.jsonb_object_agg(name, checksum) as checksums from strafe_migrations.applied_migrations');
  const actual = Array.isArray(result) ? result[0]?.checksums : null;
  const expected = Object.entries(bundle.checksums);
  if (!actual || Object.keys(actual).length !== expected.length || expected.some(([name, checksum]) => actual[name] !== checksum)) {
    throw new Error('Migration history could not be confirmed. Rerun the same command; do not modify applied SQL files.');
  }
  process.stdout.write(`Production migrations are up to date (${expected.length} verified files).\n`);
}
