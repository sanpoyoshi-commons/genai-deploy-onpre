#!/usr/bin/env bash
# 自前エクスポート済みの fp32 ONNX（ruri-v3-310m 埋め込み／ruri-v3-reranker-310m リランカ）を
# dynamic int8 量子化し、別ディレクトリへ出力する（embedding/リランカ高速化・案1）。
#
# 背景：本番経路 e2e で CPU 速度限界が定量化された＝ingest 約35 chunk/分（tei 約4.6コア飽和）／
# rerank 35〜43秒/クエリ（候補20・cross-encoder）。精度は規程水準（Hit@1 90%/MRR0.95）達成済だが、
# 1台・CPU 既定での実用速度が課題。案1＝モデルの int8 量子化で CPU スループットを
# 引き上げる（推測：数倍。精度トレードオフは量子化前後の実測で判定する＝「まず実測してから判定」）。
#
# 設計：
#   - 着手順は案1先行（量子化でモデル版を固定→将来の dump/差分ジョブの前提）。案2/3 は後続へ送り。
#   - 量子化のみ先行（RERANK_CANDIDATES 削減併用は今回見送り）。
#   - 既存 fp32 ONNX を入力に「ローカル変換」＝HuggingFace 再 DL 不要（export-ruri-*-onnx.sh が生成済の
#     onnx/model.onnx を量子化するだけ）。dynamic 量子化はキャリブレーションデータ不要＝法令コーパス非依存。
#   - 出力は別ディレクトリ（<src>-int8）に分け、fp32 と int8 を並存。切替は compose の EMBEDDING_MODEL_PATH /
#     RERANKER_MODEL_PATH を int8 パスへ向けるだけ（A/B 比較・即時切戻し可）。
#   - 量子化済 onnx は <out>/onnx/model.onnx に配置＝TEI 既定レイアウトに合わせる（--model-id で読める）。
#
# 量子化方式：onnxruntime dynamic quantization（重みを int8、活性化は実行時に動的量子化）。
#   ARCH で命令セットを選ぶ（既定 avx512_vnni＝近年の Intel/AMD で最速）。VNNI 非対応 CPU や精度劣化が
#   許容外の場合は ARCH=avx2 で再実行（reduce_range で安全側・互換重視）。生成モデル自体はどの CPU でも動作する。
#
# 使い方（deploy リポ直下で。pip install を伴うため手動で実行する。
#         ただし HuggingFace モデル DL は不要＝既存 fp32 ONNX のローカル変換のみ）：
#   bash scripts/quantize-onnx-int8.sh                       # 埋め込み・リランカ両方を量子化
#   bash scripts/quantize-onnx-int8.sh embedding             # 埋め込みのみ
#   bash scripts/quantize-onnx-int8.sh reranker              # リランカのみ
#   ARCH=avx2 bash scripts/quantize-onnx-int8.sh             # 互換重視（精度比較用）
# 生成後（compose 既定が既に *-int8 を指すため env 指定は不要。tei は embedding profile へ分離済み）：
#   docker compose --profile embedding --profile rerank up -d --force-recreate tei tei-reranker
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${ROOT}/tei/models"
ARCH="${ARCH:-avx512_vnni}"            # avx512_vnni | avx512 | avx2 | arm64
PY_IMAGE="python:3.12-slim"
TARGET="${1:-both}"                    # both | embedding | reranker

# 量子化対象（fp32 入力ディレクトリ名）。出力は同名 + -int8。
EMBED_SRC="ruri-v3-310m-onnx"
RERANK_SRC="ruri-v3-reranker-310m-onnx"

