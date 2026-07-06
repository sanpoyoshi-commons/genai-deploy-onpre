#!/usr/bin/env bash
# genai-deploy-onpre — web (genai-web-onpre) をビルドして ./web/ へ配置する。
#
# deploy はフロントエンドのビルド済み成果物（バイナリ）を同梱しない方針。本スクリプトが
# 横並び配置した ../genai-web-onpre から dist を生成し、nginx 配信先 ./web/ に置く。
# （api は docker compose が ../genai-ai-api-onpre から直接ビルドするため対象外）。
#
# ビルドは **Docker コンテナ内（node 固定版）** で行う。理由：
#   - ホストに node/mise が無くても動く（Docker は本スタックの前提なので確実に在る）。
#   - genai-web-onpre の engines/mise が要求する node 22.22.2 を確実に使える。
#   - WSL では素の `npm` が Windows 版 node を掴み UNC パスでビルド不能になる罠を回避する。
#
# onpre 用の VITE 焼き込み値は localhost トポロジ固定・非秘密のため既定値を埋め込む。
# 別トポロジ（LAN 公開でホスト名を変える等）では実行前に環境変数で上書きできる：
#   OIDC_AUTHORITY  例 https://192.168.1.50/auth/realms/genai-realm
#   OIDC_CLIENT_ID / OIDC_SCOPE / API_ENDPOINT / TEAM_API_ENDPOINT / WEB_SRC / NODE_IMAGE
#   TOP_CHAT_SYSTEM_PROMPT  トップページの直接チャット入力を有効化（空＝無効・既定）。
#     例 TOP_CHAT_SYSTEM_PROMPT="あなたは有能なアシスタントです" ./scripts/build-web.sh
#
# 使い方（deploy リポジトリ直下で）：
#   ./scripts/build-web.sh
#
# 注：モデル一覧・機能 ON/OFF はランタイム（nginx /config.js → window.__APP_CONFIG__、
#     .env の MODEL_IDS 等）で注入されるため、build 時の指定は不要（再ビルド不要で切替可）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_SRC="${WEB_SRC:-$REPO_ROOT/../genai-web-onpre}"
WEB_DIST="$WEB_SRC/packages/web/dist"
WEB_OUT="$REPO_ROOT/web"

# ビルド用 node イメージ（genai-web-onpre の mise.toml/engines = node 22.22.2 に一致）。
# 必要なら digest 固定推奨（docker-compose の OSS 固定運用と同様）。
NODE_IMAGE="${NODE_IMAGE:-node:22.22.2-slim}"

# onpre 既定の VITE 焼き込み値（localhost 経由・非秘密。環境変数で上書き可）
API_ENDPOINT="${API_ENDPOINT:-/api}"                       # nginx 同一オリジン（相対）
TEAM_API_ENDPOINT="${TEAM_API_ENDPOINT:-/api}"
OIDC_AUTHORITY="${OIDC_AUTHORITY:-https://localhost/auth/realms/genai-realm}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-genai-web}"
OIDC_SCOPE="${OIDC_SCOPE:-openid profile email}"
# トップページ直接チャット入力（LandingForm）のシステムプロンプト。空＝当該フォーム非表示（既定・オプトイン）。
TOP_CHAT_SYSTEM_PROMPT="${TOP_CHAT_SYSTEM_PROMPT:-}"

if [ ! -d "$WEB_SRC" ]; then
  echo "[build-web] エラー: web ソースが見つかりません: $WEB_SRC" >&2
  echo "[build-web]   3 リポを横並び（~/work/{genai-deploy-onpre,genai-ai-api-onpre,genai-web-onpre}）に配置してください。" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "[build-web] エラー: docker が必要です（コンテナ内でビルドします）。" >&2
  exit 1
fi

echo "[build-web] Docker(${NODE_IMAGE}) 内で web をビルド（npm ci && web:build）..."
docker run --rm \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp -e npm_config_cache=/tmp/.npm \
  -e VITE_APP_API_ENDPOINT="$API_ENDPOINT" \
  -e VITE_APP_TEAM_ACCESS_CONTROL_API_ENDPOINT="$TEAM_API_ENDPOINT" \
  -e VITE_APP_OIDC_AUTHORITY="$OIDC_AUTHORITY" \
  -e VITE_APP_OIDC_CLIENT_ID="$OIDC_CLIENT_ID" \
  -e VITE_APP_OIDC_SCOPE="$OIDC_SCOPE" \
  -e VITE_APP_TOP_CHAT_SYSTEM_PROMPT="$TOP_CHAT_SYSTEM_PROMPT" \
  -v "$WEB_SRC":/src -w /src \
  "$NODE_IMAGE" \
  sh -lc 'npm ci && npm run web:build'

if [ ! -d "$WEB_DIST" ]; then
  echo "[build-web] エラー: ビルド成果物が見つかりません: $WEB_DIST" >&2
  exit 1
fi

echo "[build-web] ./web/ へ配置（旧成果物を一掃）..."
# ディレクトリ自体は削除せず中身だけ消す（inode 保持）。起動中に rm -rf ./web すると
# nginx の bind マウントが消えた古い inode を指したまま空に見え、403（directory index
# forbidden）になるため。中身入れ替えなら稼働中 nginx でも再作成不要でそのまま反映される。
mkdir -p "$WEB_OUT"
find "$WEB_OUT" -mindepth 1 -delete
cp -a "$WEB_DIST"/. "$WEB_OUT"/

# サニティチェック：旧ブランディングが残っていないか
if grep -rq "検証環境" "$WEB_OUT" 2>/dev/null; then
  echo "[build-web] 警告: '検証環境' が残存。web ソースが最新か確認してください（git -C \"$WEB_SRC\" pull）。" >&2
fi

echo "[build-web] 完了: $WEB_OUT"
echo "[build-web] 反映: 起動済みならブラウザを強制リロード。未起動なら docker compose up -d。"
