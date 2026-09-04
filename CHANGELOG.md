# Changelog（変更履歴）

利用者に影響する主要な変更を記録します。リリースタグは付けず日付ベースで記載します
（同梱 OSS イメージの実バージョンは `docker-compose.yml` が単一の真実）。
既存環境への反映手順は [docs/operations.md「更新（最新コードに追従する）」](docs/operations.md#更新最新コードに追従する) を参照してください。

## 2026-09-04

### Data

- **法令 RAG 配布 dump 更新（[`law-rag-20260904`](https://github.com/sanpoyoshi-commons/genai-deploy-onpre/releases/tag/law-rag-20260904)）** — e-Gov 2026-09-04 取得分（法令 9,518 件）。前版 `law-rag-20260822` から約 2 週間分の改正が反映されています。改正・新規 **131 条文／55 法令**（自治体システム標準化基準の省令群と税制関係の省令改正が中心。令和八年熊本地震の災害対応政令 2 件も新規収録）＋廃止・削除 10,843 行／80 法令（条番号振替が大半）。データ基準日は 2026-09-04。法令別の全内訳は Release notes を参照
- `scripts/law-rag-import.sh` と [docs/law-rag-setup.md](docs/law-rag-setup.md) の既定 `RELEASE_TAG` を `law-rag-20260904` へ更新（旧タグも `RELEASE_TAG` 環境変数で引き続き取得可能）
- 既存環境の更新手順：`git pull` → `./scripts/law-rag-import.sh --from-release`（スキーマ変更はないため migrate の再実行は不要です）

## 2026-08-28

### Security

- **同梱 Mailpit を v1.30.4 → v1.30.7 へ更新しました（[CVE-2026-67448](https://github.com/axllent/mailpit/security/advisories/GHSA-8r62-w5wh-fc5m) ／ [CVE-2026-67447](https://github.com/axllent/mailpit/security/advisories/GHSA-r553-m4fv-5v97)）** — いずれも CVSS 3.1 **MEDIUM**（6.5／5.3）。変更はイメージ 1 行のみで、設定・データの移行はありません
- **CVE-2026-67448（6.5・WebSocket の Origin チェック迂回）** — Mailpit の Web UI は**既定で認証がなく、受信した全メールを閲覧できます**。この不備は、パスをパーセントエンコードした `/%61pi/events` へ WebSocket 接続することで Origin の検査をすり抜けられるというもので、**UI を `127.0.0.1` に閉じていても塞がりません**（利用者が同じ端末のブラウザで攻撃者のページを開くと発火するため）。本構成は Keycloak のパスワード再設定メールが Mailpit に届くため、メール本文の閲覧はアカウント乗っ取りにつながりえます。修正が実際に効くことは確認済みです（v1.30.4 では当該パスで WebSocket 接続が確立しますが、v1.30.7 では `403 Forbidden` で拒否されます）
- **CVE-2026-67447（5.3・SMTP DATA 行のサイズ超過）** — 本構成では SMTP（1025）をホストへ publish しておらず内部ネットワークからのみ到達するため、影響は限定的です
- このほか **CVE が採番されていない修正**も含まれます（POP3 パスワードのデバッグログ伏字化、POP3 のログイン失敗追跡、添付ダウンロードの Content-Type サニタイズ、サムネイル応答のファイル名エスケープ、HTTP サーバへの `ReadHeaderTimeout` 追加など）。なお POP3 は `MP_POP3_AUTH` と `MP_POP3_BIND_ADDR` の両方を設定しない限り起動しないため、本構成の既定では無効です
- 既存環境の更新手順：`git pull` → `docker compose up -d mailpit`。**Mailpit は永続ボリュームを持たないため、コンテナの再作成で受信済みメールは消えます**（開発用の検証データのため実害はありませんが、着信確認の途中であれば再送してください）

## 2026-08-26

### Security

- **同梱 Keycloak を 26.6.4 → 26.7.2 へ更新しました（[CVE-2026-18963](https://access.redhat.com/security/cve/cve-2026-18963) の根本修正）** — 2026-08-22 に入れた暫定緩和は「パスワードをお忘れですか」を止めることで攻撃面を閉じるものでしたが、26.7.2 は reset-credentials の action token と対象ユーザーの照合を追加した修正版で、**機能を止めずに塞ぎます**。26.7.2 にはこのほかにも security fix が含まれます（[リリースノート](https://www.keycloak.org/2026/08/keycloak-2672-released)）
- 併せて **26.7.0 / 26.7.1 の breaking changes** を事前に点検し、本構成への影響が無いことを確認しています（Admin REST 用サービスアカウントの権限は protocol mapper 経由ではなく `realm-management` client role の直接割当／`view-system` 不使用／FGAP・Authorization Services・Identity Provider いずれも未使用／`--features` 指定なし＝preview 機能を有効化していない／self-registration 無効）
- **⚠️ Keycloak はダウングレードできません**：起動時に Liquibase が DB スキーマを自動マイグレーションします（今回は `jpa-changelog-26.7.0.xml`）。**更新前に `./scripts/backup.sh logical` でバックアップを取得してください**。切り戻しはイメージタグを戻すだけでは完了せず、`keycloak-db` のリストアが必要です

### Changed

- **「パスワードをお忘れですか」を再び有効化しました（暫定緩和の解除）** — `keycloak/import/genai-realm-realm.template.json` の `resetPasswordAllowed` を `true` へ戻しました。**新規に構築する環境では何もする必要はありません**
- **⚠️ 2026-08-22 の暫定緩和を手で適用した既存環境は、戻す操作が必要です**：realm は `--import-realm` で初回のみ取り込まれるため、テンプレートの変更は既存環境に効きません。**先に 26.7.2 へ上げてから**、管理コンソール（Realm settings → Login → Forgot password → **On**）または `kcadm.sh` で戻してください（順序が逆だと、脆弱なままリセット機能を開くことになります）。手順は [docs/operations.md「「パスワードをお忘れですか」の暫定無効化（解除済み・履歴）」](docs/operations.md#パスワードをお忘れですかの暫定無効化解除済み履歴)。`master` realm は Keycloak の既定が `false` のため、そのままで構いません

## 2026-08-22

### Data

- **法令 RAG 配布 dump 更新（[`law-rag-20260822`](https://github.com/sanpoyoshi-commons/genai-deploy-onpre/releases/tag/law-rag-20260822)）** — e-Gov 2026-08-22 取得分（法令 9,537 件）。前版 `law-rag-20260802` は**スキーマ更新のみのリリース**（e-Gov 再取得なし・データ基準日 2026-08-01）だったため、実データとしては約 3 週間分の改正が反映されています。改正・新規 **784 条文／223 法令**（省庁の組織令・組織規則の改編が中心。医療保険・社会保険の施行規則群も横断的に改正）＋廃止・削除 37,382 行／264 法令（条番号振替が大半）。データ基準日は 2026-08-22。法令別の全内訳は Release notes を参照
- `scripts/law-rag-import.sh` と [docs/law-rag-setup.md](docs/law-rag-setup.md) の既定 `RELEASE_TAG` を `law-rag-20260822` へ更新
- 既存環境の更新手順：`git pull` → `./scripts/law-rag-import.sh --from-release`（スキーマ変更はないため migrate の再実行は不要です）

### Security

- **Keycloak の「パスワードをお忘れですか」を既定で無効化しました（[CVE-2026-18963](https://access.redhat.com/security/cve/cve-2026-18963) の暫定緩和）** — CVSS 3.1 **9.1 Critical**（`AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:N`・CWE-640）。Keycloak の reset-credentials フローに不備があり、**未認証の攻撃者がメール検証リンクを踏ませることなく任意ユーザーのパスワードを再設定できる**（＝アカウント乗っ取り）ものです。同梱 Keycloak（26.6.4）は影響範囲に含まれ、`/auth/` は nginx 経由で公開されるため、**本構成では実際に攻撃面が開いています**。`bruteForceProtected` では防げません（総当たりではなくフローの検証不備のため）
- 対応として `keycloak/import/genai-realm-realm.template.json` の `resetPasswordAllowed` を `false` にしました。Keycloak はこの値が `false` のとき `login-actions/reset-credentials` の GET／POST 双方をサーバー側で拒否します。Red Hat が公式の暫定緩和として案内している手順と同じものです
- **影響**：利用者が自分でパスワードを再発行する導線のみが使えなくなります。**招待フロー（`create-user.mjs`）は別経路のため影響ありません**。パスワードを忘れた場合は管理者が招待メール再送または管理コンソールで再設定します
- **⚠️ 既存環境は手動での適用が必要です**：realm は `--import-realm` で初回のみ取り込まれるため、すでに起動したことのある環境にはこの変更が効きません。管理コンソール（Realm settings → Login → Forgot password → Off、`master` realm も）または `kcadm.sh` で適用してください。手順は [docs/operations.md「「パスワードをお忘れですか」の暫定無効化（解除済み・履歴）」](docs/operations.md#パスワードをお忘れですかの暫定無効化解除済み履歴)
- **本設定は暫定です**：修正版 Keycloak 26.7.2（2026-08-19 公開）へイメージを上げた時点で `resetPasswordAllowed` を `true` へ戻します。バージョン固定＋リリース後クールダウンの運用原則に従い、版上げは別途実施します

## 2026-08-07

### Docs

- **配布タグの意味を明確化** — `law-rag-YYYYMMDD` のタグ日は **dump を配布した日**で、**e-Gov 取得日（データ基準日）とは別**である旨を [docs/law-rag-setup.md](docs/law-rag-setup.md)・[NOTICE](NOTICE)・`scripts/law-rag-export.sh` ヘッダに明記しました（データ基準日は dump 同梱の `law_rag_meta` が正。例：`law-rag-20260802` のデータ基準日は 2026-08-01）。文言のみの変更で、dump・スクリプトの動作は変わりません

## 2026-08-04

### Added

- **法令調査ページで参照時点を指定できるようになりました（時間軸 as-of の web 対応）** — 質問欄の下の「参照時点」に将来の日付を入れると、その日に施行されている版（未施行の改正後条文）で回答します。未入力なら現行（今日時点）で従来どおりです。過去日は指定できません（e-Gov の一括データは各条文の旧版を保持しないため）。
- **引用条文の版を一覧表示** — 回答の下に「引用した条文の版」パネルを追加し、条文ごとに **現行／施行予定** のバッジ・施行日・改正予定（次版施行日）と、参照時点・データ基準日を表示します。「どの版で答えたか」を本文の散文任せにしないための表示です。レポート本文（コピー範囲）は従来どおりで、パネルはその外に出ます。
- **API 返却に構造化メタを追加** — `POST /api/law-rag/query` が `references[]`・`dataAsOf`・`asOfDate`（指定時のみ）を返します。`outputs` / `usageMetadata` は不変のため、`outputs` だけを読む既存クライアントはそのまま動きます。dump・スキーマの変更はありません（`law-rag-20260802` をそのまま使用）。詳細は [docs/law-rag-setup.md「時間軸（as-of）」](docs/law-rag-setup.md#時間軸as-onどの時点の法令で答えるか)

### Fixed

- **参照時点を指定したときの出典見出しが改正前のままだった問題を修正** — 引用本文は指定時点の版に切り替わるのに、見出し（法令名＋条見出し）が現行版のままで、見出しと本文が別の版になることがありました。
- **生成文に `<0xE3><0x80><0x80>` のような文字列が混ざる問題を修正** — 一部のモデル（gemma 系）は専用トークンを持たない文字をバイト単位のトークンで表し、その内部表記が生成文にそのまま出ることがあります（日本語では全角スペースで顕著）。モデル出力の受け口で本来の文字へ復号するようにしました（チャット・翻訳・ダイアグラム・法令調査のすべてに適用）。

## 2026-08-02

### Added

- **法令 RAG に時間軸（as-of）対応（データ／API 層）** — 参照時点を指定して回答できるようになりました。法令調査 API（`POST /api/law-rag/query`）に任意の `inputs.as_of_date`（`YYYY-MM-DD`）を追加。**未指定なら現行（従来どおり）**、指定するとその時点で施行されている版を構造的に解決して回答し、未施行条文にも到達できます（出典に施行日・未施行・改正予定を表示）。あわせて**データ基準日**（e-Gov 取得日）をレポートの「## 出典」節へ自動で焼き込みます（どの時点の知識かを明示）。web からの日付指定 UI は次段階で対応予定。詳細は [docs/law-rag-setup.md「時間軸（as-of）」](docs/law-rag-setup.md#時間軸as-onどの時点の法令で答えるか)

### Data

- **法令 RAG 配布 dump 更新（[`law-rag-20260802`](https://github.com/sanpoyoshi-commons/genai-deploy-onpre/releases/tag/law-rag-20260802)）** — e-Gov 実データは前版 `law-rag-20260801` と同一（2026-08-01 取得分・再取得なし）。本リリースは時間軸 as-of 対応でスキーマを更新したもの（`dwh_laws.enforce_date` 実カラム化・`app_laws_for_indexing.is_future` 未施行フラグ・`law_rag_meta` データ基準日）＋将来のみ新設される未施行 2,304 条文を未施行フラグ付きで索引へ追加。データ基準日は 2026-08-01。詳細は Release notes を参照
- `scripts/law-rag-import.sh` と [docs/law-rag-setup.md](docs/law-rag-setup.md) の既定 `RELEASE_TAG` を `law-rag-20260802` へ更新
- **⚠️ 旧 dump（`law-rag-20260801` 以前）は新スキーマと非互換**：`law_rag_meta` を含まないため import スクリプトが明示エラーにします。新スキーマでは `law-rag-20260802` 以降を使用してください（旧 dump は同時期の旧 api とセットで利用可能）。既存環境の更新手順：`git pull` → `docker compose ... run --rm migrate`（`enforce_date`/`is_future`/`law_rag_meta` を追加）→ `./scripts/law-rag-import.sh --from-release`

## 2026-08-01

### Data

- **法令 RAG 配布 dump 更新（[`law-rag-20260801`](https://github.com/sanpoyoshi-commons/genai-deploy-onpre/releases/tag/law-rag-20260801)）** — e-Gov 2026-08-01 取得分（法令 9,550 件）。前版 `law-rag-20260713` からの差分は改正・新規 2,046 条文／265 法令（金融商品取引法本体・薬機法施行規則・個人情報保護法・電気事業法・資金決済法などが中心、令和八年の新規制定＝重要品種育成法・ヒトゲノム編集胚等規制法・防災庁設置法ほか）、廃止・削除 29,231 行／233 法令（会社法・税法など改正頻度の高い法令での条番号振替が大半）。法令別の差分内訳・sha256・取得手順は Release notes を参照
- `scripts/law-rag-import.sh` と [docs/law-rag-setup.md](docs/law-rag-setup.md) の既定 `RELEASE_TAG` を `law-rag-20260801` へ更新（旧タグも `RELEASE_TAG` 環境変数で引き続き取得可能）

### Fixed

- **法令 RAG 検索インデックスの版選別を現行施行版へ是正** — e-Gov 一括データは 1 法令を施行日ごとの複数版（現行・未施行の将来改正版）で収録する。検索インデックス（`app_laws_for_indexing`）が施行日が最も新しい版＝将来改正版を採用しており、未施行の条文本文を返す場合があった。「施行日 ≤ ビルド日の最新版＝現行施行版」を採用するよう是正（`tools/law-rag-ingest/sql/02_rebuild_app_layer.sql`）。配布 dump `law-rag-20260801` も是正版へ差し替え（sha256 更新・Release notes 参照）。未施行版は原本テーブル `dwh_laws` に全版保持し、施行日での時点切替（as-of 検索）は今後対応

## 2026-07-17

### Security

- **nginx 1.30.3 → 1.30.4**（base: alpine3.23 → alpine3.24）— 2026-07 公開の nginx 脆弱性 3 件への対応：
  - [CVE-2026-42533](https://my.f5.com/manage/s/article/K000162097)（Major）: `map` ディレクティブ＋正規表現使用時のバッファオーバーフロー（DoS／条件次第でコード実行の可能性）
  - [CVE-2026-60005](https://my.f5.com/manage/s/article/K000162100)（Medium）: `ngx_http_slice_module` のメモリ開示
  - [CVE-2026-56434](https://my.f5.com/manage/s/article/K000162098)（Medium）: `ngx_http_ssi_module` の use-after-free
- 本構成の同梱 nginx 設定は 3 件とも該当機能を使用していません（`map` はリテラルマッチのみで正規表現不使用・slice／SSI モジュール不使用）。直接の攻撃面はありませんが、影響バージョン範囲（〜1.31.2、stable 系は〜1.30.3）に含まれるため防御的に更新します。**nginx 設定をカスタマイズして `map` の正規表現マッチ等を追加している場合は早期の更新を推奨**
- 既存環境への反映：`git pull` → `docker compose pull nginx` → `docker compose up -d nginx`（[docs/operations.md「更新（最新コードに追従する）」](docs/operations.md#更新最新コードに追従する) 参照）

## 2026-07-14

### Data

- **法令 RAG 配布 dump 更新（[`law-rag-20260713`](https://github.com/sanpoyoshi-commons/genai-deploy-onpre/releases/tag/law-rag-20260713)）** — e-Gov 2026-07-13 取得分（法令 9,225 件）。前版 `law-rag-20260705` からの差分は改正 707 条文／115 法令（金融機能強化法関連・薬機法関連・郵政関連が中心、ほか医療系資格の施行令/施行規則の横断改正）、廃止・削除 7,741 行。法令別の差分内訳・sha256・取得手順は Release notes を参照
- `scripts/law-rag-import.sh` と [docs/law-rag-setup.md](docs/law-rag-setup.md) の既定 `RELEASE_TAG` を `law-rag-20260713` へ更新（旧タグも `RELEASE_TAG` 環境変数で引き続き取得可能）

## 2026-07-13

### Docs

- **WSL2 カーネル脆弱性対応の更新**（[docs/prerequisites.md](docs/prerequisites.md) A-6）— Copy Fail / Dirty Frag / Fragnesia は修正済みカーネルが配布済みとなったため、**恒久対策＝`wsl --update`（`uname -r` が 6.18.33 以上で 3 系統すべて修正済み）を最善手順として明記**。未使用モジュールの無効化は「更新できない場合の暫定緩和策（多層防御として残置可）」へ位置づけを変更。ネイティブ Ubuntu 24.04 は `apt full-upgrade`（`linux` 6.8.0-124.124 以上）で修正済み
- CHANGELOG.md（本ファイル）新設・[docs/operations.md](docs/operations.md) に本リポ自体の更新手順を追記

## 2026-07-12

同梱 OSS イメージの定期棚卸し・再 pin（タグ＋digest 更新）。全 13 イメージで
CRITICAL 脆弱性 0（`scripts/scan-images.sh`）、9 サービス起動・主要経路の疎通を確認済み。

### Changed

- **Keycloak 26.6.3 → 26.6.4** — セキュリティ修正 8 件（CVE-2026-11800＝JWT アルゴリズム混同による認証バイパス、CVE-2026-9099＝権限昇格 ほか）。**既存環境は早期の更新を推奨**
- **pgvector 0.8.3 → 0.8.5** — HNSW vacuum 修正。postgres はカスタムイメージのため `docker compose build postgres` が必要。**既存 DB ボリュームでは `ALTER EXTENSION vector UPDATE;` を一度実行**（[docs/operations.md](docs/operations.md) 参照。新規環境では不要）
- **SeaweedFS 4.34 → 4.39** — 既存ボリュームと in-place 互換（PUT/GET 確認済み）
- **Ollama 0.30.10 → 0.31.2** — 既存 pull 済みモデルはそのまま利用可
- **Mailpit v1.30.2 → v1.30.4** — 公開 SMTP 向け脆弱性修正 2 件（本構成は localhost バインドのため影響は限定的）
- **Dozzle v10.6.6 → v10.6.9**
- **node 24.17.0 → 24.18.0-alpine**（`echo-exapp` サンプル）

### Unchanged

- PostgreSQL 16.14 / pg_bigm v1.2-20250903 / nginx 1.30.3 / TEI 1.9.3 / speaches 0.8.3 / ElasticMQ 1.7.1（現行が最新のため変更なし）
