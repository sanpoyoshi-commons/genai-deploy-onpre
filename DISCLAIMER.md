# 免責事項 / Disclaimer

## 用途・無保証

- 本配布物は**個人開発者の開発・実験用途**を想定したものです。本基盤上でアプリ開発・
  検証を試すための土台であり、**本番業務での利用は想定していません**。
- 本配布物は MIT License に基づき**現状有姿（AS IS）・無保証**で提供されます。商品性・
  特定目的適合性・非侵害を含む一切の保証はありません。
- **本番業務での利用や、実際の個人情報・機微なデータの取り扱いは想定していません。** そうした
  用途では個人情報保護法などの**法律・ルールを守る義務**が生じますが、本配布物がそれを満たすことは
  **保証しません**（可用性・データ保全も同様）。**守る責任は利用者にあります。** 実運用に持ち込む
  場合は、認証強化・TLS の正式証明書化・バックアップ・監査ログ・脆弱性対応などのハードニングを
  各自の責任で実施してください。
- 既定の自己署名 TLS 証明書・サンプル設定・初期パスワード等は**開発前提**の値です。
  そのまま公開ネットワークに晒さないでください。

## Code Interpreter（任意コード実行）について

- Code Interpreter 機能（`sandbox` profile・**既定 off**）は、入力データを処理するために
  **任意の Python コードを実行**します。nsjail による多層防御（namespace 隔離・network off・
  rootfs read-only・nobody 降格・内側 seccomp・資源上限）で絞っていますが、本環境の制約上、
  外側コンテナは **seccomp=unconfined ＋ 4 cap** という privileged 寄りの posture で動作します。
- 本機能は **localhost・opt-in・無保証**前提の開発／実験用途であり、**本番業務・公開ネットワーク・
  マルチテナントでの任意コード実行は想定していません**。有効化には `SANDBOX_ACCEPT_RISK=1` の
  明示が必要です（未設定なら起動しません）。
- posture・残存リスク・受容判断は `docs/sandbox-acceptance-decision.md` および
  `docs/sandbox-threat-model.md` に集約しています。本番相当で使う場合は gVisor／microVM 等への
  強化と運用監視を**各自の責任**で実施してください。

## 第三者・上流プロジェクトとの関係（非提携）

- 本プロジェクトは**独立した非公式プロジェクト**です。同梱・派生する各 OSS、および
  上流プロジェクト（デジタル庁の `genai-ai-api` / `genai-web` 等）とは**無関係であり、
  提携・推奨・公認を受けていません（non-affiliated, not endorsed）**。
- 本プロジェクトに関する問い合わせ・不具合報告・脆弱性報告を、上流各 OSS や
  デジタル庁へ行わないでください。窓口は本リポジトリです。
- 各 OSS および上流プロジェクトの著作権・ライセンス表示は `NOTICE` /
  `LICENSES-THIRD-PARTY/` / `UPSTREAM.md` に保持しています（帰属義務は遵守します）。
- 本プロジェクトの UI・ドキュメント・コード（型定義・テスト等）には、上流
  （`genai-web` / `genai-ai-api`）由来の名称・製品名（例：「源内」、デジタル庁の
  プロジェクト名等）が、**互換性・識別の目的で残存**している場合があります。これらは
  上流の表記であり、本プロジェクトがその名称・商標に関する権利を主張するものでも、
  デジタル庁との提携・公認を示すものでもありません。

---

## English (summary)

- This distribution is intended for **individual developers' development and
  experimentation**. It is **not intended for production use**.
- Provided **AS IS, without warranty of any kind** under the MIT License. Use is
  entirely **at your own risk**; production use, handling of sensitive data, regulatory
  compliance, availability, and data durability are out of scope and your responsibility.
- This is an **independent, unofficial project**. It is **not affiliated with or endorsed
  by** the bundled OSS projects or the upstream projects (Digital Agency's `genai-ai-api`
  / `genai-web`, etc.). Please do **not** contact those upstream projects or the Digital
  Agency regarding this project. Required copyright/license attributions are retained in
  `NOTICE`, `LICENSES-THIRD-PARTY/`, and `UPSTREAM.md`. Upstream-derived product names
  (e.g. "源内" / Genai, Digital Agency project names) may remain in the UI, documentation,
  and code for compatibility and identification; these are upstream designations and do
  not imply any claim of rights or any affiliation with or endorsement by the Digital Agency.
