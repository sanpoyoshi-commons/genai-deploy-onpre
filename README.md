# genai-deploy-onpre

`genai-web-onpre` および `genai-ai-api-onpre` をローカル環境で動作させる
ための配布物（docker-compose.yml 等の設定ファイル群）を提供します。

## 概要

個人開発者が単一のホスト上で `docker compose up` によりローカル AI 基盤を起動し、
その上でアプリ開発・実験を行えることを目指す配布物です。

本リポジトリ自体は上流フォークを含まない独立リポジトリです。

> **免責**：本配布物は**開発・実験用**の無保証ツールです。**本番業務での利用や、実際の個人情報・
> 機微なデータの取り扱いは想定していません**（利用は自己責任）。また本プロジェクトは同梱・派生 OSS や
> 上流（デジタル庁の `genai-ai-api` / `genai-web` 等）とは**無関係・非公式**です。
> 免責の全文は [DISCLAIMER.md](DISCLAIMER.md) を参照してください。

> **運用・詳細**：機能の ON/OFF（プロファイル）、モデル選定、更新、ログ閲覧、パスワードの扱い等の
> 運用手順は **[docs/operations.md](docs/operations.md)** にまとめています。本書は最短の起動までを扱います。

> **上流オリジナルとの違い**：クラウド前提の上流（`genai-web` / `genai-ai-api`）との差分と、そこから
> 生じるオンプレ固有の使い方（招待制のユーザー管理・メール送信等）は
> **[docs/onpre-vs-upstream.md](docs/onpre-vs-upstream.md)** にまとめています。

## システム要件（メモリの目安）

ローカル AI 基盤は、**埋め込み（embedding）モデルとローカル LLM がそれぞれ常駐で
大きなメモリを占有**します。起動するプロファイルを増やすほど必要メモリは増えます。

- **インフラ系のみ**（postgres / keycloak / seaweedfs / nginx / api 等）：数 GB 程度。
- **chat LLM（`--profile llm` の ollama）**：モデル次第。例として 7B 級（`mistral:7b` 等）は
  常駐 5〜6 GB、3B 級（`llama3.2:3b` 等）でも約 2 GB。
- **embedding（`--profile embedding` の tei＝ruri-v3-310m）**：常駐で約 1〜2 GB。RAG（文書検索）を
  使うときだけ起動します（既定の chat では起動しません）。

> **重要（実測）**：メモリ約 8 GB のホストでは、**tei（embedding）とローカル LLM の同時常駐は
> 成立しません**。tei 稼働中は空きが逼迫し、7B モデルは OOM（`llama runner process ... exit
> code -1`）、3B モデルでもスワップ多発でロードがタイムアウトしました。tei を停止すれば
> LLM は正常に動作します（逆も同様）。
>
> **RAG（embedding 検索）と chat LLM を同時に使う構成**（`COMPOSE_PROFILES=llm,embedding`）
> では、**16 GB 以上**を推奨します。8 GB 級ホストでは、使うプロファイル／モデルを絞るか、
> より小さい LLM を選んでください。
>
> メモリ不足の兆候：応答が異様に遅い／`llama runner process has terminated with exit code -1`／
> ollama のモデルロードがタイムアウトする。`free -h` で空き（available）と Swap 使用量を確認できます。

## 関連リポジトリ

- `genai-web-onpre`（Web フロントエンド）
- `genai-ai-api-onpre`（AI アプリ API）

本配布物は `genai-ai-api-onpre` を同階層（`../genai-ai-api-onpre`）に配置して
api コンテナをビルドします。

## 初期設定（起動前の準備）

前提：Docker Engine（Docker Desktop 非依存）＋ 本リポジトリ clone 済み。**以下のコマンドは、特記なき限り deploy リポジトリ直下（`~/work/genai-deploy-onpre`）で実行します。**

> Docker / WSL2(Windows11) / git の導入からゼロで始める場合は、先に
> **[前提環境のセットアップ（docs/prerequisites.md）](docs/prerequisites.md)** を参照してください
> （Windows11→WSL2→Ubuntu→更新/セキュリティ→Docker Engine→git→clone を通しで案内）。

最初の起動の前に、以下を順に実行します。

```bash
# 1. 設定ファイルを作成（.env を手動作成。テンプレートは .env.example、各変数は docs/env-reference.md 参照）
cp .env.example .env
# エディタで .env を編集（パスワード・ポート・モデル一覧などを設定）

# 2. 自己署名 TLS 証明書を生成（初回のみ）
./scripts/gen-certs.sh
#   LAN 公開時は LAN IP を SAN に追加：HOST_IP=192.168.1.50 ./scripts/gen-certs.sh

# 3. 秘密値・設定の実体を生成（初回のみ・最初の起動前に必須）
#    各パスワード・Keycloak realm import（初回管理者 admin 含む）・SeaweedFS S3 認証・
#    Dozzle ユーザーを secrets/ 等に生成します（.gitignore 対象。初回ログイン用パスワードもここ）。
./scripts/gen-secrets.sh

# 4. Web フロントエンドをビルドして web/ へ配置（初回・genai-web-onpre 更新時）
#    本リポジトリは web のビルド済み成果物を同梱しない。Docker 内でビルドするためホストに node 不要。
./scripts/build-web.sh

# 5. カスタムイメージを初回ビルド（postgres=pgvector/pg_bigm・api/migrate=../genai-ai-api-onpre）。
docker compose build
```

