#!/usr/bin/env bash
#
# fetch-third-party-licenses.sh
#
# 同梱 OSS の LICENSE / NOTICE を上流から「逐語のまま」回収し、
# LICENSES-THIRD-PARTY/ に保全する。
#
# 背景：本スクリプトは curl が使えるターミナルで手動実行する前提。
#       ダウンロードは raw バイト列のまま保存し、逐語性を壊さないよう
#       再書き込みせず検証と索引整備のみを行う。
#
# 使い方（curl 可能なターミナルで）：
#   cd genai-deploy-onpre
#   bash scripts/fetch-third-party-licenses.sh
#   # 完了後に表示される SUMMARY を確認してください。
#
# 各 OSS について複数の候補 URL を順に試し、最初に HTTP 200 を返したものを採用する。
# 採用 URL を SUMMARY に出力する（version タグ以外＝main/master へフォールバックした
# 場合は、固定版とライセンス本文がズレうるため要注意フラグを立てる）。

set -u
cd "$(dirname "$0")/.." || exit 1
OUT="LICENSES-THIRD-PARTY"
mkdir -p "$OUT"

SUMMARY=()

# fetch_first <outfile> <url1> [url2 ...]
# 最初に 200 を返した URL を outfile に保存。全滅なら MISS。
fetch_first() {
  local outfile="$1"; shift
  local url code
  for url in "$@"; do
    code=$(curl -sSL -m 20 -w '%{http_code}' -o "$OUT/$outfile.tmp" "$url" 2>/dev/null)
    if [ "$code" = "200" ] && [ -s "$OUT/$outfile.tmp" ]; then
      mv "$OUT/$outfile.tmp" "$OUT/$outfile"
      SUMMARY+=("OK   $outfile  <= $url")
      return 0
    fi
  done
  rm -f "$OUT/$outfile.tmp"
  SUMMARY+=("MISS $outfile  (全候補 404/取得不可 — 上流に当該ファイル無しの可能性)")
  return 1
}

echo "== fetching third-party LICENSE / NOTICE (verbatim) =="

# --- PostgreSQL 16.14 (PostgreSQL License; 本文は COPYRIGHT) ---
fetch_first "PostgreSQL_PostgreSQL-License.txt" \
  "https://raw.githubusercontent.com/postgres/postgres/REL_16_14/COPYRIGHT" \
  "https://raw.githubusercontent.com/postgres/postgres/master/COPYRIGHT"

# --- pgvector 0.8.5 (PostgreSQL License) ---
fetch_first "pgvector_PostgreSQL-License.txt" \
  "https://raw.githubusercontent.com/pgvector/pgvector/v0.8.5/LICENSE" \
  "https://raw.githubusercontent.com/pgvector/pgvector/master/LICENSE"

# --- pg_bigm v1.2-20250903 (PostgreSQL License; 導入予定) ---
fetch_first "pg_bigm_PostgreSQL-License.txt" \
  "https://raw.githubusercontent.com/pgbigm/pg_bigm/v1.2-20250903/LICENSE" \
  "https://raw.githubusercontent.com/pgbigm/pg_bigm/master/LICENSE"

# --- Keycloak 26.6.4 (Apache-2.0) ---
fetch_first "Keycloak_Apache-2.0.txt" \
  "https://raw.githubusercontent.com/keycloak/keycloak/26.6.4/LICENSE.txt" \
  "https://raw.githubusercontent.com/keycloak/keycloak/main/LICENSE.txt"
fetch_first "Keycloak-NOTICE.txt" \
  "https://raw.githubusercontent.com/keycloak/keycloak/26.6.4/NOTICE" \
  "https://raw.githubusercontent.com/keycloak/keycloak/26.6.4/NOTICE.txt"

# --- SeaweedFS 4.39 (Apache-2.0) ---
fetch_first "SeaweedFS_Apache-2.0.txt" \
  "https://raw.githubusercontent.com/seaweedfs/seaweedfs/4.39/LICENSE" \
  "https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/LICENSE"
fetch_first "SeaweedFS-NOTICE.txt" \
  "https://raw.githubusercontent.com/seaweedfs/seaweedfs/4.39/NOTICE" \
  "https://raw.githubusercontent.com/seaweedfs/seaweedfs/4.39/NOTICE.txt"

