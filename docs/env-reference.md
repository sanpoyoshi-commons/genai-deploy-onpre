# 環境変数リファレンス（.env / docker-compose）

`docker compose up -d` は **すべての設定に既定値**を持つため、`.env` は機密値だけ変えれば動きます。
本書は「何を弄れるか」を用途別にまとめた一覧です。各値は `docker-compose.yml` の
`${VAR:-default}` と一致しています（`.env` に書かなければ既定で動作）。

- 機密値（パスワード・API キー・暗号鍵）は `.env` 直書きより **docker secrets 推奨**（[セキュリティハードニング](#12-機密値と-secrets)）。
- `.env.example` をコピーして `.env` を作成します：`cp .env.example .env`（編集は手動）。
- 機能の ON/OFF は基本 `COMPOSE_PROFILES`（[§8](#8-機能トグルprofile)）。個別 env は微調整用です。

---

## 1. ネットワーク / 公開ポート

| 変数 | 既定 | 説明 |
|---|---|---|
| `HTTP_BIND` | `127.0.0.1` | 全公開ポートの bind アドレス。LAN 公開時は実 IP（例 `192.168.x.x`）に。 |
| `HTTP_PORT` / `HTTPS_PORT` | `80` / `443` | nginx の HTTP / HTTPS。 |
| `S3_PORT` | `8443` | SeaweedFS(S3) 公開ポート。`S3_PUBLIC_ENDPOINT` の `:port` と一致させる。 |
| `KEYCLOAK_HTTP_PORT` | `8088` | Keycloak 管理コンソール（localhost のみ）。 |
| `MAILPIT_UI_PORT` | `8025` | Mailpit Web UI。 |
| `DOZZLE_PORT` | `9980` | Dozzle ログ閲覧 UI。 |
| `LOG_LEVEL` | `info` | api / worker のログレベル。 |

## 2. 認証（Keycloak）

| 変数 | 既定 | 説明 |
|---|---|---|
| `KEYCLOAK_HOSTNAME` | `https://localhost/auth` | 外部到達ホスト名。**変更時は `KEYCLOAK_ISSUER` も連動**（token の `iss` と一致が必要）。 |
| `KEYCLOAK_ADMIN` | `admin` | ブートストラップ管理者ユーザー名。 |
| `KEYCLOAK_ISSUER` | `https://localhost/auth/realms/genai-realm` | JWT 検証の issuer。通常は `KEYCLOAK_HOSTNAME` に合わせる（内部既定で十分）。 |
| `KEYCLOAK_JWKS_URI` / `KEYCLOAK_AUDIENCE` | コンテナ内部既定 | JWKS 取得 URL / 受け入れ aud。通常変更不要。 |
| `KEYCLOAK_ADMIN_BASE_URL` / `_REALM` / `_CLIENT_ID` | 内部既定 | Admin REST 連携（teams CRUD）。非秘密の固定値。 |

> `KEYCLOAK_ADMIN_PASSWORD` / `KEYCLOAK_DB_PASSWORD` / `KEYCLOAK_ADMIN_CLIENT_SECRET` は機密 → [§12](#12-機密値と-secrets)。

## 3. 業務 DB（PostgreSQL）

| 変数 | 既定 | 説明 |
|---|---|---|
| `POSTGRES_DB` / `POSTGRES_USER` | `genai` / `genai` | DB 名・ユーザー。 |
| `POSTGRES_PASSWORD` | （必須） | 機密 → [§12](#12-機密値と-secrets)。`DATABASE_URL` はこの値から自動組み立て（直接書かない）。 |

## 4. LLM（チャット / 生成）

| 変数 | 既定 | 説明 |
|---|---|---|
| `LLM_BACKEND` | `ollama` | **経路選択の主役**。`ollama`(ローカル) / `vllm` / `openai` / `anthropic` / `gemini` / `bedrock`。 |
| `LLM_DEFAULT_MODEL` | `gemma4:e2b` | リクエスト未指定時の既定モデル（空なら `MODEL_IDS[0]`）。 |
| `LLM_DEFAULT_TIMEOUT_MS` | `1800000` | 推論タイムアウト（30 分）。CPU 推論で重いモデル/大きいプロンプトが完走できるよう長め。api 起動時に undici(fetch) の既定 300s も本値へ揃える。nginx `proxy_read_timeout` とも整合させる（短い方が律速）。 |
| `LLM_DEFAULT_TEMPERATURE` | 空 | 既定サンプリング温度（0〜2）。空＝バックエンド既定（ollama OpenAI 互換は 1.0）。リクエストが温度を指定しない全 chat に効く既定値。**ダイアグラム生成は web が個別に低温（0.2）を送る**ため本値の設定は不要（diagram 用途では本値より優先される）。 |
| `MODEL_IDS` | JSON 配列 | web セレクタ＋api 許可リスト（単一の真実）。変更は nginx/api 再起動で反映。 |
| `OLLAMA_BASE_URL` | `http://ollama:11434/v1` | 同梱 ollama を指す。外部 ollama 利用時のみ変更。 |
| `OLLAMA_DEFAULT_CHAT_MODEL` | `gemma4:e2b` | ollama 経路の既定モデル。 |
| `OLLAMA_CONTEXT_LENGTH` | `4096` | ollama の既定 context 長（トークン）。既定 4096 はダイアグラム生成等の大きいプロンプト（〜7千トークン）を切り詰め図が出ない。十分な RAM（16GB+ 目安）があれば `8192` 等に上げると解消（KV キャッシュ分メモリ増・低メモリ機ではスワップで逆効果）。 |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | ollama が同時常駐するモデル数の上限。既定 1（低 RAM 単一ボックス向け）。1 なら新モデルのロード時に旧モデルを自動アンロードするため、セレクタでモデルを切り替えても二重常駐で OOM/スワップ枯渇しない。RAM に余裕（16GB+）があれば 2 以上に上げてよい。 |

クラウド / vLLM / Bedrock の API キー・モデル・region は `.env.example` のコメント参照（キーは機密＝既定空）。

## 5. RAG（検索拡張生成）

> RAG は `--profile embedding` が必要（tei サービス起動）。すべて既定で動作する微調整ノブ。

| 変数 | 既定 | 説明 |
|---|---|---|
| `RAG_TOP_M` | `10` | 最終返却チャンク数。 |
| `RAG_FETCH_K` | `20` | ベクトル/全文の各取得数。 |
| `RAG_RRF_K` | `60` | 順位融合(RRF)定数。 |
| `RAG_MAX_CHUNK_SIZE` | `1000` | 1 チャンク最大文字数。 |
| `RAG_CHUNK_OVERLAP` | `120` | 隣接チャンクのオーバーラップ。 |
| `RAG_BIGM_SIMILARITY_LIMIT` | `0.2` | pg_bigm 全文しきい値（下げ＝再現↑/精度↓）。 |
| `EMBEDDING_BACKEND` | `tei` | 埋め込み経路（`tei` ローカル / `openai`）。 |
| `EMBEDDING_MODEL_PATH` | `/models/ruri-v3-310m-onnx-int8` | int8 量子化版（高速・精度 -10pt 許容）。fp32 は `/models/ruri-v3-310m-onnx`。 |
| `EMBEDDING_MAX_BATCH_TOKENS` / `_MAX_CLIENT_BATCH_SIZE` | `4096` / `8` | TEI warmup バッチ。低メモリ機の OOM 回避に絞る。 |
| `EMBEDDING_DEFAULT_TIMEOUT_MS` | `300000` | 埋め込みタイムアウト。 |

### リランカ（精度向上・`--profile rerank` 必要）

| 変数 | 既定 | 説明 |
|---|---|---|
| `RERANK_ENABLED` | `false` | cross-encoder で Hit@1 向上（法令 bench 45%→90%）。`true` ＋ tei-reranker 起動で有効。 |
| `RERANK_CANDIDATES` | `20` | rerank 候補プール（最終は `RAG_TOP_M` に絞る）。 |
| `RERANK_DEFAULT_TIMEOUT_MS` | `60000` | rerank タイムアウト。 |
| `RERANKER_MODEL_PATH` | `/models/ruri-v3-reranker-310m-onnx-int8` | int8 版。fp32 は `/models/ruri-v3-reranker-310m-onnx`。 |
| `RERANKER_MAX_BATCH_TOKENS` / `_MAX_CLIENT_BATCH_SIZE` | `4096` / `512` | TEI バッチ。 |
| `RERANK_BACKEND` / `RERANK_BASE_URL` | 内部既定 | 通常変更不要。 |

## 6. 画像生成（stable-diffusion.cpp・`--profile image`）

| 変数 | 既定 | 説明 |
|---|---|---|
| `IMAGE_BACKEND` | `sdcpp` | 経路選択（現状 sdcpp のみ）。 |
| `SDCPP_MODEL_FILE` | `v1-5-pruned-emaonly.safetensors` | `./sdcpp/models/` に置いたモデルファイル名。 |
| `IMAGE_GENERATION_TIMEOUT_MS` / `IMAGE_POLL_INTERVAL_MS` | `300000` / `1000` | CPU 推論用に長め。 |
| `IMAGE_GENERATION_MODEL_IDS` / `IMAGE_DEFAULT_MODEL` | `[]` / 空 | 許可リスト / 既定モデル。 |

## 7. 文字起こし（faster-whisper・`--profile transcribe`）

| 変数 | 既定 | 説明 |
|---|---|---|
| `WHISPER_MODEL` | `deepdml/faster-whisper-large-v3-turbo-ct2` | HF リポ名。**事前 pull 必須**（自動 DL されない）。 |
| `WHISPER_BASE_URL` | `http://whisper:8000/v1` | speaches のベース URL。 |
| `WHISPER_LANGUAGE` | 空（自動検出） | 言語ヒント。 |
| `WHISPER_TIMEOUT_MS` | `600000` | 長尺見込みのタイムアウト。 |

## 8. 機能トグル（profile）

| 変数 | 既定 | 説明 |
|---|---|---|
| `COMPOSE_PROFILES` | `llm` | 起動する機能群。`llm,embedding,rerank,image,transcribe,queue,sandbox` から選ぶ。web メニューも自動連動。 |
| `ENABLED_USE_CASES` | 空 | profile 自動連動を上書きする上級者向け JSON（指定時優先）。 |

## 9. Code Interpreter（任意コード実行・`--profile sandbox`）

> 任意 Python 実行。`SANDBOX_ACCEPT_RISK=1` を明示しないと起動中止。詳細・脅威モデルは
> [sandbox-acceptance-decision.md](./sandbox-acceptance-decision.md) / [sandbox-threat-model.md](./sandbox-threat-model.md)。

| 変数 | 既定 | 説明 |
|---|---|---|
| `SANDBOX_ACCEPT_RISK` | 空 | `1` でリスク受容（必須・二段確認）。 |
| `SANDBOX_BASE_URL` | `http://sandbox:8080` | api → sandbox 委譲先。 |
| `SANDBOX_MAX_FILE_BYTES` / `SANDBOX_MAX_OUTPUT_BYTES` | `8388608` / `262144` | sandbox 側の入出力上限。 |
| `SANDBOX_MAX_CONCURRENCY` / `SANDBOX_WALL_MS` | `4` / `60000` | 同時実行 / 壁時計上限。 |
| `CODE_INTERPRETER_MODEL` | 空 | コード生成 LLM（モデル階層連動・空なら `LLM_DEFAULT_MODEL`）。 |
| `CODE_INTERPRETER_TIMEOUT_MS` | `60000` | api 側 実行タイムアウト。 |
| `CODE_INTERPRETER_MAX_ATTEMPTS` | `3` | 生成リトライ回数。 |
| `CODE_INTERPRETER_MAX_FILE_BYTES` | `26214400` | 入力ファイル合計上限（api 側）。 |

## 10. ExApp（追加 AI アプリ・`--profile queue`）

| 変数 | 既定 | 説明 |
|---|---|---|
| `SQS_ENDPOINT` / `EXAPP_QUEUE_URL` | ElasticMQ 既定 | 非同期キュー。 |
| `EXAPP_ALLOW_PRIVATE_ENDPOINTS` / `EXAPP_ENDPOINT_ALLOWLIST` | `false` / 空 | SSRF ガード。ローカル ExApp を叩くには `true`＋allowlist。 |
| `EXAPP_HTTP_TIMEOUT_MS` | `30000` | 外部呼び出しタイムアウト。 |
| `EXAPP_ARTIFACT_THRESHOLD_BYTES` | `10240` | これ超の出力は artifacts バケットへ退避。 |
| `EXAPP_APIKEY_ENC_KEY` | 空 | apiKey 暗号鍵（任意）。設定時は worker と同一値必須 → 機密扱い [§11](#11-機密値と-secrets)。 |

## 11. オブジェクトストレージ（SeaweedFS / S3）

| 変数 | 既定 | 説明 |
|---|---|---|
| `S3_PUBLIC_ENDPOINT` | `https://localhost:8443` | presigned URL のブラウザ到達用。LAN 公開時は実 IP/FQDN に。 |
| `S3_INTERNAL_ENDPOINT` | `http://seaweedfs:8333` | 内部直結（通常変更不要）。 |
| `S3_REGION` / `S3_ACCESS_KEY_ID` | `us-east-1` / `genai-s3-dev-key` | 署名 region / アクセスキー。 |
| `FILE_BUCKET_NAME` / `AUDIO_BUCKET_NAME` / `ARTIFACTS_BUCKET_NAME` | `genai-*` | バケット名。 |
| `API_JSON_BODY_LIMIT` | `10mb` | api リクエストボディ上限（大きい添付で 413 のとき引き上げ）。 |

> `S3_SECRET_ACCESS_KEY` は機密 → [§12](#12-機密値と-secrets)。

## 12. 機密値と secrets

以下は `.env` 直書きも可能ですが、**本番は docker secrets 推奨**（`docker-compose.secrets.yml` オーバーレイ）：

| 機密変数 | dev 既定 | 本番 |
|---|---|---|
| `POSTGRES_PASSWORD` / `KEYCLOAK_DB_PASSWORD` / `KEYCLOAK_ADMIN_PASSWORD` | `changeme` | **必ず変更**。secrets ファイル化。 |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | `genai-admin-dev-secret-change-me` | `.env` 方式では `gen-secrets.sh` 実行時にレンダリング実体（realm import）の生成値へ**自動整合**（未設定・空・dev 既定値のとき）。独自値にする場合は Keycloak 側 client secret も一致させる。 |
| `S3_SECRET_ACCESS_KEY` | `genai-s3-dev-secret-change-me` | `.env` 方式では `gen-secrets.sh` 実行時に生成値へ**自動整合**（`secrets/s3.config.json` と一致）。独自値にする場合は同ファイルと一致させる。 |
| `EXAPP_APIKEY_ENC_KEY` | 空（平文保存） | 暗号化する場合に設定（api/worker 同一値）。 |
| クラウド LLM の `*_API_KEY` | 空 | 利用時に設定（`.env.example` には書かない）。 |

secrets 化の手順：

```bash
./scripts/gen-secrets.sh        # secrets/* を生成（手動・.gitignore）
docker compose -f docker-compose.yml -f docker-compose.secrets.yml up -d
```

詳細は [docs/operations.md（パスワードの扱い）](operations.md#パスワードの扱いenv-と-docker-secrets) を参照。
