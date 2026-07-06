# ライセンス整備

## 1. 本リポ（genai-deploy-onpre）

上流フォークなしの独立リポのため、ライセンス関係はシンプルで自己完結する。

| ファイル | 内容 |
|---|---|
| `LICENSE` | MIT 全文 + 本プロジェクト Copyright |
| `LICENSE-CC-BY` | ドキュメント用 CC BY 4.0 全文 |
| `NOTICE` | 同梱 OSS スタックの構成宣言と各 OSS ライセンス出典 |
| `LICENSES-THIRD-PARTY/` | 同梱 OSS の各ライセンス本文を保全 |

## 2. 同梱 OSS とライセンス

`docker compose` で起動する OSS のライセンス一覧（バージョンは `docker-compose.yml` でタグ + SHA 固定）。

| OSS | 用途 | ライセンス |
|---|---|---|
| PostgreSQL（+ pgvector / pg_bigm） | 業務 DB・ベクトル検索 | PostgreSQL License |
| Ollama | ローカル LLM 推論 | MIT |
| vLLM | GPU LLM 推論（任意） | Apache-2.0 |
| Keycloak | 認証・IdP | Apache-2.0 |
| ElasticMQ | キュー（SQS 互換） | Apache-2.0 |
| nginx | リバースプロキシ・TLS | BSD-2-Clause |
| Mailpit | 開発用 SMTP | MIT |
| SeaweedFS | オブジェクトストレージ（S3 互換） | Apache-2.0 |
| Dozzle | ログ閲覧 UI | MIT |

ローカル LLM／embedding／画像生成のモデルは各モデルの利用規約に従う（同梱せず、利用者が取得）。

## 3. web / api リポ（参考）

上流フォーク由来のため、各リポに以下を整備する：`LICENSE`（MIT）／`LICENSE-CC-BY`（CC BY 4.0）／`NOTICE`（上流出典・派生関係）／`UPSTREAM.md`（取込タグ・SHA・更新手順）／`LICENSES-THIRD-PARTY/`。web リポには非 AWS 環境向け配布では提供しない上流由来ファイルが含まれる（[repository-structure.md](./repository-structure.md) §4）。
