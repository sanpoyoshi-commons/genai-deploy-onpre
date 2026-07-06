# Security Policy / セキュリティポリシー

## サポート対象バージョン / Supported Versions

最新の `main` を基準にメンテナンスしています。古いバージョンへの個別バックポートは
基本的に行いません。
The latest `main` branch is maintained. Backports to older versions are generally not provided.

## 脆弱性の報告 / Reporting a Vulnerability

**公開 Issue では報告しないでください。** 脆弱性は非公開で受け付けます。

- 本リポジトリの **Security → Report a vulnerability**（GitHub Private Vulnerability
  Reporting）からご報告ください。メールでの個別窓口は設けていません。
- 本リポジトリは独立した非公式の配布物です（[DISCLAIMER.md](../DISCLAIMER.md) 参照）。
  同梱する各 OSS 自体の脆弱性は、それぞれの上流プロジェクトへご報告ください。

Please report privately via this repository's **Security → Report a vulnerability** (GitHub Private
Vulnerability Reporting). We do not provide an email contact. This is an independent, unofficial
distribution; vulnerabilities in the bundled OSS components themselves should be reported to their
respective upstream projects.

報告には以下を含めてください / Please include:

- 影響を受けるコンポーネント・バージョン
- 再現手順または PoC
- 想定される影響範囲

## セキュリティ対策の状況 / Security Measures

本リポジトリ（デプロイ／インフラ層）には以下を適用しています。

- **コミット時の自動検査**：Gitleaks（`pre-commit`、秘密情報の平文混入）。
- **プッシュ時の自動検査**（`pre-push`。uvx / docker 導入時に実行され、未導入の環境では
  自動でスキップされます）：
  - **Checkov**（IaC：Dockerfile / docker-compose の設定ミス。設定は `.checkov.yaml`）
  - **Trivy**（ファイルシステムの脆弱性 / 設定ミス / 秘密。抑制は `.trivyignore`）
  - **OSV-Scanner**（依存の既知脆弱性）
- **設計観点のレビュー**：OWASP Top 10:2025 の観点でインフラ構成・権限境界・secrets の
  取り扱いをレビューし、シグネチャ系スキャナが苦手な設計・ロジック面を補完します。
- **ハードニング**：docker secrets による機密分離（`docker-compose.secrets.yml` オーバーレイ）、
  自己署名 TLS、SeaweedFS の at-rest 暗号化、コードインタプリタ用サンドボックスの最小権限化
  （脅威モデル＝[docs/sandbox-threat-model.md](../docs/sandbox-threat-model.md)、受容判断＝
  [docs/sandbox-acceptance-decision.md](../docs/sandbox-acceptance-decision.md)）。

> 本配布物は個人開発者の開発・実験用途を想定しています。本番業務での利用は想定しておらず、
> 動的スキャン（DAST）やペネトレーションテストは、導入する場合は各自の責任で実施してください
> （[DISCLAIMER.md](../DISCLAIMER.md)）。
