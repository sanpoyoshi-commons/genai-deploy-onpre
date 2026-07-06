# リポジトリ構成

本プロジェクトは3つのリポジトリで構成される。フロントエンド／バックエンドは上流 OSS（`digital-go-jp/genai-web`・`digital-go-jp/genai-ai-api`、いずれも MIT）由来のローカル／オンプレ版で、`-onpre` サフィックスで識別する。

## 1. 3リポジトリ

| リポジトリ | 役割 | 由来 | ライセンス |
|---|---|---|---|
| `genai-web-onpre` | フロントエンド（配信 web） | 上流 `genai-web` の派生（fork） | MIT |
| `genai-ai-api-onpre` | バックエンド API（旧 Lambda 群を単一 Express に集約） | 上流 `genai-web` の Lambda 由来の新規実装 | MIT |
| `genai-deploy-onpre`（本リポ） | docker-compose・OSS スタック設定・配布用ドキュメント | 新規（上流フォークなし・独立リポ） | MIT |

## 2. 命名規約

- 上流名を基底に `-onpre`（on-premise）サフィックスを付与し、ローカル化派生であることを示す
- Gitea（開発）／GitHub（公開）で同一名を使用し参照の混乱を防ぐ

## 3. 配布形態

- **開発時**：3リポを独立してビルド・依存解決
- **配布時**：deploy リポ単独を clone し `docker compose up -d` で web + api + OSS スタックを一括起動
- 個人開発者 1 人が `git clone && docker compose up -d` で動かせることを判断軸とする

## 4. ライセンス境界

- **web / api**：上流フォーク由来。各リポに LICENSE / NOTICE / UPSTREAM を整備（詳細は [licensing.md](./licensing.md)）
- **deploy**：独立リポのため上流追従はなく、同梱 OSS のライセンスを集約する
- 上流 web の一部には非 AWS 環境では提供しない上流由来ファイルがあり、これは web リポ側に閉じる。api / deploy リポにはこれらは含まれない