quantize_one() {
  local src_name="$1"
  local src_dir="${MODELS_DIR}/${src_name}"
  local out_name="${src_name}-int8"
  local out_dir="${MODELS_DIR}/${out_name}"

  if [ ! -f "${src_dir}/onnx/model.onnx" ]; then
    echo "[quantize] NG: ${src_dir}/onnx/model.onnx が無い。先に export-ruri*-onnx.sh を実行のこと。" >&2
    exit 1
  fi

  echo "[quantize] src  = ${src_dir}"
  echo "[quantize] out  = ${out_dir}"
  echo "[quantize] arch = ${ARCH}"
  # 再生成時の取り違え防止：既存の出力は上書きせずエラー終了する（破壊的削除を避ける＝rm -rf 不使用）。
  # 別 ARCH で作り直す等は、手動で当該ディレクトリを削除してから再実行のこと。
  if [ -e "${out_dir}" ]; then
    echo "[quantize] NG: ${out_dir} が既に存在します。再生成する場合は手動で削除してから実行してください。" >&2
    exit 1
  fi
  mkdir -p "${out_dir}"

  docker run --rm \
    -e ARCH="${ARCH}" \
    -e HF_HOME=/work/.hf-cache \
    -v "${src_dir}:/work/src:ro" \
    -v "${out_dir}:/work/out" \
    -w /work \
    "${PY_IMAGE}" bash -lc '
      set -euo pipefail
      pip install --no-cache-dir -q -U "optimum[onnxruntime]>=1.24" "onnx" "onnxruntime>=1.20"
      # 1. fp32 一式（config/tokenizer/modules.json/1_Pooling 等）を出力へコピー。onnx/ は量子化版で差し替えるので除外。
      python - <<"PY"
import shutil, os
src, out = "/work/src", "/work/out"
for name in os.listdir(src):
    if name == "onnx":
        continue
    s = os.path.join(src, name)
    d = os.path.join(out, name)
    if os.path.isdir(s):
        shutil.copytree(s, d, dirs_exist_ok=True)
    else:
        shutil.copy2(s, d)
print("[quantize] copied non-onnx assets")
PY
      # 2. dynamic int8 量子化。optimum の ORTQuantizer で arch プリセットに沿って重みを int8 化（活性化は実行時動的）。
      #    入力＝/work/src/onnx/model.onnx、出力＝/work/out/onnx/model_quantized.onnx。
      python - <<"PY"
import os
from optimum.onnxruntime import ORTQuantizer
from optimum.onnxruntime.configuration import AutoQuantizationConfig

arch = os.environ["ARCH"]
factory = {
    "avx512_vnni": lambda: AutoQuantizationConfig.avx512_vnni(is_static=False, per_channel=True),
    "avx512":      lambda: AutoQuantizationConfig.avx512(is_static=False, per_channel=True),
    "avx2":        lambda: AutoQuantizationConfig.avx2(is_static=False, per_channel=True),
    "arm64":       lambda: AutoQuantizationConfig.arm64(is_static=False, per_channel=True),
}
if arch not in factory:
    raise SystemExit(f"[quantize] unknown ARCH={arch} (avx512_vnni|avx512|avx2|arm64)")
qconfig = factory[arch]()
quantizer = ORTQuantizer.from_pretrained("/work/src/onnx", file_name="model.onnx")
quantizer.quantize(save_dir="/work/out/onnx", quantization_config=qconfig)
print("[quantize] dynamic int8 done (arch=%s)" % arch)
PY
      # 3. TEI 既定の onnx/model.onnx 名に正規化（optimum は model_quantized.onnx を出すため改名）。
      cd /work/out/onnx
      if [ -f model_quantized.onnx ]; then
        # fp32 の重複（コピーされていれば）を消し、量子化版を model.onnx にする。
        rm -f model.onnx model.onnx_data
        mv model_quantized.onnx model.onnx
        [ -f model_quantized.onnx_data ] && mv model_quantized.onnx_data model.onnx_data || true
      fi
      ls -la /work/out/onnx
      test -f /work/out/onnx/model.onnx && echo "[quantize] OK: onnx/model.onnx present" || { echo "[quantize] NG: model.onnx missing"; exit 1; }
    '

  echo "[quantize] done -> ${out_dir}"
  # サイズ比（fp32 → int8）を表示。おおむね 1/4 になれば dynamic int8 が効いている。
  local fp32_sz int8_sz
  fp32_sz=$(du -m "${src_dir}/onnx/model.onnx" | cut -f1)
  int8_sz=$(du -m "${out_dir}/onnx/model.onnx" | cut -f1)
  echo "[quantize] size: fp32=${fp32_sz}MB -> int8=${int8_sz}MB (${src_name})"
}

case "${TARGET}" in
  embedding) quantize_one "${EMBED_SRC}" ;;
  reranker)  quantize_one "${RERANK_SRC}" ;;
  both)      quantize_one "${EMBED_SRC}"; quantize_one "${RERANK_SRC}" ;;
  *) echo "usage: $0 [both|embedding|reranker]   (ARCH=avx512_vnni|avx512|avx2|arm64)" >&2; exit 2 ;;
esac

echo "[quantize] all done. next: compose 既定が *-int8 を指すため env 指定は不要。"
echo "[quantize]   docker compose --profile embedding --profile rerank up -d --force-recreate tei tei-reranker  で起動/再作成"
