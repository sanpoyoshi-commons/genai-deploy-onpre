# 法令 RAG データのセットアップ（dump 取得 ／ 自前 ingest）

RAG（文書検索）機能で**法令検索**を使うには、法令データを PostgreSQL（pgvector）へ取り込んでおく必要があります。全量法令の取り込み（埋め込み生成を含む ingest）は、**個人 PC では数十時間規模**（実測でおよそ 47 時間）かかります。

そこで本配布物では **2 通り（両建て）** を用意します。

- **方法 A（推奨・既定）**：メンテナが作成済みの **事前ビルド dump** を取得して **import** する。47 時間の ingest は不要で、すぐに使えます。
- **方法 B（最新化したい人向け）**：e-gov から最新の法令データを取得し、**自前で ingest** する。常に最新だが時間がかかります。

---

## 前提

- 起動の前提（Docker / clone 等）は [docs/prerequisites.md](./prerequisites.md) を参照。
- **実行ディレクトリ**：本書のコマンドは特記なき限り deploy リポジトリ直下（`~/work/genai-deploy-onpre`）で実行します。
- 本機能は **`embedding` profile**（tei）と PostgreSQL が必要です。RAG は opt-in の任意機能で、既定（チャットのみ）では起動しません。
  ```bash
  COMPOSE_PROFILES=llm,embedding docker compose up -d
  ```
