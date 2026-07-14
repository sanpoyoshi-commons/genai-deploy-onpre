#!/usr/bin/env bash
# genai-deploy-onpre — 法令 RAG dump インポート（利用者用）
#
# 事前ビルド dump（data-only）を稼働中 postgres へ投入する。47 時間の自前 ingest を省ける。
#
# ⚠ 危険コマンド境界：本スクリプトは運用者がターミナルで対話実行する（cron 不可）。
#   法令 3 テーブルを TRUNCATE してから投入する破壊的操作（RESTORE 入力で確認）。
#   対象は e-Gov 由来のグローバル公開データ（dwh_laws / app_laws_master /
#   app_laws_for_indexing）であり、利用者固有データ（rag_* 等）には触れない。
#
# 前提:
#   - docker compose up 済み（postgres healthy）かつ migrate 適用済み（法令テーブルが存在）。
#   - RAG を使うため embedding profile（tei）も併用するのが通常（README システム要件参照）。
#
# 使い方:
#   ./scripts/law-rag-import.sh <dump ファイル>     ローカルの dump を投入（分割 .part-NN も自動結合）
#   ./scripts/law-rag-import.sh --from-release      GitHub Release から取得して投入
#
# --from-release 時の環境変数（いずれも既定値あり・別の配布先/版を使う場合のみ指定）:
#   GITHUB_OWNER  GitHub ユーザー/組織名（既定 sanpoyoshi-commons）
#   GITHUB_REPO   リポジトリ名（既定 genai-deploy-onpre）
#   RELEASE_TAG   リリースタグ（既定 law-rag-20260713＝e-Gov 取得日 law-rag-YYYYMMDD）
#   ASSET_NAME    アセット名（既定 law-rag.dump）。分割時は <ASSET_NAME>.part-00.. を順に取得し結合。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LAW_TABLES=(dwh_laws app_laws_master app_laws_for_indexing)

usage() {
  cat <<EOS
使い方:
  $(basename "$0") <dump ファイル>     ローカル dump を投入（分割 .part-NN は自動結合）
  $(basename "$0") --from-release      GitHub Release から取得して投入
                                       （既定 sanpoyoshi-commons / law-rag-20260713。上書きは環境変数）
EOS
}

COMPOSE_FILES=(-f docker-compose.yml)
[ -f docker-compose.secrets.yml ] && COMPOSE_FILES+=(-f docker-compose.secrets.yml)
dc() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

confirm() {
  local prompt="$1"
  echo ""
  echo "⚠  危険コマンドを実行します: $prompt"
  echo "    続行するには RESTORE と入力してください（その他のキーで中止）:"
  IFS= read -r reply
  [ "$reply" = "RESTORE" ] || { echo "[import] 中止"; exit 1; }
}

download_from_release() {
  local owner="${GITHUB_OWNER:-sanpoyoshi-commons}"
  local tag="${RELEASE_TAG:-law-rag-20260713}"
  local repo="${GITHUB_REPO:-genai-deploy-onpre}"
  local asset="${ASSET_NAME:-law-rag.dump}"
  local base="https://github.com/${owner}/${repo}/releases/download/${tag}"
  local dl_dir="$REPO_ROOT/dist"
  mkdir -p "$dl_dir"
  local out="$dl_dir/$asset"

  # まず単一アセットを試す。
  if curl -fSL -o "$out" "$base/$asset"; then
    echo "$out"
    return 0
  fi
  # 単一が無ければ分割アセット（.part-00, .part-01, ...）を順に取得して結合。
  rm -f "$out"
  local i=0 idx part
  while :; do
    printf -v idx '%02d' "$i"
    part="${asset}.part-${idx}"
    if curl -fSL -o "$dl_dir/$part" "$base/$part"; then
      i=$((i + 1))
    else
      break
    fi
  done
  [ "$i" -gt 0 ] || { echo "[import] エラー: アセットが見つかりません（$asset / ${asset}.part-00）" >&2; exit 1; }
  cat "$dl_dir/${asset}.part-"* > "$out"
  echo "$out"
}

# ---- 引数処理 -----------------------------------------------------------------
DUMP=""
case "${1:-}" in
  --from-release) DUMP="$(download_from_release)" ;;
  ""            ) usage; exit 2 ;;
  *             ) DUMP="$1" ;;
esac

# ローカルで分割ファイルだけがある場合は結合する。
if [ ! -f "$DUMP" ]; then
  if compgen -G "${DUMP}.part-"* >/dev/null; then
    echo "[import] 分割ファイルを結合: ${DUMP}.part-*"
    cat "${DUMP}.part-"* > "$DUMP"
  else
    echo "[import] エラー: dump 不在: $DUMP" >&2
    exit 1
  fi
fi

# ---- 接続情報・前提チェック ---------------------------------------------------
pg_user="$(dc exec -T postgres printenv POSTGRES_USER | tr -d '\r\n')"
pg_db="$(dc exec -T postgres   printenv POSTGRES_DB   | tr -d '\r\n')"

for t in "${LAW_TABLES[@]}"; do
  exists="$(dc exec -T postgres psql -U "$pg_user" -d "$pg_db" -tAc \
    "SELECT to_regclass('public.$t') IS NOT NULL;" | tr -d '\r\n')"
  [ "$exists" = "t" ] || {
    echo "[import] エラー: テーブル $t が存在しません。先に migrate を適用してください:" >&2
    echo "    docker compose ${COMPOSE_FILES[*]} run --rm migrate" >&2
    exit 1
  }
done

tbl_csv="$(IFS=, ; echo "${LAW_TABLES[*]}")"

confirm "法令 RAG インポート（${tbl_csv} を TRUNCATE して dump を投入）<- $DUMP"

# ---- TRUNCATE -> data-only restore -------------------------------------------
echo "[import] TRUNCATE: $tbl_csv"
dc exec -T postgres psql -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 \
  -c "TRUNCATE ${tbl_csv};"

echo "[import] pg_restore --data-only --disable-triggers <- $DUMP"
# --disable-triggers：data-only 投入時の制約/トリガを抑止（postgres ロールは superuser）。
dc exec -T postgres pg_restore \
  --data-only --no-owner --no-privileges --disable-triggers \
  -U "$pg_user" -d "$pg_db" < "$DUMP"

echo "[import] ANALYZE + 行数確認:"
for t in "${LAW_TABLES[@]}"; do
  dc exec -T postgres psql -U "$pg_user" -d "$pg_db" -q -c "ANALYZE $t;" >/dev/null
  n="$(dc exec -T postgres psql -U "$pg_user" -d "$pg_db" -tAc "SELECT count(*) FROM $t;" | tr -d '\r\n')"
  printf '  %-24s %s\n' "$t" "$n"
done

echo ""
echo "[import] 完了。RAG（文書検索）で法令検索が利用できます。"
echo "[import] 疎通確認（任意）: web の法令調査フォームから質問して動作確認できます。"