# --- ElasticMQ v1.7.1 (Apache-2.0) ---
# 実ファイル名は LICENSE.txt（拡張子なし LICENSE は上流に無く 404。GitHub contents API で確認・2026-06-02）。
fetch_first "ElasticMQ_Apache-2.0.txt" \
  "https://raw.githubusercontent.com/softwaremill/elasticmq/v1.7.1/LICENSE.txt" \
  "https://raw.githubusercontent.com/softwaremill/elasticmq/v1.7.1/LICENSE" \
  "https://raw.githubusercontent.com/softwaremill/elasticmq/master/LICENSE.txt"
fetch_first "ElasticMQ-NOTICE.txt" \
  "https://raw.githubusercontent.com/softwaremill/elasticmq/v1.7.1/NOTICE" \
  "https://raw.githubusercontent.com/softwaremill/elasticmq/v1.7.1/NOTICE.txt"

# --- Ollama v0.31.2 (MIT) ---
fetch_first "Ollama_MIT.txt" \
  "https://raw.githubusercontent.com/ollama/ollama/v0.31.2/LICENSE" \
  "https://raw.githubusercontent.com/ollama/ollama/main/LICENSE"

# --- Text Embeddings Inference v1.9.3 (Apache-2.0) ---
fetch_first "TEI_Apache-2.0.txt" \
  "https://raw.githubusercontent.com/huggingface/text-embeddings-inference/v1.9.3/LICENSE" \
  "https://raw.githubusercontent.com/huggingface/text-embeddings-inference/main/LICENSE"
fetch_first "TEI-NOTICE.txt" \
  "https://raw.githubusercontent.com/huggingface/text-embeddings-inference/v1.9.3/NOTICE" \
  "https://raw.githubusercontent.com/huggingface/text-embeddings-inference/v1.9.3/NOTICE.txt"

# --- nginx 1.30.3 (BSD-2-Clause) ---
fetch_first "nginx_BSD-2-Clause.txt" \
  "https://raw.githubusercontent.com/nginx/nginx/release-1.30.3/LICENSE" \
  "https://nginx.org/LICENSE"

# --- Mailpit v1.30.4 (MIT) ---
fetch_first "Mailpit_MIT.txt" \
  "https://raw.githubusercontent.com/axllent/mailpit/v1.30.4/LICENSE" \
  "https://raw.githubusercontent.com/axllent/mailpit/develop/LICENSE"

# --- Dozzle v10.6.9 (MIT) ---
fetch_first "Dozzle_MIT.txt" \
  "https://raw.githubusercontent.com/amir20/dozzle/v10.6.9/LICENSE" \
  "https://raw.githubusercontent.com/amir20/dozzle/master/LICENSE"

# --- speaches 0.8.3 (MIT; profile transcribe の STT serving・faster-whisper 同梱) ---
fetch_first "speaches_MIT.txt" \
  "https://raw.githubusercontent.com/speaches-ai/speaches/0.8.3/LICENSE" \
  "https://raw.githubusercontent.com/speaches-ai/speaches/v0.8.3/LICENSE" \
  "https://raw.githubusercontent.com/speaches-ai/speaches/master/LICENSE"

# --- Node.js v24.15.0 (MIT 系; api ベースイメージ) ---
fetch_first "Node.js_MIT.txt" \
  "https://raw.githubusercontent.com/nodejs/node/v24.15.0/LICENSE" \
  "https://raw.githubusercontent.com/nodejs/node/main/LICENSE"

# --- vLLM v0.21.0 (Apache-2.0; 既定構成外・任意) ---
fetch_first "vLLM_Apache-2.0.txt" \
  "https://raw.githubusercontent.com/vllm-project/vllm/v0.21.0/LICENSE" \
  "https://raw.githubusercontent.com/vllm-project/vllm/main/LICENSE"
fetch_first "vLLM-NOTICE.txt" \
  "https://raw.githubusercontent.com/vllm-project/vllm/v0.21.0/NOTICE" \
  "https://raw.githubusercontent.com/vllm-project/vllm/v0.21.0/NOTICE.txt"

