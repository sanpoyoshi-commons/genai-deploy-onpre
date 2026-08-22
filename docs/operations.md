# 運用ガイド（genai-deploy-onpre）

本書は、起動後の運用・詳細設定をまとめたものです。最短の起動手順は [README](../README.md) を参照してください。

> コマンドは特記なき限り **deploy リポジトリ直下（`~/work/genai-deploy-onpre`）** で実行します。

## 目次

- [パスワードの扱い（.env と docker secrets）](#パスワードの扱いenv-と-docker-secrets)
- [ユーザー・チームの管理（招待制オンボーディング）](#ユーザーチームの管理招待制オンボーディング)
- [メール送信（Mailpit と本番 SMTP）](#メール送信mailpit-と本番-smtp)
- [「パスワードをお忘れですか」の無効化（暫定）](#パスワードをお忘れですかの無効化暫定)
- [更新（最新コードに追従する）](#更新最新コードに追従する)
- [プロファイル（機能の ON/OFF）](#プロファイル機能の-onoff)
- [chat LLM モデルの選定](#chat-llm-モデルの選定ハードウェア階層別メニュー)
- [画像生成モデルの配置（sdcpp）](#画像生成モデルの配置sdcpp)
- [文字起こしモデルの pull（whisper）](#文字起こしモデルの-pullwhisper)
- [証明書の信頼登録](#証明書の信頼登録ブラウザ警告の解消)
- [ログ閲覧（Dozzle ＋ logs ヘルパー）](#ログ閲覧dozzle--logs-ヘルパー)
- [バックアップ・リストア](#バックアップリストア)

---

## パスワードの扱い（.env と docker secrets）

既定は `.env` のパスワードで動きます（手軽）。よりセキュアに、パスワードを環境変数へ出さない
**docker secrets**（`docker-compose.secrets.yml` オーバーレイ、任意）も選べます。個人開発・
localhost 単独利用では脅威は低いため `.env` で十分です。

> **`.env` 方式でも `gen-secrets.sh` の実行を推奨**：`KEYCLOAK_ADMIN_CLIENT_SECRET` と
> `S3_SECRET_ACCESS_KEY` は Keycloak realm import／SeaweedFS S3 のレンダリング実体
> （`secrets/` 配下）にランダム生成値が焼き込まれます。`gen-secrets.sh` は `.env` が存在すると
> この 2 変数を生成値へ**自動整合**するため（未設定・空・dev 既定値のときのみ。独自値は変更せず警告）、
> Keycloak Admin REST 401（チーム作成 500）や S3 署名不一致を防げます。

> **⚠️ 方式の切り替えは DB volume の初期化が必要**：`.env` パスワード（base 単体）と secrets
> ファイル（オーバーレイ）はパスワードの出所が異なります。**既存の DB volume を残したまま切り替えると
> DB 認証に失敗します（migrate が `P1000`。逆方向 secrets→base も同様）**。切り替えるときは先に
> `down -v`（**データロスト**）で `postgres_data` / `keycloak_db_data` をリセットしてから、切り替え後の
> 方式で起動し直してください。**どちらか一方を最初に決め、以後ずっと同じコマンドで使い続けます**
> （切り替えるならデータを貯める前＝実験段階のうちに）。

### docker secrets オーバーレイの使い方

```bash
# 1. 秘密値ファイルを生成（secrets/ に作成。.gitignore 対象。初期設定の gen-secrets.sh と同じ）
./scripts/gen-secrets.sh

# 2. base に重ねて起動・停止（2 ファイル指定）
docker compose -f docker-compose.yml -f docker-compose.secrets.yml up -d
docker compose -f docker-compose.yml -f docker-compose.secrets.yml down
```

- postgres / keycloak-db は `POSTGRES_PASSWORD_FILE`（公式イメージのネイティブ対応）。
- Keycloak は `_FILE` 非対応のため、entrypoint ラッパで secret を読み込み環境変数へ注入します。
- 秘密値ファイルは `secrets/`（mode 644、ディレクトリは 700）。Keycloak が非 root で読むため
  644 とし、ディレクトリ 700 でホスト側アクセスを制限します（`gen-secrets.sh` が設定）。
- secrets 方式を選んだら **以後は常に 2 ファイルを指定**してください（base 単体で再作成すると
  上記のとおり DB 認証に失敗します）。単一サービスだけ作り直すときは `--no-deps` も付けます（例：
  `… -f docker-compose.secrets.yml up -d --no-deps --force-recreate nginx`）。
  `COMPOSE_PROFILES` を併用する場合は、その値も同じコマンドに前置します。

### secrets にするもの／`.env` に残すもの

**secrets オーバーレイは `.env` を不要にしません。** 移るのは基盤パスワード5つだけで、それ以外の
設定値（ポート・ホスト名・モデル一覧・プロファイル等）は引き続き `.env` が必要です。

| 区分 | 対象 | 置き場所・挙動 |
|---|---|---|
| **secrets へ移す（5つ）** | `POSTGRES_PASSWORD` / `KEYCLOAK_DB_PASSWORD` / `KEYCLOAK_ADMIN_PASSWORD` / `KEYCLOAK_ADMIN_CLIENT_SECRET` / `S3_SECRET_ACCESS_KEY` | `gen-secrets.sh` が `secrets/` に生成。オーバーレイ時は `.env` の該当値が空に上書きされ `/run/secrets/` から読まれる（`.env` の該当行は使われなくなる＝消しても残してもよい） |
| **`.env` に残す（パスワード以外すべて）** | プロジェクト名・ポート（`HTTP_BIND` / 各 `*_PORT`）、Keycloak 非機密（`KEYCLOAK_HOSTNAME` / `KEYCLOAK_ADMIN` / `KEYCLOAK_ISSUER` 等）、`POSTGRES_DB` / `POSTGRES_USER`、LLM（`LLM_BACKEND` / `MODEL_IDS` / `OLLAMA_BASE_URL` 等）、RAG / embedding / rerank、画像 / 文字起こし、`COMPOSE_PROFILES`、sandbox / ExApp 設定 … | `.env`（オーバーレイでも必須） |

> **注意（対象外）**：外部 LLM（`LLM_BACKEND=openai` / `anthropic` / `bedrock` 等）の **API キーは
> 現状 secrets オーバーレイの対象外**で、`.env` に環境変数として置く形です（機密ですが env 経由）。
> secrets で隠れるのは上記5つのインフラ系のみです。各変数の詳細は [docs/env-reference.md](env-reference.md)。

---

## ユーザー・チームの管理（招待制オンボーディング）

`docker compose up` 直後は realm import で seed された **初期管理者 `admin`（SystemAdmin）が 1 名だけ**います。
本オンプレ版は **セルフサインアップを無効（招待制）** とし、管理者が Keycloak にユーザーを供給します
（クラウド版の Cognito セルフサインアップ／管理画面に相当する操作）。各スクリプトは **api コンテナ内**で
実行します（内部ネットワークの Keycloak / PostgreSQL を使うため）。secrets オーバーレイ運用時も
`_FILE` を自動解決するため `-e` での secret 受け渡しは不要です。

> 手動派の方は、Keycloak 管理コンソール（`https://localhost/auth` → realm `genai-realm`）から
> Users / Groups を直接操作しても同じことができます。以下は再現性のあるスクリプト手順です。

### 1. 一般ユーザーを作成・招待する

```bash
set -a && . ./.env && set +a
docker compose exec -T \
  -e KEYCLOAK_ADMIN_CLIENT_SECRET="$KEYCLOAK_ADMIN_CLIENT_SECRET" \
  -e NEW_USER_EMAIL="user@example.com" \
  api node --input-type=module - < scripts/create-user.mjs
```

- `User` グループ付与＋`UPDATE_PASSWORD` 必須アクション付きでユーザーを作成し、**招待メール**
  （パスワード設定＋メール検証リンク）を送ります。メールは [Mailpit](#メール送信mailpit-と本番-smtp) に届きます。
- 招待メールを送らずに作る場合は `-e SEND_INVITE=0`（パスワードは管理コンソールで設定）。
- 同じメールで再実行しても二重作成しません（冪等）。

### 2. 2 人目以降の SystemAdmin を付与する

対象ユーザーが**一度ログイン済み**（＝Keycloak に存在）であることが前提です。

```bash
set -a && . ./.env && set +a
docker compose exec -T \
  -e KEYCLOAK_ADMIN_CLIENT_SECRET="$KEYCLOAK_ADMIN_CLIENT_SECRET" \
  -e TARGET_EMAIL="user@example.com" \
  api node --input-type=module - < scripts/add-system-admin.mjs
```

付与後、対象ユーザーが**再ログイン**するとヘッダーに「チーム管理」メニューが出ます。

### 3. 共通アプリチームを作成する

`COMMON_TEAM_ID = 00000000-0000-0000-0000-000000000000` に登録したアプリは、**全認証済みユーザー**が
所属に関係なく利用できます。この共通チームの実体を作ります（冪等）。

```bash
docker compose exec -T api node --input-type=module - < scripts/create-common-app-team.mjs
```

作成後、チーム一覧（`/teams`）と AI アプリ一覧に「共通アプリ」チームが表示されます。

### 標準的なオンボーディング手順

1. `admin` でログイン → `create-user.mjs` でメンバーを招待
2. 招待された各メンバーが Mailpit のリンクからパスワード設定 → 一度ログイン
3. 必要なら `add-system-admin.mjs` で管理者を増やす
4. `admin`（または別の SystemAdmin）が web の「チーム管理」からチーム作成・メンバー追加・AI アプリ登録
5. 全員に配りたいアプリは `create-common-app-team.mjs` で共通チームを作り、そこに登録

## メール送信（Mailpit と本番 SMTP）

招待・メール検証は Keycloak の SMTP 設定経由で送信されます（利用者自身によるパスワードリセットは
[暫定的に無効化](#パスワードをお忘れですかの無効化暫定) しています）。

- **既定（開発）**：realm に **Mailpit**（`host=mailpit`, `port=1025`, 認証なし）が配線済みです。
  送信メールは **Mailpit Web UI（`http://127.0.0.1:8025/`）** で確認します（実際には外部送信されません）。
- **本番（外部 SMTP へ切替）**：SMTP パスワードは秘密値のため realm import JSON には焼き込みません。
  Keycloak 管理コンソール（`https://localhost/auth`）→ realm `genai-realm` → **Realm settings → Email**
  で Host / Port / From / 認証情報を設定してください（または逆プロキシ前段で送信を制御）。

> **realm 変更の反映について**：realm は `--import-realm` で**初回のみ**取り込まれます。`smtpServer` や
> `defaultGroups` を変えた `genai-realm-realm.template.json` を**既存環境**へ反映するには、
> (a) 管理コンソールで該当項目を手で直す、または (b) `down -v`（**データロスト**）→ `gen-secrets.sh`
> → 再起動でクリーンに再 import します。新規環境では `gen-secrets.sh` 生成時点で反映されます。

## 「パスワードをお忘れですか」の無効化（暫定）

realm テンプレートは `resetPasswordAllowed: false`（＝ログイン画面の「パスワードをお忘れですか？」を出さない）
を既定にしています。**これは恒久的な設計ではなく、Keycloak の脆弱性への暫定緩和です。**

- **理由**：[CVE-2026-18963](https://access.redhat.com/security/cve/cve-2026-18963)（CVSS 3.1 **9.1 Critical**
  `AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:N`／CWE-640）。Keycloak の reset-credentials フローに不備があり、
  **未認証の攻撃者がメール検証リンクを踏ませることなく、任意ユーザーのパスワードを再設定できます**。
  同梱の Keycloak は nginx の `/auth/` 配下に公開されるため、この機能が有効だと攻撃経路になります。
- **この設定で塞がる理由**：Keycloak は `resetPasswordAllowed` が `false` のとき、リンクを隠すだけでなく
  `/auth/realms/<realm>/login-actions/reset-credentials` の GET／POST 双方をサーバー側で拒否します（400）。
  Red Hat が公式の暫定緩和として案内している手順と同じものです。
- **`bruteForceProtected` では防げません**：本件は総当たりではなくフローの検証不備のためです。
- **修正版が出たら戻します**：Keycloak 26.7.2 で修正済みです。本リポジトリはバージョン固定＋クールダウン
  （リリース後 7〜14 日の様子見）を運用原則としているため、先に本設定で攻撃面を閉じ、
  イメージを 26.7.2 へ上げた時点で `resetPasswordAllowed` を `true` へ戻します。

### 影響と代替手段

- **影響を受けるのは、利用者が自分でパスワードを再発行する導線のみ**です。
- **招待フローは影響を受けません**。`create-user.mjs` は Keycloak Admin REST の `execute-actions-email`
  （`UPDATE_PASSWORD` / `VERIFY_EMAIL`）を使っており、reset-credentials フローとは別経路です。
- 利用者がパスワードを忘れた場合は、**管理者が再設定**します。
  - 招待メールを再送する：[「1. 一般ユーザーを作成・招待する」](#1-一般ユーザーを作成招待する) と同じコマンド（冪等）
  - 管理コンソールで直接設定する：`https://localhost/auth` → realm `genai-realm` → Users → 対象 → Credentials

### 既存環境への反映（必須）

realm は `--import-realm` で**初回のみ**取り込まれるため、**すでに起動したことのある環境ではテンプレートの
変更が効きません**。以下のどちらかで、稼働中の realm に直接適用してください。

**管理コンソール**：`https://localhost/auth` → realm 選択 → Realm settings → Login →
**Forgot password → Off**。`genai-realm` だけでなく **`master` realm も確認**してください。

**または CLI**：

```bash
# 管理者としてログイン（パスワードはプロンプトで入力）
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin

# 現在値の確認
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh get realms/genai-realm \
  --fields realm,resetPasswordAllowed

# 無効化（master 側も同様に実行）
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh update realms/genai-realm \
  -s resetPasswordAllowed=false
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh update realms/master \
  -s resetPasswordAllowed=false
```

適用後、`https://localhost/auth/realms/genai-realm/account/` からのログイン画面に
「パスワードをお忘れですか？」が表示されないこと、および
`https://localhost/auth/realms/genai-realm/login-actions/reset-credentials` が
エラーページ（400）になることを確認してください。

## 更新（最新コードに追従する）

本リポ（`genai-deploy-onpre`）と `genai-ai-api-onpre` / `genai-web-onpre` を更新したときの
反映手順です。

**本リポ（`genai-deploy-onpre`）**

```bash
git pull                  # 同梱 OSS イメージの固定タグ/digest 更新も取り込まれる
docker compose pull       # 新しいタグ/digest のイメージを取得
docker compose build postgres   # postgres はカスタムビルドのため再ビルド
docker compose up -d      # 変更のあったコンテナのみ再作成
```

変更内容（どのイメージが何のために上がったか）はリポ直下の [CHANGELOG.md](../CHANGELOG.md)
を参照してください。pgvector の更新を含む場合は、後述の `ALTER EXTENSION vector UPDATE;`
が既存 DB ボリュームで必要です。

**API（`genai-ai-api-onpre`）**

```bash
git -C ../genai-ai-api-onpre pull
docker compose build      # api / migrate イメージを再ビルド（postgres 等はキャッシュ）
docker compose up -d      # 変更コンテナを再作成。migrate が DB マイグレーションを適用
```

`docker compose up -d --build` でビルドと再作成をまとめても構いません。

**Web（`genai-web-onpre`）**

```bash
git -C ../genai-web-onpre pull
./scripts/build-web.sh    # web/ を再ビルド・配置
# 起動中ならブラウザを強制リロード（nginx は web/ を都度配信）
```

> **secrets オーバーレイ運用**なら build / up とも 2 ファイル指定に：
> `docker compose -f docker-compose.yml -f docker-compose.secrets.yml build` → `… up -d`。
> `COMPOSE_PROFILES` を使っているなら同じ値を前置します。

> **同梱 OSS イメージ**（postgres / keycloak / nginx 等）はバージョンを `docker-compose.yml` で
> タグ＋SHA 固定。更新は同ファイルのタグ/digest を新版へ変更 → `docker compose pull` →
> `docker compose up -d`。
>
> **pgvector を含む postgres イメージ更新時の注意**：`CREATE EXTENSION` は初回 initdb 時のみ
> 実行されるため、**既存の DB ボリュームでは拡張のバージョンが古いまま残ります**（バイナリは
> 新版・カタログ表記が旧版のねじれ）。イメージ更新後に一度だけ拡張を揃えてください：
>
> ```bash
> docker compose exec postgres psql -U genai -d genai -c 'ALTER EXTENSION vector UPDATE;'
> ```
>
> 新規環境（ボリューム新規作成）ではこの手順は不要です。

---

## プロファイル（機能の ON/OFF）

機能（メニュー）は **`COMPOSE_PROFILES` で ON/OFF します**。profile を有効にすると、その機能の
バックエンドが起動し、**web のメニューにも自動で現れます**（profile ↔ メニューが連動。web の
再ビルドは不要・nginx 再起動で反映）。**既定（無指定）はチャットのみ**で、軽く `docker compose up`
できます。機能は足し算で opt-in してください。

```bash
# 例：チャットだけ（既定・最小）
COMPOSE_PROFILES=llm docker compose up -d

# 例：チャット＋RAG（文書検索）
COMPOSE_PROFILES=llm,embedding docker compose up -d

# 例：全部入り（GPU/大 RAM 前提）
COMPOSE_PROFILES=llm,embedding,rerank,image,transcribe,queue docker compose up -d
```

> `COMPOSE_PROFILES` は **`.env` に書く**か、上記のようにコマンド先頭に付けます。`docker compose
> --profile llm up -d` のように `--profile` を毎回並べても同じですが、`.env` に一度書くと以後の
> `up`／`down`／`ps` すべてに効くため運用が楽です。

### 機能 ↔ プロファイル 対応表

| 機能（web メニュー） | 有効化する profile | バックエンド | 目安 RAM |
|---|---|---|---|
| チャット／履歴 | （base＋）`llm` | ollama | LLM 次第（上記） |
| 文章生成・翻訳・図表生成 | `llm` | ollama | （chat と共用） |
| RAG（文書検索） | `embedding`（＋`rerank` で精度↑） | tei（＋tei-reranker） | embed 1〜2 GB（＋rerank 1〜2 GB） |
| 法令調査（法令 RAG） | `embedding`（RAG と共用・要法令データ投入） | tei＋pgvector | （RAG と共用） |
| 画像生成 | `image` | sdcpp（要モデル配置・下記） | 数 GB（GPU 推奨） |
| 文字起こし | `transcribe`＋`queue` | whisper＋worker | 1〜2 GB |
| AIアプリ（ExApps）の実行 | `queue` | elasticmq＋worker | 軽（JVM 数百 MB） |
| Code Interpreter（任意コード実行）⚠ | `sandbox`（要 `SANDBOX_ACCEPT_RISK=1`） | nsjail サンドボックス | 〜1.5 GB |

> 文字起こしは whisper（faster-whisper）に加えて非同期処理 worker が要るため、
> `transcribe` と `queue` を併用します（`COMPOSE_PROFILES=llm,transcribe,queue`）。RAG の
> 精度を上げる reranker は `rerank` を足します（別途 ONNX エクスポート要・下記 RAG 節参照）。
>
> AIアプリ（ExApps）は **閲覧・作成は既定でも可能**ですが、**非同期実行には `queue` が必要**です
> （elasticmq＋worker）。`queue` 無しでは実行ボタンが無効化され、api も実行要求を 503 で返します。
>
> **法令調査（法令 RAG）を使う場合**：`embedding` profile を有効にすると web メニューに「法令調査」が
> 現れます（汎用 RAG と同じ embedding スタックに連動）。利用には法令データを pgvector へ取り込む必要が
> あります（全量 ingest は個人 PC で数十時間規模）。事前ビルド dump の取得か自前 ingest かは
> **[docs/law-rag-setup.md](law-rag-setup.md)** を参照してください。法令調査は汎用 chat / 汎用 RAG とは別系統の
> 専用パイプライン（法令名推定→特定→条文選別→出典付きレポート）で、独立メニューとして提供します
> （設計意図は web リポジトリ `docs/法令調査機能.md` を参照）。

### ⚠ Code Interpreter（任意コード実行）を有効にする前に

Code Interpreter（`sandbox` profile）は、ユーザーが投入したデータを処理するために
**任意の Python コードを実行**する機能です。nsjail サンドボックス（namespace 隔離・network off・
rootfs read-only・nobody 降格・内側 seccomp・資源上限）で多層防御していますが、本環境の制約上
**外側 docker seccomp は unconfined ＋ 限定 cap** という、他機能より privileged 寄りの posture で動きます。
**localhost・opt-in・無保証**前提の機能であり、本番業務や公開ネットワークでの
任意コード実行は想定していません（残存リスクの詳細は下記 `docs/sandbox-acceptance-decision.md`）。

そのため、有効化には **`SANDBOX_ACCEPT_RISK=1` の明示が必須**です。未設定のまま `sandbox` profile を
起動すると、sandbox コンテナは posture 要約の警告バナーを出して**起動を中止**します（二段確認）。

```bash
# Code Interpreter を有効化（リスクを理解した上で）
SANDBOX_ACCEPT_RISK=1 COMPOSE_PROFILES=llm,sandbox docker compose up -d
# .env に SANDBOX_ACCEPT_RISK=1 と COMPOSE_PROFILES=llm,sandbox を書いてもよい
```

> 有効化の判断は運用者が一度行い記録するシート（[docs/sandbox-acceptance-decision.md](sandbox-acceptance-decision.md)）と、
> 背景の脅威モデル（[docs/sandbox-threat-model.md](sandbox-threat-model.md)）を必ず確認してください。本番相当で使うなら
> gVisor／microVM 等への強化と運用監視を各自の責任で行ってください（[DISCLAIMER.md](../DISCLAIMER.md)）。

### ハードウェア帯別プリセット（迷ったらこれ）

| 帯 | 用途 | `COMPOSE_PROFILES` | RAM 目安 |
|---|---|---|---|
| 最小／PoC | チャット・生成・翻訳・図表 | `llm` | 〜8 GB |
| 標準 | ＋RAG（文書検索） | `llm,embedding` | 16 GB〜 |
| フル | ＋画像・文字起こし・リランカ | `llm,embedding,rerank,image,transcribe,queue` | GPU／大 RAM 前提 |

> 低メモリ機（8 GB 級）では tei（embedding）と LLM の同時常駐が成立しないことがあります
> （[README のシステム要件](../README.md#システム要件メモリの目安)参照）。最小帯から始め、RAM に余裕がある分だけ機能を足してください。

---

## chat LLM モデルの選定（ハードウェア階層別メニュー）

chat LLM（ollama）の重みは配布物に**同梱せず**、運用者が自環境（CPU/RAM/GPU）に
応じて選び、実行時に pull します。**寛容な OSS ライセンス（再配布容易性）と、CPU 実機での
性能・日本語応答品質**を重視した階層別の推奨メニューを以下に示します。

### 使うモデルの指定（web 再 build 不要）

選択肢は `.env` の `MODEL_IDS`（JSON 配列）で指定します。この 1 つの値が
**画面のモデルセレクタ**（web）と **api の許可リスト**の双方を駆動します（単一の真実）。
変更は `.env` 編集 → nginx と api の再起動だけで反映され、**web の再ビルドは不要**です。
リクエスト未指定時の既定は `LLM_DEFAULT_MODEL`（空なら `MODEL_IDS` の先頭）です。

```bash
# .env で選択肢を列挙（既定推奨＝Gemma 4 を先頭に。CPU は e2b が実用・最も軽い）
#   MODEL_IDS=["gemma4:e2b","gemma4:e4b","mistral:7b","hf.co/elyza/Llama-3-ELYZA-JP-8B-GGUF"]
#   LLM_DEFAULT_MODEL=gemma4:e2b
# 反映（config.js を再生成 → セレクタが切り替わる）
docker compose up -d nginx api
# 使うモデルを ollama に pull（profile llm が起動している前提）
docker compose --profile llm exec ollama ollama pull gemma4:e2b
```

### 階層別メニュー（主軸＝Gemma 4・Apache-2.0／序列：Apache-2.0 ◎ ＞ Llama 系 ○）

**主軸は Gemma 4（Apache-2.0）** です。CPU 実機で `gemma4:e2b`/`e4b` が同等以下サイズの
他モデルより速く・日本語応答品質も良好（CPU 品質律速への現実的回答）で、かつ
ライセンスが清潔（Apache-2.0）なため、各帯の第一推奨に置きます。Mistral/Llama/ELYZA/
Swallow は「他選択肢」として残し、運用者が自環境で選べます。メモリ目安は
「[README のシステム要件](../README.md#システム要件メモリの目安)」も参照（tei 併用時は逼迫に注意）。

| 階層 | 第一推奨（Gemma 4） | 他選択肢 | ライセンス |
|---|---|---|---|
| 軽量（CPU/〜8GB） | **`gemma4:e2b`（既定・最も軽い）/ `gemma4:e4b`（メモリに余裕があれば）** | `mistral:7b` / `llama3.2:3b` | **Apache-2.0** / Apache-2.0・Llama |
| 日本語特化（8B） | （Gemma 4 が日本語良好なため任意） | ELYZA-JP・Swallow（下記コミュニティ配布） | Meta Llama 3/3.x（商用可） |
| 中量（16〜32GB/GPU） | **`gemma4:26b`（MoE）** | — | **Apache-2.0** |
| 大型（GPU） | **`gemma4:31b`** | `mixtral` / `llama3.3:70b` | **Apache-2.0** / Apache-2.0・Llama |

> 小型エッジモデル（`gemma4:e2b`/`e4b`）は通常チャット（短〜中文）では CPU でも快適ですが、
> **doc 要約や RAG の長文コンテキスト処理では品質が落ちることがあります**（n_ctx・モデル容量の制約）。
> 長文・RAG 用途を重視する場合は、より大きい `gemma4:26b`/`31b`（GPU）の併用を検討してください。
>
> **低スペック機（実質12GB級）では `e2b` を既定推奨**します。`e4b` は同環境でチャット時に
> ハングする事例を確認済みのため、メモリに余裕がある環境でのみ選んでください。
>
> **⚠ 法令調査（法令 RAG）は別格に重い**：法令名推定→条文選別→出典付きレポート生成の
> **3 回の逐次 LLM 呼び出し**を法令本文という大コンテキスト上で行うため、本スタックで最も重い処理です。
> **実測（CPU のみ・16GB クラス）**では、`gemma4:e2b` は品質は良いが 1 クエリに十数分かかりタイムアウト、
> `llama3.2:3b` は速いが法令名取り違え・出典欠落で実用品質に達しませんでした。**法令調査で「速く・高品質」を
> 両立するには GPU か十分な計算資源を推奨**します。法令調査フォームの LLM 選択でこのトレードオフを
> 切り替えられます（速度優先＝小型 / 精度優先＝高性能。詳細は web リポジトリ `docs/法令調査機能.md`）。

```bash
# 公式タグ（ollama ライブラリ）
docker compose --profile llm exec ollama ollama pull gemma4:e2b   # Apache-2.0・軽量（既定推奨）
docker compose --profile llm exec ollama ollama pull gemma4:26b   # Apache-2.0・中量(GPU)
# 日本語特化は ollama 公式ライブラリに無く、コミュニティ/HF 配布から pull する
docker compose --profile llm exec ollama ollama pull hf.co/elyza/Llama-3-ELYZA-JP-8B-GGUF
```

### ダイアグラム生成（フローチャート等）の設定と前提

web の「ダイアグラム」機能は、種別ごとの**大きなシステムプロンプト**（フローチャートは最大で
約 6.5K トークン）＋利用者入力を**通常の chat 経路**で LLM に送り、返ってきた mermaid を
ブラウザで描画します。**この箱（CPU・11GB 級）でも描画成功は可能**ですが、既定のままでは
図が出ません。実機検証で図が描画できた条件は次の通りです。

| 設定 | 値 | 理由 |
|---|---|---|
| `OLLAMA_CONTEXT_LENGTH` | `8192` | 既定 4096 ではプロンプト（〜7.3K）が切り詰められ mermaid 命令が落ちて図が出ない。7168 でも僅かに切り詰めるため 8192 が必要。 |
| 温度 | `0.2`（**自動**） | 既定（1.0）だと mermaid 書式が崩れ（`A="x"`/`-->|B` 等）レンダラが拒否する。低温で `A["x"]`/`-->` の遵守が安定。**ダイアグラム機能は web 側が自動で 0.2 を送る**ため設定不要（通常チャットには影響しない）。 |
| モデル | ELYZA-8B 等の 8B 級 | `llama3.2:3b` は構文崩壊（`子graph` 等）で描画不可。8B で有効な mermaid を生成できた。 |
| `OLLAMA_MAX_LOADED_MODELS` | `1`（既定） | タイトル生成にも選択モデルを使う（=同一モデル）ので通常は二重常駐しないが、念のため既定 1 で新モデルのロード時に旧モデルを自動アンロードして OOM を防ぐ。 |

```bash
# .env 例（ダイアグラム生成を CPU で試す場合）。温度は web が自動で下げるため不要。
#   OLLAMA_CONTEXT_LENGTH=8192
#   MODEL_IDS=["gemma4:e2b","hf.co/elyza/Llama-3-ELYZA-JP-8B-GGUF"]
# 反映（ollama は env 変更で再作成、api も）
docker compose up -d ollama api nginx
# ブラウザでモデルセレクタを 8B 級（ELYZA 等）に切り替えてから作図する
```

> **⚠ CPU では非常に遅い**：上記条件でも 11GB CPU 機ではフローチャート 1 枚に **約 20 分**
> （プレフィル ~17 分＋生成）かかります（タイムアウトは `LLM_DEFAULT_TIMEOUT_MS` 30 分・
> nginx `proxy_read_timeout` 1800s で対応済み）。**実用的な速度には GPU か 16GB+ を推奨**します。
> なお `LLM_DEFAULT_TEMPERATURE`（env）はダイアグラム以外の全 chat に効く別系統の任意設定です
> （ダイアグラムは web が個別に温度を送るため env 不要）。

### ライセンスの注意

- **Gemma 4（2026-04 公開）以降は Apache-2.0** です（Gemma 3 までの独自
  「Gemma 利用規約」から標準ライセンスへ移行）。本メニューは Gemma **4** を採用します。
- **ELYZA / Swallow**：Meta Llama 3/3.x ベースで、**Meta Llama Community License**
  に従う限り商用利用可（月間アクティブユーザ 7 億未満）。ただし **ollama 公式ライブラリには
  無く**、コミュニティ／HF 配布のため重み・量子化の品質や更新は配布元に依存します
  （タグは運用者が pull したものに合わせてください）。なお Llama 3.1/3.3 系 Swallow は
  Gemma 利用規約の Use Restriction も継承します（採用前に各配布元のライセンスを確認）。
- **embedding（tei）** は本メニューと別系統で `ruri-v3-310m`（Apache-2.0）を採用します。
- 同梱・採用モデルのライセンス保全は [`LICENSES-THIRD-PARTY/`](../LICENSES-THIRD-PARTY/) を参照。

### （将来）Gemma 4 MTP による高速化

Gemma 4 には Multi-Token Prediction（MTP）drafter があり、speculative decoding で
最大約 3 倍（GPU）／CPU でも数十 % の高速化が可能です（出力は不変）。ただし**現状
ollama では未対応**（llama.cpp 領域）のため、本スタックの ollama 経路では未提供です。
ollama が対応した時点で高速化オプションとして案内予定です。

---

## 画像生成モデルの配置（sdcpp）

画像生成（`generateImage`）は **stable-diffusion.cpp**（MIT・CPU 推論）で動かします。
ランタイムは自前ビルド（`sdcpp/Dockerfile`）で、モデルの重みは配布物に含めず運用者が配置します。

```bash
# 1) モデル（SD1.5 base 等）を ./sdcpp/models/ に配置（.safetensors / .gguf）。
#    既定ファイル名は v1-5-pruned-emaonly.safetensors（.env の SDCPP_MODEL_FILE で変更可）。
# 2) 画像生成サーバを起動（初回は CPU ビルドで数分）。
docker compose --profile image up -d sdcpp
```

- **既定モデル（SD 1.5）**：CreativeML OpenRAIL-M で配布されます。軽量で CPU でも動作します
  （ただし CPU 推論は 1 枚あたり数十秒〜数分かかります。GPU 対応は今後）。
- **モード対応範囲**：txt2img / img2img / inpaint / ControlNet に対応します。**inpaint・ControlNet は
  対応モデルの追加配置と sd-server の起動フラグが必要**です（未配置のモードを要求すると api は **501** を返します）。
  Bedrock 固有の color-guided generation・background-removal・outpainting は stable-diffusion.cpp に
  相当機能が無いため非対応（501）です。
- **ライセンスを重視する場合**：Apache-2.0 のモデル（例：FLUX.1-schnell）も配置できます
  （高品質ですが VRAM 要件が高く、実用上 GPU が要ります）。

---

## 文字起こしモデルの pull（whisper）

文字起こし（`startTranscription` / `getTranscription`）は **faster-whisper-server（speaches）**
（MIT・CPU 推論）で動かします。**speaches はモデルを自動 DL しません**（未 pull のモデルを要求すると
worker が whisper から 404 を受けてジョブを **FAILED** にします＝`getTranscription` が status=FAILED を返す）。
chat LLM（ollama）と同様、運用者が使うモデルを事前に pull します。

```bash
# 1) whisper と worker を起動（whisper は profile transcribe、worker は profile queue）。
docker compose --profile transcribe --profile queue up -d whisper worker

# 2) 使うモデルを speaches に pull（HuggingFace から DL → whisper_hf_cache に保持）。
#    WHISPER_MODEL（.env / 既定 deepdml/faster-whisper-large-v3-turbo-ct2）と一致させること。
#    whisper はホストに公開しないため、内部ネットワークの使い捨てコンテナから pull する：
PROJ=$(docker compose ls --format '{{.Name}}' | head -1)   # 例 genai-local
docker run --rm --network ${PROJ}_genai_internal curlimages/curl:latest \
  -X POST "http://whisper:8000/v1/models/deepdml/faster-whisper-large-v3-turbo-ct2"
```

- **既定モデル（large-v3-turbo）**：large-v3 に近い精度で大幅に高速で、CPU 推論の実用的な選択肢です。
- **精度を最優先する場合**：`WHISPER_MODEL=Systran/faster-whisper-large-v3`（高精度だが CPU は重く長尺は時間大）
  や中庸の `Systran/faster-whisper-medium` を `.env` で指定し、api・worker を再起動してから上記 pull を実行します。
- **話者分離（speakerLabel）**：現時点では非対応です。`speakerLabel=true` でもリクエストは成功し、
  単一話者の結果（話者ラベル無し）を返します（pyannote 等による話者分離は今後）。

---

## 証明書の信頼登録（ブラウザ警告の解消）

本配布物は自己署名 HTTPS を既定とします。配布物単体ではブラウザ警告ゼロは
構造的に達成できないため、各利用端末で内部 CA（`certs/ca.crt`）を信頼登録します。

- Windows：`certs/ca.crt` を「信頼されたルート証明機関」にインポート
- macOS：キーチェーンアクセスで `certs/ca.crt` を「常に信頼」に設定
- Firefox：設定 → 証明書 → 認証局証明書のインポートで `certs/ca.crt` を追加

公開ドメインで運用する場合は Let's Encrypt／商用証明書への差し替えが可能です
（詳細は今後のデプロイ手順書）。

---

## ログ閲覧（Dozzle ＋ logs ヘルパー）

各サービスのコンテナログはすべて **Docker `json-file` ドライバ**（`max-size=100m` /
`max-file=3`、共通設定）に集約されます。閲覧手段は 2 系統を併存させます。

- **GUI（主）**：Dozzle Web UI ―― ブラウザでリアルタイム閲覧・検索・色分け。
- **CLI（従／自動化／フォールバック）**：`scripts/logs.sh`（bash）／ `scripts/logs.ps1`
  （PowerShell）―― SSH 経由運用・障害切り分けの 1 コマンド化に使います。

### Dozzle UI（既定 `http://127.0.0.1:9980/`、localhost のみ）

localhost バインド・simple 認証必須・`docker.sock` を read-only マウント・操作系
（actions / shell）無効・Analytics 送信無効、をデフォルトで設定済みです。
simple 認証ユーザー（`admin`）は初期設定の `./scripts/gen-secrets.sh` が
自動生成します（パスワードは `secrets/dozzle_admin_password`）。**パスワードを変える・
ユーザーを追加する**ときは、次のコマンドで `dozzle/users.yml` を作り直します：

```bash
docker run --rm amir20/dozzle:v10.5.3 generate <user> --password <pw> --name <name> > dozzle/users.yml
```

UI は英語表記ですが、**ブラウザの自動翻訳機能を ON にすれば日本語化されます**
（Chrome：右クリック「日本語に翻訳」／Edge：翻訳バー）。英語のエラーメッセージや
スタックトレースを正確に読みたいときは、一時的に翻訳を OFF に切り替えてください。

### logs.sh / logs.ps1 ヘルパースクリプト

構造化 JSON ログから障害切り分けに必要な行を 1 コマンドで抽出します。

```bash
# 全サービスから ERROR / FATAL を抽出
./scripts/logs.sh error

# 1 リクエストを request_id で hop 串刺し（nginx → api → postgres 等）
./scripts/logs.sh req <request_id>

# LLM 呼び出し系（component=api.llm.* / event=llm_call_*）
./scripts/logs.sh llm

# DB クエリ系（api.db / db_query_failed / db_query_slow）
./scripts/logs.sh db

# 任意サービスのライブ追尾（Ctrl+C で停止）
./scripts/logs.sh tail [service]

# 指定期間（例：5m / 1h）
./scripts/logs.sh since 5m
```

Windows は `.\scripts\logs.ps1 <サブコマンド>` を同じ体系で利用できます。

`jq` を導入すると構造化検索が正確になります（推奨）。`jq` が無い環境でも
`grep` フォールバックで最低限の障害切り分けは可能で、不在時はインストール手順を
日本語で案内します。

### 障害切り分けの典型 4 ケース

| 障害 | UI 操作（Dozzle、3 クリック以内目安） | ヘルパースクリプト |
|---|---|---|
| 画面が真っ白 | 検索バーに `request_id`／`level:ERROR` フィルタ → サービスを `nginx → web → api → postgres` で順に確認 | `./scripts/logs.sh req <id>` |
| LLM が応答しない | `component:api.llm` 検索 → `llm_call_started` の後に `_succeeded` / `_failed` が無い経路を特定 | `./scripts/logs.sh llm` |
| ファイルアップロード失敗 | `component:api.storage` 検索 → `event:file_upload_failed` ／ `error.*` 確認 | `./scripts/logs.sh error` |
| ログインができない | `component:api.auth` ／ `service:keycloak` 検索 → `event:login_failed` / `auth_token_rejected` | `./scripts/logs.sh req <id>` |

> ログのローテーションは `docker-compose.yml` 冒頭の `x-logging` で一元管理しています
> （`max-size=100m` × `max-file=3`、合計 300MB/コンテナ）。
> ディスク容量に応じて調整してください。

### request_id による hop 串刺し（nginx → api）

nginx は受信時に `X-Request-Id` ヘッダがあればそれを採用、無ければ自動生成し、後段の api /
keycloak / SeaweedFS へ `X-Request-Id` で透過します（`nginx/conf.d/00-logging.conf` ＋
`default.conf` の `proxy_set_header X-Request-Id $req_id;`）。
nginx の access_log も統一された JSON 形式（`service` / `level` / `component=nginx.access` /
`event=request_completed` / `request_id` / `method` / `uri` / `status` / `request_time` /
`upstream_*` 等）で出力するため、`./scripts/logs.sh req <id>` で **nginx と api の両ログを
1 コマンドに統合**できます（ケース①画面真っ白／ケース④ログイン失敗の動線）。

> 注：本配布物は外部公開を nginx のみに限定します。Docker の `ports` は
> ホストの ufw を迂回するため、LAN 公開時はホスト側 iptables/ufw による補助制限が
> 必須です（今後のデプロイ手順書で詳述）。

---

## バックアップ・リストア

業務 DB（postgres）／認証 DB（keycloak-db）／添付ファイル（seaweedfs）のバックアップと
リストアの運用手順は [docs/backup-restore.md](backup-restore.md) を参照してください。

要点：

- `./scripts/backup.sh logical` — 業務 DB と認証 DB の論理バックアップ（稼働中安全、ダウンタイムなし、日次 cron 想定）
- `./scripts/backup.sh full` — 上記＋ SeaweedFS の物理バックアップ（停止→tar→起動、数分のダウンタイム、週次 cron 想定）
- `./scripts/restore.sh logical|full <dump...>` — 通常リストア（運用者がターミナルで対話実行、`RESTORE` 入力 prompt あり）

SeaweedFS は at-rest 暗号化が既定 ON のため、`backup.sh full` は filer メタデータと volume データを
同一時点で取得する設計です（詳細は [docs/backup-restore.md](backup-restore.md) §2-3）。
