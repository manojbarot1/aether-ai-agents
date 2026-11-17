// Copy one agent's SQLite DB to another, minus per-agent state.
// Usage: node clone-db.cjs <app-dir> <source.db> <dest.db>
// Safe while the source agent is running (SQLite online backup).
'use strict';
const path = require('path');
const fs = require('fs');

const [appDir, src, dest] = process.argv.slice(2);
if (!appDir || !src || !dest) {
  console.error('usage: node clone-db.cjs <app-dir> <source.db> <dest.db>');
  process.exit(1);
}
const Database = require(require.resolve('better-sqlite3', { paths: [path.join(appDir, 'server')] }));

// Rows that belong to one agent only and must not travel with a clone.
const STRIP_SETTINGS = [
  'premium_license_key',   // license stays on the source agent
  'premium_license_status',
  'catalog_applied_version', 'catalog_applied_tier', 'catalog_applied_json',
  'catalog_last_sync_ms', 'catalog_last_error',
];
const STRIP_TABLES = [
  'sessions',              // logins are per agent; the account itself is kept
  'requests', 'request_attempts', 'request_hourly',
  'server_logs', 'response_cache', 'playground_conversations', 'idempotency_claims',
];

(async () => {
  for (const f of [dest, dest + '-wal', dest + '-shm']) fs.rmSync(f, { force: true });
  fs.mkdirSync(path.dirname(dest), { recursive: true });

  const source = new Database(src, { fileMustExist: true });
  await source.backup(dest);
  source.close();

  const db = new Database(dest);
  const tables = new Set(db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all().map(r => r.name));
  db.transaction(() => {
    if (tables.has('settings')) {
      const del = db.prepare('DELETE FROM settings WHERE key = ?');
      for (const k of STRIP_SETTINGS) del.run(k);
    }
    for (const t of STRIP_TABLES) if (tables.has(t)) db.prepare(`DELETE FROM "${t}"`).run();
  })();
  db.exec('VACUUM');
  db.close();
  fs.chmodSync(dest, 0o600);
})().catch(err => { console.error(err.message); process.exit(1); });
