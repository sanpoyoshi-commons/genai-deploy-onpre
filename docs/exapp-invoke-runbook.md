# ExApp ローカル実行配線 e2e ランブック（手動 e2e）

個人開発者が自作の **AI アプリ（ExApp＝外部 REST API）** を登録し、ローカルの本基盤から実際に
呼び出して結果を得る e2e を検証する手順。同期 1 本・非同期 1 本を実機再現する。

> 実 `docker compose up`・DB マイグレーション適用・`.env`/secrets を伴う手順。

## 0. 前提・配線済みの内容

- api：`PostgresApiKeyStore`（ex_app_api_keys テーブル・任意 AES-256-GCM）で apiKey 保存／`createExApp` の
  500 を解消。`exAppInvoker`（同期 outputs／非同期 202→status_url polling／artifacts 退避）を worker に配線。
- web：登録フォームの endpoint 検証を `http://localhost` 等ローカル宛も許容するよう緩和（公開は https 推奨）。
- compose：worker/api に `EXAPP_*`・`ARTIFACTS_BUCKET_NAME`・`EXAPP_APIKEY_ENC_KEY` を配線。検証スタブ
  `JOB_COMPLETE_AFTER` は撤去。サンプル `echo-exapp`（profile `example`）を追加。
- migration：`genai-ai-api-onpre/prisma/migrations/20260602000000_exapp_invoke`（ex_app_api_keys ＋
  invoke_ex_app_histories.status_url / external_request_id）。

## 1. `.env` 設定（手動）

ExApp 実行には queue profile が必須。SSRF ガードは既定で localhost/private を拒否するため、ローカル
echo 検証時のみ明示許可する：

```dotenv
# ローカル ExApp（echo-exapp）宛を許可（既定は安全側＝false）
EXAPP_ALLOW_PRIVATE_ENDPOINTS=true
EXAPP_ENDPOINT_ALLOWLIST=echo-exapp
# apiKey 暗号化（任意・api と worker で同一値）。未設定なら平文保存。
# EXAPP_APIKEY_ENC_KEY=<base64(32B) または hex(64)>
# echo-exapp の apiKey 突合（登録時 apiKey と一致させる場合のみ）
# ECHO_EXAPP_API_KEY=test-key-123
```

## 2. ビルド・マイグレーション適用（手動）

```bash
# api/worker イメージを新コードで再ビルド（exAppInvoker/PostgresApiKeyStore を含む）
docker compose -f docker-compose.yml -f docker-compose.secrets.yml build api worker

# マイグレーション適用（migrate サービス＝secrets overlay 付きで up すると自動適用）
docker compose -f docker-compose.yml -f docker-compose.secrets.yml run --rm migrate
```

> スタックは必ず `-f docker-compose.yml -f docker-compose.secrets.yml` のオーバーレイ付きで起動する
> （素の up は postgres 認証を壊す）。

## 3. 起動（queue ＋ example profile・手動）

```bash
COMPOSE_PROFILES=queue,example \
  docker compose -f docker-compose.yml -f docker-compose.secrets.yml up -d
docker compose ps                 # api / worker / elasticmq / echo-exapp / postgres / seaweedfs
docker compose logs -f worker     # worker_started・exapp ログ確認
```

echo-exapp の内部到達確認（任意）：

```bash
docker run --rm --network genai-deploy-onpre_genai_internal node:24.15.0-alpine \
  node -e "fetch('http://echo-exapp:3000/health').then(r=>r.json()).then(console.log)"
# 期待: { ok: true }
```

## 4. 登録（GUI もしくは API）

GUI：チーム管理 → AI アプリ → 追加。endpoint に下記を設定（apiKey は任意の文字列・`ECHO_EXAPP_API_KEY`
を設定した場合は一致させる）。uiFormat（リクエスト形式）は最小例：

```json
{ "question": { "type": "text", "title": "入力", "required": true } }
```

- **同期テスト用 endpoint**：`http://echo-exapp:3000/sync`
- **非同期テスト用 endpoint**：`http://echo-exapp:3000/async`

登録が 200 で成功すること（旧 500 が解消）。

## 5. 実行 e2e（同期・非同期）

GUI から各アプリを実行（`question` に任意文字列）。または API：

```bash
# 認証トークン取得後、POST /api/exapps/invoke { teamId, exAppId, inputs }
# → 202 accepted。worker が echo-exapp を実際に叩き、履歴を success + outputs へ書き戻す。
```

### 合格条件

- **同期**：実行履歴が `COMPLETED`、`outputs` が `echo: <入力>` になる。
- **非同期**：202 受付後 worker が status_url を polling し、数秒後に履歴が `COMPLETED`、`outputs` が
  `echo: <入力>`、`artifacts` に `echo-result.txt`（getArtifactFile でダウンロード可能）。
- worker ログに `exapp_async_accepted` / `job_completed`、SSRF 拒否（`exapp_endpoint_blocked`）が
  出ていないこと。

## 6. 後片付け

```bash
COMPOSE_PROFILES=queue,example \
  docker compose -f docker-compose.yml -f docker-compose.secrets.yml down
```

## トラブルシュート

- 登録が 500：migration 未適用（ex_app_api_keys 不在）。§2 を実施。
- invoke しても履歴が running のまま：worker 未起動（queue profile 漏れ）か elasticmq 接続不可。
- 履歴が error・worker ログに `exapp_endpoint_blocked`：SSRF 許可漏れ。`EXAPP_ALLOW_PRIVATE_ENDPOINTS=true`
  と `EXAPP_ENDPOINT_ALLOWLIST=echo-exapp` を確認。
- artifacts がダウンロードできない：`ARTIFACTS_BUCKET_NAME` のバケットが seaweedfs-init で作成済か確認。