- **メモリ注意**：tei（embedding）とローカル LLM の同時常駐は重く、**16 GB 以上推奨**です（README の [システム要件](../README.md#システム要件メモリの目安)）。低メモリ機では import 中・ingest 中に他の常駐サービスを絞ってください。
- **クエリ実行時も重い（取り込みだけでなく）**：法令調査の問い合わせは、法令名推定→条文選別→出典付きレポート生成の 3 回の逐次 LLM 呼び出しを大コンテキストで行うため、本スタックで最も計算負荷が高い処理です。**実測（CPU のみ・16GB クラス）では、高品質なモデルはタイムアウト、小型モデルは精度不足**となり、両立には GPU か十分な計算資源を推奨します。モデルは web の法令調査フォームで選択でき、トレードオフを切り替えられます（詳細は [operations.md（chat LLM モデルの選定）](operations.md#chat-llm-モデルの選定ハードウェア階層別メニュー)）。
- **⚠️ パスワード方式を先に確定する**：法令データを投入すると DB volume（`postgres_data`）にデータが入ります。あとで `.env` ↔ docker secrets の方式を切り替えると **DB volume の初期化（`down -v`＝投入したデータも消去）が必要**になります（理由は [operations.md（パスワードの扱い）](operations.md#パスワードの扱いenv-と-docker-secrets)）。**投入前にどちらの方式で運用するか決めて**から進めてください。

---

## 方法 A：事前ビルド dump を取得して import（推奨）

事前ビルド dump は **GitHub Releases のアセット**として配布します（公開リポジトリでは配布に追加費用はかかりません）。取得と投入は `scripts/law-rag-import.sh` で行います（法令 3 テーブルを TRUNCATE してから data-only で投入する破壊的操作のため、`RESTORE` 入力の確認が入ります）。

> **同梱データの版（出典）**：配布 dump の基底データは **e-Gov 法令検索の全法令データ（XML 一括ダウンロード）を 2026-07-05 に取得**したものを加工（条文チャンク化＋`cl-nagoya/ruri-v3-310m` による 768 次元埋め込み付与）した派生物です。e-Gov は日次更新のため、**より新しい法令が必要な場合は方法 B（自前 ingest）** を使ってください。出典・利用条件（CC BY 4.0 互換）の詳細は [NOTICE](../NOTICE)「法令 RAG 事前ビルド dump」節を参照。

> **前提**：`docker compose up` 済み（postgres healthy）で、**migrate 適用済み**（法令テーブルが存在）であること。未適用なら `docker compose -f docker-compose.yml -f docker-compose.secrets.yml run --rm migrate`。

### A-1（推奨）：Release から取得して一括投入

`--from-release` を使うと、ダウンロード（分割アセットは自動結合）→ 投入までを一括で行います。

> **タグの意味と最新版**：`RELEASE_TAG` の日付（`law-rag-YYYYMMDD`）は **e-Gov 法令データの取得日**を表します。配布 dump は容量の都合上、Releases には基本的に**最新版 1 つだけ**を置きます。メンテナがより新しい取得日の dump に差し替えると既定タグが古くなるので、その場合は Releases ページ <https://github.com/sanpoyoshi-commons/genai-deploy-onpre/releases> で**現在のタグ**を確認して指定してください：
>
> ```bash
> RELEASE_TAG=law-rag-YYYYMMDD ./scripts/law-rag-import.sh --from-release
> ```

```bash
cd ~/work/genai-deploy-onpre

# 既定の配布先（org sanpoyoshi-commons ／ リリースタグ law-rag-20260713）から取得して投入
./scripts/law-rag-import.sh --from-release
```

> 環境変数（いずれも既定値あり・別の配布先/版を使う場合のみ上書き）：`GITHUB_OWNER`（既定 `sanpoyoshi-commons`）／`RELEASE_TAG`（既定 `law-rag-20260713`＝e-Gov 取得日 `law-rag-YYYYMMDD`）／`GITHUB_REPO`（既定 `genai-deploy-onpre`）／`ASSET_NAME`（既定 `law-rag.dump`）。

### A-2（代替）：手動ダウンロード → ローカル投入

ブラウザ等で取得済みの dump を投入する場合：

```bash
# 単一ファイル
./scripts/law-rag-import.sh law-rag.dump

# 分割ファイル（law-rag.dump.part-00, .part-01, ...）の場合も、
# 先頭名を渡せばスクリプトが自動結合する
./scripts/law-rag-import.sh law-rag.dump
```

> **WSL2 の注意（`/mnt/c/...` 直指定を避ける）**：Windows 側でダウンロードした dump を `/mnt/c/Users/...`（Windows ファイルシステム）のまま渡すと、大容量の stdin ストリームで `pg_restore: could not read from input file: end of file` になることがあります（実機確認）。**Linux ファイルシステム側（例 `~/`）へコピーしてから**渡してください（例：`cp /mnt/c/Users/<あなた>/Downloads/law-rag.dump ~/ && ./scripts/law-rag-import.sh ~/law-rag.dump`）。

> **2GB/ファイル上限**：GitHub Releases のアセットは 1 ファイル 2GB までです。dump がこれを超える場合は `.part-NN` に分割して配布します（取得・結合はスクリプトが自動処理）。

### A-3. 取り込み確認

取り込み後の疎通確認は任意です。RAG（法令検索）が応答するかは、web の**法令調査フォーム**から
実際に質問して確認できます（出典付きレポートが返れば取り込み成功）。

---

## 方法 B：最新の法令を自前で ingest

最新の法令に更新したい場合は、e-gov の全法令データから取り込みます。**数十時間かかる**点に留意してください。

### B-1. e-gov の全法令データを取得

全法令の XML を **e-Gov 法令検索の「XML 一括ダウンロード」** から入手します。ページで全法令の
一括 zip（**全法令で約 278MB・日次更新**。本書では `all_xml.zip` と表記）をダウンロードし、
deploy リポジトリ直下（`~/work/genai-deploy-onpre`）などに配置します。

- **ダウンロード**：<https://laws.e-gov.go.jp/bulkdownload/>
- **利用条件（必読）**：[e-Gov ポータル利用規約](https://www.e-gov.go.jp/terms)。商用利用も可・複製/翻案可ですが、
  **(a) 出典の記載**と **(b) 編集・加工した場合はその旨の記載**が必要です（CC BY 4.0 互換）。
  なお法令本体は著作権法第13条により著作権の目的とならない（パブリックドメイン的な）扱いです。

### B-2. コーパス化 → ingest

本リポジトリの変換スクリプトでコーパス化し、api 側の取り込みツールで pgvector へ ingest します。

```bash
# e-gov XML → コーパス化（本リポジトリのスクリプト）
python scripts/egov_law_to_corpus.py  # 入出力パスはスクリプトの指定に従う
```

- 取り込み（embedding 生成を含む ingest）は **api 側のツール**で行います（`genai-ai-api-onpre` の law-rag 取り込みツール）。`embedding` profile（tei）稼働が前提です。
- 通称→正式名称の辞書運用は [docs/law-rag-aliases.md](./law-rag-aliases.md) を参照（法令名推定の精度に関わります）。

> **所要時間（実測の目安）**：全量で**およそ 47 時間**（`app_laws_for_indexing.content_embedding` ＝約 51 万条文の埋め込み生成が主因）。途中で他の重い常駐（LLM 等）と競合させないこと。

> **2 回目以降の更新は差分ビルドで短縮可能**：埋め込み済みの DB（方法 A の dump を import した状態でも可）が既にあれば、47 時間の全量埋め込みを繰り返す必要はありません。既存の埋め込みを退避・復元し、**新規・改正で本文が変わった条文だけ**を再埋め込みする「差分ビルド」の手順を、api 側取り込みツールの README（`genai-ai-api-onpre` の `tools/law-rag-ingest/README.md`「差分ビルド」節）にまとめています。前提は埋め込みモデル（`EMBEDDING_MODEL_PATH`）を前回から変えていないこと。

### B-3. （任意）配布用 dump を作る

ingest 済みの環境からは、`scripts/law-rag-export.sh` で配布用 dump（法令 3 テーブルの data-only・custom 形式・圧縮）を生成できます。2GB を超える場合は自動分割します。生成物を GitHub Releases にアップロードすれば、他環境では方法 A で即取り込めます。

```bash
./scripts/law-rag-export.sh          # ./dist に law-rag-<日時>.dump（または .part-NN）を生成
```

---

## 関連

- 起動の前提：[docs/prerequisites.md](./prerequisites.md)
- RAG の通称辞書：[docs/law-rag-aliases.md](./law-rag-aliases.md)
- バックアップ／リストア（DB 全体の論理 dump）：[docs/backup-restore.md](./backup-restore.md)
