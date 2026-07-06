// 最小サンプル ExApp（AI アプリ＝外部 REST API）。
// ローカル版の ExApp 実行配線 e2e 検証用。依存ゼロ（Node 標準のみ）。
//
// プロトコル（AIアプリAPI仕様）:
//   - 同期:   POST /sync   ← { inputs } → 200 { outputs }
//   - 非同期: POST /async  ← { inputs } → 202 { outputs, request_id, status, status_url }
//             GET  /status/:id (x-api-key) → IN_PROGRESS →（数回後）COMPLETED { outputs, artifacts }
//   - 認証:   x-api-key ヘッダを検証（EXAPP_EXPECTED_API_KEY 設定時のみ・不一致は 401）
//
// 環境変数:
//   PORT（既定 3000）/ EXAPP_EXPECTED_API_KEY（任意・設定時のみ検証）/ ASYNC_COMPLETE_AFTER（既定 2）

import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';

const PORT = Number(process.env.PORT ?? 3000);
const EXPECTED_API_KEY = process.env.EXAPP_EXPECTED_API_KEY ?? '';
const ASYNC_COMPLETE_AFTER = Number(process.env.ASYNC_COMPLETE_AFTER ?? 2);

/** request_id → { inputs, polls } の簡易ジョブストア（プロセス内・揮発）。 */
const jobs = new Map();

function readJson(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', (c) => {
      body += c;
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(body || '{}'));
      } catch {
        resolve({});
      }
    });
  });
}

function send(res, status, obj) {
  const payload = JSON.stringify(obj);
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(payload);
}

function checkApiKey(req, res) {
  if (!EXPECTED_API_KEY) return true; // 検証無効
  if (req.headers['x-api-key'] === EXPECTED_API_KEY) return true;
  send(res, 401, { error: { message: 'invalid api key' } });
  return false;
}

/** inputs から代表テキストを取り出して echo 文を作る。 */
function echoText(inputs) {
  const first = inputs && typeof inputs === 'object' ? Object.values(inputs).find((v) => typeof v === 'string') : null;
  return `echo: ${first ?? JSON.stringify(inputs ?? {})}`;
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // ヘルスチェック。
  if (req.method === 'GET' && url.pathname === '/health') {
    return send(res, 200, { ok: true });
  }

  // 同期：即 outputs を返す。
  if (req.method === 'POST' && url.pathname === '/sync') {
    if (!checkApiKey(req, res)) return;
    const body = await readJson(req);
    return send(res, 200, { outputs: echoText(body.inputs) });
  }

  // 非同期：202＋status_url を返し、以後 polling で COMPLETED にする。
  if (req.method === 'POST' && url.pathname === '/async') {
    if (!checkApiKey(req, res)) return;
    const body = await readJson(req);
    const requestId = randomUUID();
    jobs.set(requestId, { inputs: body.inputs, polls: 0 });
    return send(res, 202, {
      outputs: 'リクエストを受け付けました',
      request_id: requestId,
      status: 'PENDING',
      status_url: `/status/${requestId}`,
    });
  }

  // 非同期ステータス確認。
  if (req.method === 'GET' && url.pathname.startsWith('/status/')) {
    if (!checkApiKey(req, res)) return;
    const requestId = url.pathname.slice('/status/'.length);
    const job = jobs.get(requestId);
    if (!job) {
      return send(res, 404, { error: { message: 'unknown request_id' } });
    }
    job.polls += 1;
    if (job.polls < ASYNC_COMPLETE_AFTER) {
      return send(res, 200, {
        request_id: requestId,
        status: 'IN_PROGRESS',
        progress: `処理中... ${job.polls}/${ASYNC_COMPLETE_AFTER}`,
      });
    }
    // 完了：outputs ＋ サンプル artifact（base64 のテキストファイル）。
    const artifactContents = Buffer.from(`artifact for: ${echoText(job.inputs)}`, 'utf8').toString('base64');
    return send(res, 200, {
      request_id: requestId,
      status: 'COMPLETED',
      outputs: echoText(job.inputs),
      artifacts: [{ contents: artifactContents, display_name: 'echo-result.txt' }],
    });
  }

  send(res, 404, { error: { message: 'not found' } });
});

server.listen(PORT, () => {
  // biome-ignore lint/suspicious/noConsole: サンプルサーバの起動ログ。
  console.log(`echo-exapp listening on :${PORT} (expected_api_key=${EXPECTED_API_KEY ? 'set' : 'none'})`);
});
