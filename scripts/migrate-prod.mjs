import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from 'pg';

if (process.argv.includes('--sql')) {
  const { exportMigrations } = await import('./export-migrations.mjs');
  await exportMigrations();
  process.exit(0);
}

if (!process.argv.includes('--postgres')) {
  try {
    const { migrateHttps } = await import('./migrate-https.mjs');
    await migrateHttps();
  } catch (error) {
    process.stderr.write(`Production migration failed: ${error instanceof Error ? error.message : 'unknown error'}\n`);
    process.exitCode = 1;
  }
  process.exit(process.exitCode || 0);
}

const directory = resolve(dirname(fileURLToPath(import.meta.url)), '../supabase/migrations');
const databaseUrlRaw = process.env.MIGRATIONS_DATABASE_URL?.trim();
if (!databaseUrlRaw) {
  throw new Error('MIGRATIONS_DATABASE_URL is required. Use an administrator connection; DATABASE_URL is the restricted runtime login.');
}

let databaseUrl;
try {
  databaseUrl = new URL(databaseUrlRaw);
} catch {
  throw new Error('MIGRATIONS_DATABASE_URL must be a valid PostgreSQL connection URL.');
}
if (!['postgres:', 'postgresql:'].includes(databaseUrl.protocol)) {
  throw new Error('MIGRATIONS_DATABASE_URL must use the postgres or postgresql scheme.');
}
if (['sslmode', 'sslcert', 'sslkey', 'sslrootcert'].some((parameter) => databaseUrl.searchParams.has(parameter))) {
  throw new Error('Remove SSL parameters from MIGRATIONS_DATABASE_URL and configure DATABASE_SSL_CA_PATH instead.');
}

const localHosts = new Set(['localhost', '127.0.0.1', '[::1]']);
const isLocalDatabase = localHosts.has(databaseUrl.hostname);
const sslCaPath = process.env.DATABASE_SSL_CA_PATH?.trim();
let ssl;
if (!isLocalDatabase) {
  if (!sslCaPath) throw new Error('DATABASE_SSL_CA_PATH is required for remote PostgreSQL connections.');
  try {
    ssl = { ca: await readFile(sslCaPath, 'utf8'), rejectUnauthorized: true };
  } catch {
    throw new Error('DATABASE_SSL_CA_PATH could not be read.');
  }
}

const migrationFiles = (await readdir(directory, { withFileTypes: true }))
  .filter((entry) => entry.isFile() && /^\d{14}_[a-z0-9_]+\.sql$/.test(entry.name))
  .map((entry) => entry.name)
  .sort();
if (migrationFiles.length === 0) throw new Error(`No SQL migrations found in ${directory}.`);

const client = new Client({
  connectionString: databaseUrlRaw,
  ...(ssl ? { ssl } : {}),
  connectionTimeoutMillis: 10_000,
  application_name: 'strafe-points-migrator',
});

const lockKeyA = 0x53545246; // STRF
const lockKeyB = 0x4d494752; // MIGR
let locked = false;

try {
  await client.connect();
  const { rows: identityRows } = await client.query(
    'select current_database() as database_name, current_user as database_user',
  );
  const identity = identityRows[0];
  if (identity.database_user !== 'postgres') {
    throw new Error('The migration connection must authenticate as the Supabase postgres role.');
  }

  await client.query('select pg_catalog.pg_advisory_lock($1, $2)', [lockKeyA, lockKeyB]);
  locked = true;
  await client.query(`
    create schema if not exists strafe_migrations;
    revoke all on schema strafe_migrations from public, anon, authenticated, service_role;
    create table if not exists strafe_migrations.applied_migrations (
      name text primary key,
      checksum text not null check (checksum ~ '^[0-9a-f]{64}$'),
      applied_at timestamptz not null default pg_catalog.now()
    );
    revoke all on table strafe_migrations.applied_migrations from public, anon, authenticated, service_role;
  `);

  const { rows: appliedRows } = await client.query(
    'select name, checksum from strafe_migrations.applied_migrations order by name',
  );
  const migrationNames = new Set(migrationFiles);
  for (const applied of appliedRows) {
    if (!migrationNames.has(applied.name)) {
      throw new Error(`Migration ${applied.name} is recorded in the database but is missing from this checkout.`);
    }
  }

  const appliedByName = new Map(appliedRows.map((row) => [row.name, row.checksum]));
  for (const name of migrationFiles) {
    const path = resolve(directory, name);
    if (basename(path) !== name) throw new Error(`Invalid migration filename: ${name}`);
    const sql = await readFile(path, 'utf8');
    const checksum = createHash('sha256').update(sql).digest('hex');
    const previousChecksum = appliedByName.get(name);
    if (previousChecksum) {
      if (previousChecksum !== checksum) throw new Error(`Applied migration ${name} has changed. Add a new migration instead.`);
      continue;
    }

    const laterApplied = appliedRows.find((row) => row.name > name);
    if (laterApplied) {
      throw new Error(`Migration ${name} is out of order; ${laterApplied.name} has already been applied.`);
    }

    process.stdout.write(`Applying ${name}...\n`);
    await client.query('begin');
    try {
      await client.query(sql);
      await client.query(
        'insert into strafe_migrations.applied_migrations(name, checksum) values ($1, $2)',
        [name, checksum],
      );
      await client.query('commit');
    } catch (error) {
      await client.query('rollback');
      throw error;
    }
    process.stdout.write(`Applied ${name}.\n`);
  }

  process.stdout.write(`Production migrations are up to date (${identity.database_name}).\n`);
} catch (error) {
  process.stderr.write(`Production migration failed: ${error instanceof Error ? error.message : 'unknown error'}\n`);
  process.exitCode = 1;
} finally {
  if (locked) {
    try {
      await client.query('select pg_catalog.pg_advisory_unlock($1, $2)', [lockKeyA, lockKeyB]);
    } catch {
      // Closing the connection releases a session advisory lock if the unlock query fails.
    }
  }
  await client.end().catch(() => {});
}
