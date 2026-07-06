# 法令 RAG 通称辞書（law-name-aliases）運用ドキュメント

法令 RAG の「法令名推定 → 法令特定」段で、ローカル LLM（gemma）が出す**通称・略称**を
**正式名称へ決定論的に置換**するための辞書の、出所・生成・検証・運用を記録する。

- 辞書ファイル：[`api-config/law-name-aliases.json`](../api-config/law-name-aliases.json)（`{"通称":"正式名称", ...}`）
- 単一の真実（コード側）：api `src/lib/lawRag/lawNameEstimator.ts` の `resolveLawNameAliases` / `applyLawNameAliases`

## 1. なぜ必要か

法令特定は法令名の embedding（`app_laws_master.law_title_embedding`）最近傍で行う。gemma は
「労働者派遣法」のような通称を出せても、その通称は正式名称（「労働者派遣事業の適正な運営の確保及び
派遣労働者の保護等に関する法律」）と embedding が離れ、最近傍が**別法を誤って拾う**（実測：
労働者派遣法 → 昭和四十三年法律第八十九号）。上流（クラウド版）は web 検索 grounding で通称→正式名称を
解決していたが on-prem は web 無し。そこで主要法令の標準的略称を正式名称へ決定論置換する。

**正式名称→law_num の解決は従来どおり embedding**（全法令名と同一経路）。辞書が持つのは
「通称→正式名称」のみ（DB に law_num を焼き込まない＝陳腐化を避ける）。

## 2. 反映機構（リーンプロンプトと統一）

レポート生成のリーンプロンプト（`LAW_RAG_REPORT_PROMPT_FILE`）と同じ流儀：

| | 値 |
|---|---|
| 環境変数 | `LAW_RAG_ALIASES_FILE`（compose 既定 `/config/law-rag/law-name-aliases.json`） |
| マウント | `./api-config:/config/law-rag:ro`（プロンプトと共用） |
| 読込 | api 起動時に 1 度（`LawReportPipeline` コンストラクタ） |
| 反映 | **JSON 差し替え＋`docker compose ... restart api` のみ**（イメージ再ビルド不要） |
| フォールバック | 未指定・読めない・不正 JSON は空辞書（辞書機能だけ無効化＝素の embedding 解決） |

キーは読込時に正規化（空白・全角空白・中黒・括弧を除去）するので、JSON は自然な通称
（中黒入り等）で記述してよい。

## 3. データ出所：e-Gov 法令標準XML の `LawTitle/@Abbrev`

辞書データは e-Gov 法令検索の全法令 XML（`all_xml.zip`）の `<LawTitle Abbrev="略称1,略称2">正式名称</LawTitle>`
（公式略称・カンマ区切りで複数）から抽出する。**ingest（api `tools/law-rag-ingest/xml_to_jsonl.py`）は
`LawTitle` のテキストのみ取り込み Abbrev 属性を捨てている**ため、略称は元 XML にのみ存在し DB には無い。

> **断面（スナップショット）**：現行辞書は e-Gov **2026/5/30 断面**の公式略称である。法令は改称・略称変更が
> あるため、辞書はあくまで「その断面時点の公式略称」を収録する。断面より古い旧称・俗称（例：改称前の
> 「下請法」）は含まれない（§7 参照）。e-Gov を更新断面で取り直して再生成すれば最新化される。

抽出（運用者のローカルで実施・外部取得も運用者側）例：
```python
import glob, json, xml.etree.ElementTree as ET
rows = []
for f in glob.glob(f"{XMLDIR}/**/*.xml", recursive=True):
    try: root = ET.parse(f).getroot()
    except Exception: continue
    t = root.find(".//LawTitle")
    if t is None: continue
    formal = "".join(t.itertext()).strip()
    num = root.find(".//LawNum")
    law_num = "".join(num.itertext()).strip() if num is not None else ""
    for alias in (t.get("Abbrev") or "").split(","):
        alias = alias.strip()
        if alias: rows.append({"alias": alias, "formal": formal, "lawNum": law_num})
json.dump(rows, open("aliases-raw.json", "w"), ensure_ascii=False, indent=2)
```
`aliases-raw.json` はリポに含めない（再生成可能な中間生成物）。

## 4. スクリプト（deploy/scripts）

すべて LLM 不要（tei+DB のみ）。コンテナ内で実行：

| スクリプト | 役割 |
|---|---|
| `law-alias-build.mjs` | `aliases-raw.json` を検証し本番 JSON を生成（stdout） |
| `law-alias-verify.mjs` | 辞書の収録基準を実 embedding 解決で検証（小規模辞書/サンプル向け・失敗時 exit 1） |
| `law-alias-collision-audit.mjs` | 全エントリの意味的衝突を監査（辞書あり解決 vs 素の embedding 解決） |

### 生成
```
docker compose -f docker-compose.yml -f docker-compose.secrets.yml cp aliases-raw.json api:/tmp/aliases-raw.json
docker compose -f docker-compose.yml -f docker-compose.secrets.yml exec -T api \
  node --input-type=module - < scripts/law-alias-build.mjs \
  > api-config/law-name-aliases.json 2> /tmp/alias-build-stats.txt
docker compose -f docker-compose.yml -f docker-compose.secrets.yml restart api   # 反映
```

