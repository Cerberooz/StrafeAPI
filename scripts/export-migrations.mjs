import { createHash } from 'node:crypto';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

export async function migrationBundle() {
  const directory = fileURLToPath(new URL('../supabase/migrations/', import.meta.url));
  const files = (await readdir(directory)).filter(name => /^\d{14}_[a-z0-9_]+\.sql$/.test(name)).sort();
  if (!files.length) throw new Error('No migrations found');
  const quote = value => "'" + value.replaceAll("'", "''") + "'";
  const checksums = {};
  const chunks = [`begin;
select pg_catalog.pg_advisory_xact_lock(${0x53545246}, ${0x4d494752});
do $identity$ begin
  if current_user <> 'postgres' then raise exception 'Run as postgres in Supabase SQL Editor'; end if;
end $identity$;
create schema if not exists strafe_migrations;
revoke all on schema strafe_migrations from public, anon, authenticated, service_role;
create table if not exists strafe_migrations.applied_migrations (
  name text primary key,
  checksum text not null check (checksum ~ '^[a-f0-9]{64}$'),
  applied_at timestamptz not null default pg_catalog.now()
);
revoke all on table strafe_migrations.applied_migrations from public, anon, authenticated, service_role;
do $history$ begin
  if exists (select 1 from strafe_migrations.applied_migrations where name not in (${files.map(quote).join(',')})) then
    raise exception 'Applied migrations are missing from this checkout';
  end if;
end $history$;`];
  for (const name of files) {
    const sql = await readFile(resolve(directory, name), 'utf8');
    const checksum = createHash('sha256').update(sql).digest('hex');
    checksums[name] = checksum;
    const tag = `$migration_${name.slice(0, 14)}$`;
    if (sql.includes(tag)) throw new Error('Migration delimiter collision');
    chunks.push(`do $apply$ declare previous text; begin
  select checksum into previous from strafe_migrations.applied_migrations where name = ${quote(name)};
  if previous is not null then
    if previous <> ${quote(checksum)} then raise exception 'Applied migration checksum changed: ${name}'; end if;
  else
    if exists (select 1 from strafe_migrations.applied_migrations where name > ${quote(name)}) then
      raise exception 'Migration is out of order: ${name}';
    end if;
    execute ${tag}${sql}${tag};
    insert into strafe_migrations.applied_migrations(name, checksum) values (${quote(name)}, ${quote(checksum)});
  end if;
end $apply$;`);
  }
  chunks.push('commit;');
  return { query: chunks.join('\n\n'), checksums };
}

export async function exportMigrations() {
  const { query } = await migrationBundle();
  const output = resolve('migrations-prod.sql');
  await writeFile(output, query, 'utf8');
  process.stdout.write(`Generated ${output}. Run the complete file as postgres in Supabase SQL Editor.\n`);
}
