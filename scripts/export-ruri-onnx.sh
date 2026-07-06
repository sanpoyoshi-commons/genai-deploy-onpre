#!/usr/bin/env bash
# ruri-v3-310m を公式 safetensors から ONNX へ自前エクスポートする（embeddings 用）。
#
# 背景：ruri-v3-310m（ModernBERT）の公式 HF リポは safetensors のみで ONNX 非同梱。TEI cpu イメージは
# ORT(ONNX) が主経路で、ONNX 不在時の candle/ModernBERT/CPU フォールバックは warmup で落ちる
# （live e2e 2026-05-27 発覚）。本スクリプトは公式 cl-nagoya/ruri-v3-310m（Apache-2.0）から
# sentence-transformers の ONNX バックエンドで ONNX を生成し、TEI が期待する layout（モデル一式＋
# onnx/model.onnx）で ./tei/models/ruri-v3-310m-onnx へ出力する。第三者 ONNX 版に依存しない
# （公式 safetensors から自前生成のため第三者 ONNX 配布に非依存）。一度きりの実行（成果物はホストに残る）。
#
# 使い方（deploy リポ直下で）：
#   bash scripts/export-ruri-onnx.sh
# 生成後（tei は OOM 対策で embedding profile へ分離済み）：
#   docker compose --profile embedding up -d --force-recreate tei
#   docker compose logs tei   # ログに Ready が出れば serving 開始
set -euo pipefail

MODEL_ID="${1:-cl-nagoya/ruri-v3-310m}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/tei/models/ruri-v3-310m-onnx"
# エクスポートに使う Python イメージ（pip でクリーンに依存を入れる。HF キャッシュは out 配下に隔離）。
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
    # 1. 元の sentence-transformers リポ一式を取得（config/tokenizer/modules.json/1_Pooling/ 等）。
    #    safetensors と results は不要（onnx を使う・容量削減）。TEI はこれらの ST 設定で pooling を適用する。
    python - <<"PY"
import os
from huggingface_hub import snapshot_download
snapshot_download(
    os.environ["MODEL_ID"],
    local_dir="/work/out",
    ignore_patterns=["*.safetensors", "*.onnx", "onnx/*", "results*/*", "*.msgpack", "*.h5"],
)
PY
    # 2. optimum で ONNX をエクスポート（feature-extraction＝エンコーダのみ。pooling は TEI 側が適用）。
    #    ST v5 の save_pretrained 経路（AutoProcessor 要求で ruri に非対応）を回避し optimum-cli 直叩き。
    optimum-cli export onnx --model "${MODEL_ID}" --task feature-extraction /work/onnx_tmp
    # 3. TEI が探す onnx/model.onnx の位置へ配置（大モデルの外部データ model.onnx_data も同梱）。
    mkdir -p /work/out/onnx
    cp /work/onnx_tmp/model.onnx /work/out/onnx/model.onnx
    [ -f /work/onnx_tmp/model.onnx_data ] && cp /work/onnx_tmp/model.onnx_data /work/out/onnx/ || true
    echo "[export] ---- output layout ----"
    ls -R /work/out | sed -n "1,40p"
    test -f /work/out/onnx/model.onnx && echo "[export] OK: onnx/model.onnx present" || { echo "[export] NG: onnx/model.onnx missing"; exit 1; }
  '

echo "[export] done -> ${OUT_DIR}"
echo "[export] next: docker compose --profile embedding up -d --force-recreate tei"