> **パスワード方式は最初に決める**：既定は `.env` のパスワードで動きます。よりセキュアに、
> パスワードを環境変数へ出さない **docker secrets**（任意）も選べます。**どちらか一方を使い続け、
> あとで切り替えるには DB volume の初期化（`down -v`＝データ消去）が必要**です（切り替えるなら
> データを貯める前＝実験段階のうちに）。選び方・内訳は
> [docs/operations.md（パスワードの扱い）](docs/operations.md#パスワードの扱いenv-と-docker-secrets)。

### 起動後に必要な投入（チェックリスト）

起動（次節）の直後に、使う機能に応じて以下を投入します（コマンドは起動後・各リンク先）。

- **チャットを使う**：LLM モデルを ollama に **pull**（重みは同梱しない）。既定 `gemma4:e2b`。
  → [モデル選定（operations.md）](docs/operations.md#chat-llm-モデルの選定ハードウェア階層別メニュー)
- **法令 RAG を使う（任意）**：法令データを pgvector へ投入（事前ビルド dump 取得／自前 ingest）。
  → [docs/law-rag-setup.md](docs/law-rag-setup.md)
- **機能（RAG／画像／文字起こし／Code Interpreter 等）の ON/OFF**：プロファイルで切り替え（既定はチャットのみ）。
  → [プロファイル（operations.md）](docs/operations.md#プロファイル機能の-onoff)

## 起動

```bash
# 起動（既定＝チャットのみ。機能追加はプロファイル参照）
docker compose up -d

# 起動状態の確認（healthy になるまで待つ）
docker compose ps
```

> docker secrets 方式を選んだ場合は 2 ファイル指定で起動します：
> `docker compose -f docker-compose.yml -f docker-compose.secrets.yml up -d`
> （詳細・注意は [operations.md](docs/operations.md#パスワードの扱いenv-と-docker-secrets)）。

### 起動後の初期投入

```bash
# チャット用モデルを pull（既定モデル。他の選択肢は operations.md のモデル選定）
docker compose --profile llm exec ollama ollama pull gemma4:e2b
```

法令 RAG を使う場合は [docs/law-rag-setup.md](docs/law-rag-setup.md) の手順でデータを投入します（任意）。

### 停止

```bash
docker compose down
```

> `COMPOSE_PROFILES` で機能を起動した後の停止は、**全 profile を前置**しないと profile 側サービス
> （`tei`／`whisper`／`worker` 等）が落ち残ります。データ（volume）は `down` では消えません
> （完全消去は `down -v`＝**データロスト**）。詳細は
> [プロファイル（operations.md）](docs/operations.md#プロファイル機能の-onoff)。

### 初回ログイン（管理者アカウント）

起動直後にすぐログインできるよう、認証基盤（Keycloak）の `genai-realm` に
**初回管理者（SystemAdmin）** を 1 名、自動で投入します。手作業は不要です
（初期設定の `./scripts/gen-secrets.sh` が初期パスワードを生成し、realm import に焼き込みます）。

- **ユーザー名**：`admin`
- **初期パスワード**：`secrets/keycloak_admin_user_password` の中身（`gen-secrets.sh` が生成。控えておく）
- **権限**：`SystemAdmin` グループ（アプリ全体の管理者）

> このアカウントは **アプリ（`genai-realm`）の管理者** です。Keycloak 自体の管理コンソール
> （master realm のブートストラップ管理者 `KEYCLOAK_ADMIN`）とは別物です。両者を混同しないでください。

初回投入は **realm を初めて作成する起動（fresh deploy）でのみ** 行われます
（`--import-realm` は既存 realm を上書きしません）。そのため `gen-secrets.sh` は
**最初の `docker compose up` の前に必ず実行**してください。

運用では、初回ログイン後に **この `admin` のパスワードを変更** するか、
**担当者個人の SystemAdmin アカウントを別途作成** することを推奨します
（このアカウントは恒久管理者として残ります）。

## ステータス

本配布物は個人開発者の開発・実験用途を想定した、現在も開発途上の
ソフトウェアです。**本番業務での利用は想定していません**（現状有姿・無保証。
法令遵守・可用性・データ保全は対象外で、責任は利用者にあります。詳細は
[DISCLAIMER.md](DISCLAIMER.md)）。

本番業務・組織導入など「実験を卒業」する段階になったら、本オンプレ配布物ではなく
上流オリジナル（クラウド前提）の公式構成への乗り換えを推奨します
（[docs/cloud-migration.md](docs/cloud-migration.md)）。

## 開発者向け

このリポジトリを clone してローカルで開発・カスタマイズする場合の補助として、以下を
用意しています。

- **コミット前のシークレット検査**：[.pre-commit-config.yaml](.pre-commit-config.yaml)（gitleaks）
  でコミット直前に秘密情報の平文混入を検査します。push 時には Checkov／Trivy／OSV-Scanner も
  走ります（`pre-commit install` で有効化。詳細は [.github/SECURITY.md](.github/SECURITY.md)）。

## ライセンス

ソフトウェアは MIT License、ドキュメントは Creative Commons Attribution
4.0 International（CC BY 4.0）で配布します。詳細は `LICENSE` および
`LICENSE-CC-BY` を参照してください。

第三者依存ライセンスは `LICENSES-THIRD-PARTY/` ディレクトリに保全されます。

## 商標・非提携の注記

本プロジェクトは、識別のための作業用名称として `genai-deploy-onpre` を使用する、
独立・非公式の派生実装です。デジタル庁およびその公式プロジェクトとは一切関係がなく、
提携・推奨・公認を受けたものではありません。関連する第三者の登録商標・出願中の商標を
主張するものでもありません。

詳細は `NOTICE` を参照してください。
