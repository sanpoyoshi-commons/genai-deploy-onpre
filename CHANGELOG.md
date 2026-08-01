# Changelog（変更履歴）

利用者に影響する主要な変更を記録します。リリースタグは付けず日付ベースで記載します
（同梱 OSS イメージの実バージョンは `docker-compose.yml` が単一の真実）。
既存環境への反映手順は [docs/operations.md「更新（最新コードに追従する）」](docs/operations.md#更新最新コードに追従する) を参照してください。

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
