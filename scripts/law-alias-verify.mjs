// 通称辞書の収録基準を機械検証する保守スクリプト（LLM 不要・tei+DB のみ）。
//
// 辞書は JSON ファイル（deploy api-config/law-name-aliases.json）を api が LAW_RAG_ALIASES_FILE で起動時に
// 読む（リーンプロンプトと同じ機構）。本スクリプトは api の resolveLawNameAliases で**実運用と同じ解決経路**
// を通して辞書を取り出し（コンテナ内 env の LAW_RAG_ALIASES_FILE 経由）、収録基準を CI 的に検証する：
//   (1) 一意実在 … 正式名称が app_laws_master.law_title に「ちょうど 1 件」実在するか（0=欠落 / 2+=曖昧 は不可）
//   (2) 自己解決 … 正式名称を resolveLawNums に渡すと自分自身の law_num に解決するか（title embedding 自己マッチ）
//   (3) 略称解決 … 各略称が applyLawNameAliases で正式名称へ写り、辞書適用後 resolveLawNums で同 law_num に届くか
// 正式名称 1 つに複数略称がある場合を想定し、正式名称でグルーピングして各略称を順に検証する。
// 参考として「辞書なしで略称を直接 resolve した結果」も併記する（辞書が誤マッチを矯正していることの可視化）。
//
// 実行（deploy リポ）：
//   docker compose -f docker-compose.yml -f docker-compose.secrets.yml exec -T api \
//     node --input-type=module - < scripts/law-alias-verify.mjs
// DB は読み取りのみ・認証不要（内部 seam 直駆動）。検証失敗が 1 件でもあれば exit 1（CI ゲート用）。

import { readFileSync } from 'node:fs';

if (!process.env.DATABASE_URL) {
  const pw = readFileSync('/run/secrets/postgres_password', 'utf8').trim();
  const user = process.env.POSTGRES_USER || 'genai';
  const db = process.env.POSTGRES_DB || 'genai';
  process.env.DATABASE_URL = `postgresql://${user}:${encodeURIComponent(pw)}@postgres:5432/${db}`;
}

const { resolveLawNameAliases, applyLawNameAliases } = await import(
  '/app/dist/lib/lawRag/lawNameEstimator.js'
);
// 実運用と同じ解決（LAW_RAG_ALIASES_FILE の JSON→正規化済み辞書）。env 未設定なら空辞書。
const LAW_NAME_ALIASES = resolveLawNameAliases(process.env);
if (Object.keys(LAW_NAME_ALIASES).length === 0) {
  console.log(
    '[alias-verify] 辞書が空です（LAW_RAG_ALIASES_FILE 未設定 or 読込失敗）。compose で配線済みか確認してください。',
  );
  process.exit(1);
}
const { LawRetriever } = await import('/app/dist/repositories/lawRetriever.js');
const { EmbeddingAbstractionClient } = await import('/app/dist/lib/llm/embeddingAbstractionClient.js');
const pg = await import('pg');

const client = new pg.default.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();
const retriever = new LawRetriever(new EmbeddingAbstractionClient());

// 正式名称でグルーピング（1 正式名称 : N 略称）。辞書の出現順を保つ。
const groups = new Map(); // formalTitle -> alias[]
for (const [alias, formal] of Object.entries(LAW_NAME_ALIASES)) {
  if (!groups.has(formal)) {
    groups.set(formal, []);
  }
  groups.get(formal).push(alias);
}

console.log(
  `[alias-verify] 略称 ${Object.keys(LAW_NAME_ALIASES).length} 件 / 正式名称 ${groups.size} 件を検証\n`,
);

let failures = 0;
const fail = (msg) => {
  failures += 1;
  console.log(`    ✗ ${msg}`);
};

for (const [formal, aliases] of groups) {
  console.log(`■ ${formal}`);
  console.log(`  略称: ${aliases.join(' / ')}`);

  // (1) 一意実在。
  const exact = await client.query('SELECT law_num FROM app_laws_master WHERE law_title = $1', [
    formal,
  ]);
  if (exact.rows.length === 0) {
    fail(`(1)一意実在: app_laws_master に該当タイトルが無い（未投入 or 表記不一致）`);
    console.log('');
    continue;
  }
  if (exact.rows.length > 1) {
    fail(`(1)一意実在: 同名タイトルが ${exact.rows.length} 件（曖昧・解決先が一意でない）`);
    console.log('');
    continue;
  }
  const goldLawNum = exact.rows[0].law_num;
  console.log(`    ✓ (1)一意実在 law_num=${goldLawNum}`);

  // (2) 自己解決（正式名称→自分自身）。
  const selfResolved = await retriever.resolveLawNums([formal], 'alias-verify');
  if (selfResolved[0] === goldLawNum) {
    console.log(`    ✓ (2)自己解決 resolveLawNums("${formal.slice(0, 8)}…")=${goldLawNum}`);
  } else {
    fail(`(2)自己解決: 正式名称が別法へ解決 → [${selfResolved.join(', ')}]（期待 ${goldLawNum}）`);
  }

  // (3) 各略称の解決（複数略称を順に）。
  for (const alias of aliases) {
    const mapped = applyLawNameAliases([alias], LAW_NAME_ALIASES);
    const mappedOk = mapped.length === 1 && mapped[0] === formal;
    // 辞書なしの直 resolve（誤マッチの可視化・失敗判定には使わない）。
    const rawResolved = await retriever.resolveLawNums([alias], 'alias-verify');
    const rawHit = rawResolved.includes(goldLawNum);
    // 辞書あり end-to-end。
    const viaAlias = await retriever.resolveLawNums(mapped, 'alias-verify');
    const e2eHit = viaAlias.includes(goldLawNum);

    if (!mappedOk) {
      fail(`略称「${alias}」: applyLawNameAliases が正式名称へ写らない → [${mapped.join(', ')}]`);
    } else if (!e2eHit) {
      fail(`略称「${alias}」: 辞書適用後も gold へ解決しない → [${viaAlias.join(', ')}]`);
    } else {
      console.log(
        `    ✓ (3)略称「${alias}」辞書あり=gold / 辞書なし直resolve=${rawHit ? 'gold(辞書不要)' : `別法[${rawResolved[0] ?? 'なし'}]→辞書が矯正`}`,
      );
    }
  }
  console.log('');
}

await client.end();

if (failures > 0) {
  console.log(`[alias-verify] ✗ NG: ${failures} 件の検証失敗`);
  process.exit(1);
}
console.log('[alias-verify] ✓ OK: 全エントリ合格');
process.exit(0);
