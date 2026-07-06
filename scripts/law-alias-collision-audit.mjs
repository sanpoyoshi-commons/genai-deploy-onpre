// 通称辞書の「意味的衝突」を全エントリで監査する（LLM 不要・embedding+DB のみ）。
//
// 辞書は K(略称)→A(その法令の公式正式名称) を必ず置換する。危険なのは「gemma が K を出すとき別法 B の
// つもりだった」＝辞書が K の解決先を本来の B から A へ逸らすケース。これは次で検出できる：
//   - 辞書あり解決 = A（構成上 K→正式名称_A→law_num_A で確定）
//   - 辞書なし解決 = B（K をそのまま embedding 近傍検索した law_num）
//   A ≠ B のキーだけが「挙動を変える」＝衝突候補。さらに **K が B のタイトルに部分一致**するものは
//   「K は本来 B を指す名前なのに A へ逸らしている」高リスク。A ≠ B でも K が B 名と無関係なら、B は
//   embedding のミスファイア（辞書が正しく矯正）で安全側。
//
// 出力：stderr に集計、stdout に高リスク候補（K / 辞書先A / 素解決B）の JSON。
//
// 実行：
//   docker compose ... exec -T api node --input-type=module - < scripts/law-alias-collision-audit.mjs \
//     > /tmp/collision-suspects.json 2> /tmp/collision-stats.txt

import { readFileSync } from 'node:fs';

const pw = readFileSync('/run/secrets/postgres_password', 'utf8').trim();
process.env.DATABASE_URL = `postgresql://${process.env.POSTGRES_USER || 'genai'}:${encodeURIComponent(pw)}@postgres:5432/${process.env.POSTGRES_DB || 'genai'}`;

const { resolveLawNameAliases, applyLawNameAliases } = await import('/app/dist/lib/lawRag/lawNameEstimator.js');
const { toVectorLiteral } = await import('/app/dist/repositories/lawRetriever.js');
const { EmbeddingAbstractionClient } = await import('/app/dist/lib/llm/embeddingAbstractionClient.js');
const pg = await import('pg');

const client = new pg.default.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();
const embedder = new EmbeddingAbstractionClient();

const aliases = resolveLawNameAliases(process.env); // 実運用と同じ（LAW_RAG_ALIASES_FILE）。
const keys = Object.keys(aliases);
console.error(`[collision-audit] 辞書 ${keys.length} キーを監査`);

// 正式名称 → law_num（一意・build で保証）。
const all = await client.query('SELECT law_num, law_title FROM app_laws_master');
const titleToNum = new Map();
const numToTitle = new Map();
for (const { law_num, law_title } of all.rows) {
  titleToNum.set(law_title, law_num);
  numToTitle.set(law_num, law_title);
}

const norm = (s) => (s ?? '').replace(/[\s　・･〔〕（）()]/g, '');

// K を素の embedding で最近傍解決（辞書なし）。バッチ embed→個別 nearest。
async function nearestNum(vec) {
  const lit = toVectorLiteral(vec);
  const r = await client.query(
    `SELECT law_num FROM app_laws_master WHERE law_title_embedding IS NOT NULL
     ORDER BY law_title_embedding <=> $1::vector LIMIT 1`,
    [lit],
  );
  return r.rows[0]?.law_num ?? null;
}

const BATCH = 256;
const suspects = [];
let changed = 0;
let processed = 0;
for (let i = 0; i < keys.length; i += BATCH) {
  const chunk = keys.slice(i, i + BATCH);
  const { embeddings } = await embedder.embed({ input: chunk, requestId: 'collision-audit' });
  for (let j = 0; j < chunk.length; j++) {
    const k = chunk[j];
    const aTitle = applyLawNameAliases([k], aliases)[0]; // 辞書先の正式名称。
    const aNum = titleToNum.get(aTitle) ?? null;
    const bNum = await nearestNum(embeddings[j]);
    processed += 1;
    if (bNum && aNum && bNum !== aNum) {
      changed += 1;
      const bTitle = numToTitle.get(bNum) ?? '';
      const nk = norm(k);
      // 高リスク＝K が素解決先 B のタイトルに部分一致（K は本来 B を指す名前の可能性）。
      const highRisk = norm(bTitle).includes(nk) || nk.includes(norm(bTitle));
      if (highRisk) {
        suspects.push({ alias: k, dictTarget: aTitle, rawResolve: bTitle });
      }
    }
  }
  console.error(`  進捗 ${processed}/${keys.length}（挙動変化 ${changed} / 高リスク候補 ${suspects.length}）`);
}

await client.end();

console.error(`\n[collision-audit] 完了：挙動変化キー ${changed} / ${keys.length}・高リスク候補 ${suspects.length}`);
process.stdout.write(JSON.stringify(suspects, null, 2) + '\n');