# === 画像生成サーバ（profile: image・自前ビルド） ===
# stable-diffusion.cpp のビルド ref は sdcpp/Dockerfile の ARG SDCPP_REF と一致させること（固定 SHA）。
SDCPP_REF="${SDCPP_REF:-92dc7268fc4ffb0c0cc0bd52dfcefea91326e797}"
fetch_first "stable-diffusion.cpp_MIT.txt" \
  "https://raw.githubusercontent.com/leejet/stable-diffusion.cpp/${SDCPP_REF}/LICENSE" \
  "https://raw.githubusercontent.com/leejet/stable-diffusion.cpp/master/LICENSE"

# === Code Interpreter サンドボックス同梱コンポーネント（profile: sandbox・自前ビルド） ===
# NsJail のビルド ref は sandbox/Dockerfile の ARG NSJAIL_REF と一致させること（PoC 確定 SHA）。
NSJAIL_REF="${NSJAIL_REF:-3.4}"
fetch_first "NsJail_Apache-2.0.txt" \
  "https://raw.githubusercontent.com/google/nsjail/${NSJAIL_REF}/LICENSE" \
  "https://raw.githubusercontent.com/google/nsjail/master/LICENSE"
fetch_first "NsJail-NOTICE.txt" \
  "https://raw.githubusercontent.com/google/nsjail/${NSJAIL_REF}/NOTICE" \
  "https://raw.githubusercontent.com/google/nsjail/${NSJAIL_REF}/NOTICE.txt"
# pandas 2.2.3 (BSD-3-Clause)
fetch_first "pandas_BSD-3-Clause.txt" \
  "https://raw.githubusercontent.com/pandas-dev/pandas/v2.2.3/LICENSE" \
  "https://raw.githubusercontent.com/pandas-dev/pandas/main/LICENSE"
# NumPy 2.2.1 (BSD-3-Clause)
fetch_first "NumPy_BSD-3-Clause.txt" \
  "https://raw.githubusercontent.com/numpy/numpy/v2.2.1/LICENSE.txt" \
  "https://raw.githubusercontent.com/numpy/numpy/main/LICENSE.txt"
# matplotlib 3.10.0 (matplotlib License; PSF/BSD 系・要文面確認)
fetch_first "matplotlib_License.txt" \
  "https://raw.githubusercontent.com/matplotlib/matplotlib/v3.10.0/LICENSE/LICENSE" \
  "https://raw.githubusercontent.com/matplotlib/matplotlib/main/LICENSE/LICENSE"
# openpyxl 3.1.5 (MIT; 上流は heptapod。要 URL 確認・MISS 時は PyPI sdist の LICENCE から)
fetch_first "openpyxl_MIT.txt" \
  "https://foss.heptapod.net/openpyxl/openpyxl/-/raw/3.1.5/LICENCE.rst" \
  "https://foss.heptapod.net/openpyxl/openpyxl/-/raw/branch/default/LICENCE.rst"
# Python (PSF; slim ベース。実パッチ版に合わせる。要確認)
fetch_first "Python_PSF.txt" \
  "https://raw.githubusercontent.com/python/cpython/3.13/LICENSE" \
  "https://raw.githubusercontent.com/python/cpython/main/LICENSE"
# 注: IPAex Gothic（IPA Font License v1.0）は authoritative なビルド済みイメージ内
#   /usr/share/doc/fonts-ipaexfont-gothic/copyright から抽出して
#   LICENSES-THIRD-PARTY/IPAexGothic_IPA-Font-License.txt へ保全する（raw URL ではなくパッケージ同梱版が確実）:
#     docker run --rm genai-sandbox-onpre:nsjail-py313 \
#       cat /usr/share/doc/fonts-ipaexfont-gothic/copyright > LICENSES-THIRD-PARTY/IPAexGothic_IPA-Font-License.txt

echo ""
echo "================ SUMMARY ================"
printf '%s\n' "${SUMMARY[@]}"
echo "================================================================================"
echo "MISS の NOTICE は『上流が NOTICE を配布していない』ことの確認結果として扱います。"
echo "OK でも採用 URL が version タグでなく main/master の場合は要確認です"
echo "（固定版と本文がズレうるため要確認フラグを立てます）。"
