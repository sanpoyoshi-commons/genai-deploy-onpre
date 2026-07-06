# 開発ドキュメント

本プロジェクトの設計・構成に関する技術ドキュメント集。設計根拠の単一の置き場。

| ファイル | 内容 |
|---|---|
| [repository-structure.md](./repository-structure.md) | 3リポジトリ構成・命名規約・配布形態・ライセンス境界 |
| [licensing.md](./licensing.md) | 本リポの LICENSE / NOTICE / 同梱 OSS ライセンス一覧 |
| [llm-abstraction.md](./llm-abstraction.md) | LLM 抽象化レイヤー（`LLM_BACKEND` 経路切替・OpenAI 互換 IF） |
| [oss-migration.md](./oss-migration.md) | クラウド（AWS 等）→ OSS の置き換えマッピング |
| [database-schema.md](./database-schema.md) | 業務 DB スキーマ（PostgreSQL 7 テーブル + RAG 用 pgvector/pg_bigm） |

関連：運用ガイド（機能 ON/OFF・モデル・更新・ログ等）は [../operations.md](../operations.md)、環境変数は [../env-reference.md](../env-reference.md)、実際の OSS バージョンと配線は repo ルートの `docker-compose.yml`（タグ + SHA 固定・詳細コメント付き）。
