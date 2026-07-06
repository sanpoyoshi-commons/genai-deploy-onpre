// 共通アプリチーム作成（上流 create-common-app-team.sh 相当）。
//
// COMMON_TEAM_ID = 00000000-0000-0000-0000-000000000000 に登録されたアプリは、所属に関係なく
// 全認証済みユーザーがアクセス・実行できる（認可ロジックは api 側に実装済み）。ただしこの固定 id の
// チームを作る手段が無かった。api の createTeam は id を内部生成＋teamAdminEmail 必須で
// 「メンバーを持たない共通チーム」を作れないため、ここでは teams 行を直接 upsert する。
//
// DATABASE_URL の取り回し：
//   - .env 方式：api コンテナ env に DATABASE_URL（パスワード焼込済）がある → そのまま使う。
//   - secrets オーバーレイ方式：exec で起動する本プロセスは entrypoint が export した DATABASE_URL を
//     継承せず空になる。POSTGRES_PASSWORD_FILE（/run/secrets/postgres_password）から再構築する
//     （docker-compose.secrets.yml の entrypoint と同手順・URL エンコード込み）。
//
// 実行（deploy リポで、api コンテナ内＝pg 依存と内部 postgres:5432 を使う）：
//   docker compose exec -T api node --input-type=module - < scripts/create-common-app-team.mjs
//
// 冪等：ON CONFLICT DO NOTHING。既存なら何もしない。

import { readFileSync } from 'node:fs';

const COMMON_TEAM_ID = '00000000-0000-0000-0000-000000000000';
const TEAM_NAME = process.env.COMMON_TEAM_NAME ?? '共通アプリ';

/** DATABASE_URL を解決（env 優先・secrets 方式は _FILE から再構築）。 */
function resolveDatabaseUrl() {
  const direct = process.env.DATABASE_URL;
  if (direct && direct.length > 0) {
    return direct;
  }
  const user = process.env.POSTGRES_USER ?? 'genai';
  const db = process.env.POSTGRES_DB ?? 'genai';
  let password = process.env.POSTGRES_PASSWORD;
  const passwordFile = process.env.POSTGRES_PASSWORD_FILE;
  if ((!password || password.length === 0) && passwordFile) {
    password = readFileSync(passwordFile, 'utf8').trim();
  }
  if (!password) {
    throw new Error('DATABASE_URL も POSTGRES_PASSWORD(_FILE) も解決できません。');
  }
  const host = process.env.POSTGRES_HOST ?? 'postgres';
  const port = process.env.POSTGRES_PORT ?? '5432';
  return `postgresql://${user}:${encodeURIComponent(password)}@${host}:${port}/${db}`;
}

const { default: pg } = await import('pg');
const pool = new pg.Pool({ connectionString: resolveDatabaseUrl() });

try {
  const res = await pool.query(
    'INSERT INTO teams (id, name) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING',
    [COMMON_TEAM_ID, TEAM_NAME],
  );
  if (res.rowCount > 0) {
    console.log(`[create-common-app-team] 作成: id=${COMMON_TEAM_ID} name="${TEAM_NAME}"`);
  } else {
    console.log(`[create-common-app-team] 既存スキップ（冪等）: id=${COMMON_TEAM_ID}`);
  }
  const check = await pool.query('SELECT id, name FROM teams WHERE id = $1', [COMMON_TEAM_ID]);
  console.log(`[verify] teams 行: ${JSON.stringify(check.rows[0] ?? null)}`);
  console.log('[result] create-common-app-team OK');
} finally {
  await pool.end();
}
