#!/usr/bin/env bash
# ruri-v3-reranker-310m を公式 safetensors から ONNX へ自前エクスポートする（RAG リランカ導入）。
# export-ruri-onnx.sh（埋め込み）の reranker 版。
#
# 背景：RAG 大規模精度検証で、法令ドメインの Hit@1≒45%（規程95%から低下）・RRF 調整も法令名コンテキスト
# 前置も無効と実証。Hit@10=95%（正解条文は top-10 内にある）のため、cross-encoder リランカで top-K を
# 並べ替えれば Hit@1 へ変換できる＝最有力レバー。ruri-v3-reranker-310m（cl-nagoya・Apache-2.0・
# ModernBERT-Ja・8192 トークン）は ruri-v3-310m 埋め込みの対。第三者 ONNX 版に依存しない（供給元検証不要＝
# サプライチェーン方針整合、export-ruri-onnx.sh と同方針）。一度きりの実行（成果物はホストに残る）。
#
# 使い方（deploy リポ直下で。HuggingFace からの DL を伴うため手動で実行する）：
#   bash scripts/export-ruri-reranker-onnx.sh
# 生成後：
#   docker compose --profile rerank up -d tei-reranker
#   # rerank 疎通は scripts/bench-rag-law-rerank.mjs（RAG③ リランカ効果測定）で確認
set -euo pipefail

MODEL_ID="${1:-cl-nagoya/ruri-v3-reranker-310m}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/tei/models/ruri-v3-reranker-310m-onnx"
PY_IMAGE="python:3.12-slim"

echo "[export] model   = ${MODEL_ID}"
echo "[export] out dir = ${OUT_DIR}"
mkdir -p "${OUT_DIR}"

docker run --rm \
  -e MODEL_ID="${MODEL_ID}" \
  -e HF_HOME=/work/.hf-cache \
  -v "${OUT_DIR}:/work/out" \
  -w /work \
  "${PY_IMAGE}" bash -lc '
    set -euo pipefail
    pip install --no-cache-dir -q -U \
      "optimum[onnxruntime]>=1.24" "transformers>=4.48" "huggingface_hub>=0.26" "onnx"
    # 1. 元リポ一式を取得（config/tokenizer 等。safetensors/onnx は除外し容量削減）。
    python - <<"PY"
import os
from huggingface_hub import snapshot_download
snapshot_download(
    os.environ["MODEL_ID"],
    local_dir="/work/out",
    ignore_patterns=["*.safetensors", "*.onnx", "onnx/*", "results*/*", "*.msgpack", "*.h5"],
)
PY
    # 2. optimum で ONNX エクスポート。reranker は sequence-classification（num_labels=1 の関連度スコア）。
    #    TEI は sequence-classification ONNX を自動検出し /rerank を有効化する。
    optimum-cli export onnx --model "${MODEL_ID}" --task text-classification /work/onnx_tmp
    # 3. TEI が探す onnx/model.onnx の位置へ配置（大モデルの外部データ model.onnx_data も同梱）。
    mkdir -p /work/out/onnx
    cp /work/onnx_tmp/model.onnx /work/out/onnx/model.onnx
    [ -f /work/onnx_tmp/model.onnx_data ] && cp /work/onnx_tmp/model.onnx_data /work/out/onnx/ || true
    echo "[export] ---- output layout ----"
    ls -R /work/out | sed -n "1,40p"
    test -f /work/out/onnx/model.onnx && echo "[export] OK: onnx/model.onnx present" || { echo "[export] NG: onnx/model.onnx missing"; exit 1; }
  '

echo "[export] done -> ${OUT_DIR}"
echo "[export] next: docker compose --profile rerank up -d tei-reranker"
