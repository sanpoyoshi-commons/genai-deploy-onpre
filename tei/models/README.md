# tei/models — 埋め込みモデル（ONNX）配置先

TEI（text-embeddings-inference）が serving する埋め込みモデルの ONNX 一式を置くディレクトリ。
中身（`*.onnx` 等）は容量大（ruri-v3-310m で約 1.2GB）かつ再生成可能なため git 追跡しない（`.gitignore`）。

## なぜ ONNX を自前生成するのか

採用モデル `cl-nagoya/ruri-v3-310m`（ModernBERT・Apache-2.0）の公式 HF リポは **safetensors のみで ONNX 非同梱**。
TEI の CPU イメージは ORT(ONNX) が主経路で、ONNX 不在時の candle/ModernBERT/CPU フォールバックは
warmup 直後にクラッシュして起動できない（2026-05-27 の live e2e で確認）。
そこで**公式 safetensors から自前で ONNX をエクスポート**して ORT 経路で安定させる。
第三者がアップロードした ONNX 版には依存しない（供給元検証不要＝サプライチェーン健全性）。

## 生成手順（一度きり）

```bash
# deploy リポ直下で実行（Docker で完結。約 1.2GB の成果物が tei/models/ruri-v3-310m-onnx へ出力される）
bash scripts/export-ruri-onnx.sh

# TEI を新モデルで起動し直す（tei は OOM 対策で embedding profile へ分離済み）
docker compose --profile embedding up -d --force-recreate tei

# 起動確認（ログに Ready が出れば serving 開始）
docker compose logs tei
```

出力レイアウト（TEI ORT が要求）：`onnx/model.onnx` ＋ `config.json` / `tokenizer.json` /
`modules.json` / `1_Pooling/config.json` / `sentence_bert_config.json` 等の sentence-transformers 設定。

compose の `tei` サービスは `--model-id ${EMBEDDING_MODEL_PATH:-/models/ruri-v3-310m-onnx-int8}` で
このディレクトリ（`./tei/models:/models:ro` でマウント）をローカルパス指定して読み込む（既定は int8 版。
fp32 で確認したいときのみ `EMBEDDING_MODEL_PATH=/models/ruri-v3-310m-onnx` で上書き）。

## int8 量子化（RAG 高速化・標準セットアップ）

CPU 既定では fp32 の ingest が約 29 chunk/分・rerank が 35〜43 秒/クエリと遅いため、上で生成した
**fp32 ONNX を dynamic int8 量子化**して serving します（**compose の既定 model-id は int8**）。量子化は
キャリブレーション不要で、**既存 fp32 ONNX のローカル変換のみ**で完結します（HuggingFace からの再 DL なし）。

**実測（法令 20 問、ARCH=avx512_vnni）**：ingest 28.7→68.6 chunk/分（×2.39）、rerank 40.7→17.0 秒
（×2.39）、精度は Hit@1 90→80%・MRR 0.950→0.858。**精度低下（-10pt）を許容し、速度を優先して int8 を
標準採用**しています。（retrieve のレイテンシは embedding でなく pg_bigm 検索が律速のため、量子化の効果は
ingest 側に出ます。）

```bash
# 標準セットアップ：fp32 を export → int8 へ量子化（*-int8 ディレクトリへ出力。再DL不要）
bash scripts/export-ruri-onnx.sh && bash scripts/export-ruri-reranker-onnx.sh
bash scripts/quantize-onnx-int8.sh          # 既定の ARCH=avx512_vnni。VNNI 非対応 CPU は ARCH=avx2

# 起動（compose 既定が *-int8 を指すので env 指定は不要）
docker compose --profile embedding --profile rerank up -d tei tei-reranker
```

fp32 へ切戻したい場合のみ env で上書き（並存・即時切戻し可）：
`EMBEDDING_MODEL_PATH=/models/ruri-v3-310m-onnx RERANKER_MODEL_PATH=/models/ruri-v3-reranker-310m-onnx ...`

量子化版の出力レイアウトは fp32 と同一（`onnx/model.onnx` を量子化版に差し替え、他の設定はコピー）。
**この int8 版でモデルを固定**しているため、以降の配布用データ生成もこの版を基準とします
（モデルを後で変えると、生成済みのデータや既存 chunk が全再生成になるためです）。
