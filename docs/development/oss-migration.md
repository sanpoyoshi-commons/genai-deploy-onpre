# クラウド → OSS 置き換えマッピング

上流はクラウド（AWS／Azure／GCP）依存のサービスを使う。本プロジェクトはこれらをローカルで動作する OSS に置き換える。下表は本スタックが実際に同梱する中核の対応関係。

## 1. AWS → OSS（本スタックの中核）

| クラウド | 用途 | OSS 代替 |
|---|---|---|
| Cognito | 認証・JWT 発行・OIDC | Keycloak |
| DynamoDB | 業務 DB（KV/NoSQL） | PostgreSQL 16 + pgvector |
| S3 | オブジェクトストレージ・presigned URL | SeaweedFS（S3 互換） |
| Bedrock | LLM 推論 | LLM 抽象化レイヤー（Ollama / vLLM / クラウド API） |
| Knowledge Base + OpenSearch | RAG（検索拡張生成） | pgvector + pg_bigm + 自前 RAG パイプライン |
| Transcribe | 音声→テキスト | faster-whisper（speaches） |
| SQS | 非同期キュー | ElasticMQ（SQS 互換） |
| SES | メール送信 | Mailpit（開発）／外部 SMTP（本番） |
| CloudWatch | ログ閲覧 | Dozzle（コンテナログ UI） |
| KMS | 暗号化・鍵管理 | SeaweedFS の at-rest 暗号化／Docker secrets |
| SSM Parameter Store | 設定・シークレット | `.env` / Docker secrets |

LLM 抽象化レイヤーの詳細は [llm-abstraction.md](./llm-abstraction.md)、各 OSS のバージョン固定は `docker-compose.yml` を参照。

## 2. 選定方針

- active development されている OSS のみ採用（メンテナンスモード入りは不可）
- ライセンスは Apache-2.0 / MIT / BSD 系を優先
- バージョンはタグ + SHA で固定し、脆弱性情報を継続監視
- 個人開発者 1 人が `docker compose up -d` で動かせるかを判断軸とする

## 3. クラウド LLM の取り扱い

Azure OpenAI / Gemini Enterprise 等のクラウド LLM は、LLM 抽象化レイヤーのクラウド経路（`LLM_BACKEND=openai|anthropic|gemini|bedrock`）として統一的に扱う。ローカル既定（Ollama）を壊さず、必要時に API キー設定で切り替えられる。
