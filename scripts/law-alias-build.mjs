// e-Gov 法令XML の <LawTitle Abbrev="略称1,略称2"> から抽出した raw 略称ペアを検証し、
// 本番投入用の通称辞書 JSON（略称→正式名称）を生成する（LLM 不要・DB 照合のみ）。
//
// 入力：/tmp/aliases-raw.json  … [{ alias, formal, lawNum }, ...]（運用者が all_xml.zip から抽出）
// 出力：stdout に検証済み JSON（{"略称":"正式名称", ...}・キー昇順）／stderr に統計と除外理由。
//
// 自己解決（正式名称→自分自身）の保証＝**embedding を回さず構成的に担保**する：
//   正式名称は app_laws_master.law_title をそのまま採用する（embed_fill が同一文字列を埋めたので、その
//   自己 cosine=1.0 が最近傍になり resolveLawNums が必ず自分の law_num を返す）。よって採用条件は
//   (a) law_num が app_laws_master に実在、(b) その law_title が DB 内で一意（同名タイトル=曖昧は除外）。
// さらに曖昧さを断つため：(c) 同一略称→複数 law_num の衝突を除外、(d) 正規化キー衝突（別タイトル）を除外。
//
// 実行：
//   docker compose ... cp aliases-raw.json api:/tmp/aliases-raw.json
//   docker compose ... exec -T api node --input-type=module - < scripts/law-alias-build.mjs \
//     > api-config/law-name-aliases.json 2> /tmp/alias-build-stats.txt
// 生成後は scripts/law-alias-verify.mjs（実 embedding 解決）でサンプル最終確認する。

import { readFileSync } from 'node:fs';

const pw = readFileSync('/run/secrets/postgres_password', 'utf8').trim();
const pg = await import('pg');
const client = new pg.default.Client({
  connectionString: `postgresql://${process.env.POSTGRES_USER || 'genai'}:${encodeURIComponent(pw)}@postgres:5432/${process.env.POSTGRES_DB || 'genai'}`,
});
await client.connect();

const raw = JSON.parse(readFileSync('/tmp/aliases-raw.json', 'utf8'));

// 略称の最大文字数（これを超える「公式だが長い擬似略称」は除外＝gemma が出さずノイズになるため）。
const MAX_ALIAS_LEN = Number(process.env.LAW_ALIAS_MAX_LEN || 30);

// 手動除外（正規化済みキー）。意味的衝突監査（scripts/law-alias-collision-audit.mjs・2026-06-08）で
// 「総称的で両義的」と判定し運用判断で除外したもの。詳細＝docs/law-rag-aliases.md。
//   証明規則：特定無線設備…証明等に関する規則 ↔ 計算証明規則 のどちらにも取れる
//   標識令  ：道路標識…に関する命令 ↔ 自動車道標識令 のどちらにも取れる
const MANUAL_EXCLUDE = new Set(['証明規則', '標識令']);

// 正規化（api lawNameEstimator.ts の normalizeAliasKey と同一規則＝要同期）。
const norm = (s) => (s ?? '').replace(/[\s　・･〔〕（）()]/g, '');

// DB の law_num→law_title と title 一意性。
const all = await client.query('SELECT law_num, law_title FROM app_laws_master');
const numToTitle = new Map();
const titleCount = new Map();
for (const { law_num, law_title } of all.rows) {
  numToTitle.set(law_num, law_title);
  titleCount.set(law_title, (titleCount.get(law_title) ?? 0) + 1);
}

// 同一略称（自然表記）→複数 law_num の衝突を検出。
const aliasToNums = new Map();
for (const r of raw) {
  if (!aliasToNums.has(r.alias)) aliasToNums.set(r.alias, new Set());
  aliasToNums.get(r.alias).add(r.lawNum);
}

const stats = {
  input: raw.length,
  dropAliasCollision: 0,
  dropLawNotInDb: 0,
  dropTitleAmbiguous: 0,
  dropEmptyKey: 0,
  dropTooLong: 0,
  dropManualExclude: 0,
  dropKeyConflict: 0,
  dupSame: 0,
};

// 正規化キー -> { alias(自然表記), title }。複数タイトルに割れたキーは後段で除外。
const keyToTitles = new Map(); // key -> Set(title)
const keyToAlias = new Map(); // key -> 自然表記（先頭）

for (const r of raw) {
  if ((aliasToNums.get(r.alias)?.size ?? 0) > 1) {
    stats.dropAliasCollision += 1;
    continue;
  }
  const title = numToTitle.get(r.lawNum);
  if (!title) {
    stats.dropLawNotInDb += 1;
    continue;
  }
  if ((titleCount.get(title) ?? 0) > 1) {
    stats.dropTitleAmbiguous += 1;
    continue;
  }
  const key = norm(r.alias);
  if (key.length === 0) {
    stats.dropEmptyKey += 1;
    continue;
  }
  if (r.alias.length > MAX_ALIAS_LEN) {
    stats.dropTooLong += 1;
    continue;
  }
  if (MANUAL_EXCLUDE.has(key)) {
    stats.dropManualExclude += 1;
    continue;
  }
  if (!keyToTitles.has(key)) {
    keyToTitles.set(key, new Set());
    keyToAlias.set(key, r.alias);
  }
  keyToTitles.get(key).add(title);
}

const out = {};
for (const [key, titles] of keyToTitles) {
  if (titles.size > 1) {
    stats.dropKeyConflict += 1; // 同一正規化キーが別タイトルへ割れる＝曖昧
    continue;
  }
  out[keyToAlias.get(key)] = [...titles][0];
}

await client.end();

// stdout：キー昇順の JSON（安定 diff）。
const sorted = Object.fromEntries(Object.keys(out).sort((a, b) => a.localeCompare(b, 'ja')).map((k) => [k, out[k]]));
process.stdout.write(JSON.stringify(sorted, null, 2) + '\n');

// stderr：統計。
const kept = Object.keys(sorted).length;
const lens = Object.keys(sorted).map((k) => k.length).sort((a, b) => a - b);
const med = lens[Math.floor(lens.length / 2)] ?? 0;
console.error(`[alias-build] 入力 ${stats.input} ペア → 採用 ${kept} 件`);
console.error(`  除外: 略称衝突 ${stats.dropAliasCollision} / DB不在 ${stats.dropLawNotInDb} / タイトル曖昧 ${stats.dropTitleAmbiguous} / 空キー ${stats.dropEmptyKey} / ${MAX_ALIAS_LEN}字超 ${stats.dropTooLong} / 手動除外 ${stats.dropManualExclude} / 正規化キー衝突 ${stats.dropKeyConflict}`);
console.error(`  採用キー長: 中央値 ${med} / 最長 ${lens[lens.length - 1] ?? 0}`);