### `law-alias-build.mjs` の採用条件
自己解決（正式名称→自分自身）を **embedding を回さず構成的に保証**する：
正式名称は `app_laws_master.law_title` をそのまま採用する（embed_fill が同一文字列を埋めたので
自己 cosine=1.0 が最近傍＝`resolveLawNums` が必ず自分の law_num を返す）。採用は次を満たすもの：

1. `law_num` が `app_laws_master` に実在（未投入法令は除外）
2. その `law_title` が DB 内で一意（同名タイトル＝曖昧は除外）
3. 同一略称→複数法令の衝突を除外／正規化キー衝突（別タイトル）を除外
4. 略称が 30 字超の「公式だが長い擬似略称」は除外（gemma が出さずノイズ・`LAW_ALIAS_MAX_LEN` で調整）
5. 手動除外リスト `MANUAL_EXCLUDE`（§5）に該当しない

## 5. 意味的衝突監査と手動除外（2026-06-08）

`law-alias-collision-audit.mjs` を全 2700 キーで実行（gemma 不要）。「辞書あり解決(=A)」と
「素の embedding 解決(=B)」を比較し、A≠B かつ **K が B のタイトルに部分一致**するもの＝
「K は本来 B を指す名前なのに A へ逸らしている」高リスクを抽出した。

結果：
- **挙動変化キー 1287 / 2700**（約半数）＝辞書の本来の仕事（短い略称は素では正しく当たらず辞書で矯正）。
- **高リスク候補 10 件**。精査：
  - **7 件は辞書が正しい**（特定法 vs 一般法の区別。素の B が誤り）：ＥＥＺ漁業法（＋施行令/規則）、
    電子消費者契約法、特別児童扶養手当法（＋施行令）、被災地借地借家法。
  - **3 件が両義的**：循環基本法（→循環型社会形成推進基本法／素＝水循環基本法。公式用法として妥当）、
    証明規則（→特定無線設備…証明等に関する規則／素＝計算証明規則）、
    標識令（→道路標識…に関する命令／素＝自動車道標識令）。

**決定（運用判断）**：総称的で両義の **証明規則・標識令の 2 件を除外**（`MANUAL_EXCLUDE` に追加）。
循環基本法は公式用法として妥当なため保持。→ 最終 **2698 件**。

監査の限界：本監査は「K が B 名に部分一致する」構造的衝突を捕捉する。部分一致しない
意図レベルの衝突（gemma が K で全く別法を意図）は構造的には検出できない。ラベル付き eval
（`scripts/law-queries.json`・20 問）は範囲が狭い。新たな衝突が見つかれば `MANUAL_EXCLUDE` に追加する。

## 6. 更新手順（辞書を増減するとき）

1. 運用者が e-Gov `all_xml.zip` から `aliases-raw.json` を再抽出（§3）。
2. `law-alias-build.mjs` で再生成（§4）。必要なら `MANUAL_EXCLUDE`/`LAW_ALIAS_MAX_LEN` を調整。
3. `law-alias-collision-audit.mjs` で新たな高リスク衝突がないか確認。
4. `docker compose ... restart api` で反映。
5. 本ドキュメント §5 の決定履歴を更新。

## 7. 既知の限界

- **通称の経時変化（gemma 知識カットオフ）**：gemma の学習時点の旧名称・旧略称が、e-Gov の現行断面
  （投入データの断面）と食い違うことがある。例：下請代金支払遅延等防止法は 2026/5/30 断面では
  「製造委託等に係る中小受託事業者に対する代金の支払の遅延等の防止に関する法律」へ改称され、公式略称も
  「中小受託取引適正化法／取適法」。gemma が旧称「下請法」を出しても e-Gov 現行データに「下請法」は
  無いため辞書に載らず、素の embedding 解決に落ちて誤りやすい。旧称・通称を救いたい場合は手動の
  legacy エイリアスとして JSON へ追記する（例：`"下請法": "製造委託等に係る…法律"`）運用で対処する。
- **app_laws_master の収録範囲**：ingest（`tools/law-rag-ingest/xml_to_jsonl.py`）は実体条文を持つ法令
  のみ取り込む（廃止条文・改正附則・「削除」だけの stub を除外）。このため全量 XML（2026/5/30 断面で
  約 10086 件）のうち、条文が残らない法令（廃止法令等）は app_laws_master（約 7813 件）に含まれない。
  これは検索対象として意味のある法令に絞る**意図的な仕様**であり、データ欠落ではない。そうした法令の
  略称は build 時に「DB不在」として除外される（解決しても条文が無いため）。
- gemma が法令名を全く想起できないクエリ（例：パート有期労働法の差別的取扱い）は、辞書では直らない
  （gemma が略称すら出さないため）。これは**推定段＝ローカル LLM の知識・推論力の限界**。本環境では
  ハードウェア制約から小型モデル（gemma 2B 級）を用いており、ここが上限になる。推定品質は次で調整余地が
  ある（環境依存の限界であり、製品の固定的欠陥ではない）：
  - **モデル差し替え**：より大きな/新しいモデルを使えば推定 recall は上がる（リソースに余裕のある環境向け）。
  - **推定プロンプト**：法令名推定の system プロンプトは api `src/lib/lawRag/lawNameEstimator.ts` の
    `LAW_NAME_SYSTEM_PROMPT`（現状はコード定数＝変更にはビルドが必要。レポート生成プロンプトのような
    設定ファイル外出しはしていない）。ドメインヒントや few-shot を入れる余地はあるが、小型モデルでは
    効果が不確実なため本環境では既定のままとする。
