#!/usr/bin/env bash
# genai-deploy-onpre — 法令 RAG dump エクスポート（メンテナ用）
#
# 稼働中 postgres から法令 3 テーブルを data-only で pg_dump し、配布用 dump を作る。
# スキーマ（テーブル・インデックス）は prisma migrate が作る前提のため data-only。
# GitHub Releases アセット（1 ファイル 2GB 上限）に合わせ、閾値超過時は分割する。
#
# 対象テーブル（e-Gov 由来のグローバル公開データ・owner_user_id を持たない）:
#   dwh_laws / app_laws_master / app_laws_for_indexing
#
# 使い方:
#   ./scripts/law-rag-export.sh                   既定: ./dist に law-rag-<TS>.dump 生成
#   ./scripts/law-rag-export.sh /path/to/outdir   出力先指定
#
# 環境変数:
#   SPLIT_BYTES  分割閾値（既定 1900M）。dump がこれを超えたら .part-NN に分割する。
#
# 出力後の運用:
#   生成された dump（または .part-NN 群）を GitHub Releases にアセットとして
#   アップロードする。アップロード時の命名規約:
#     - アセット名はタイムスタンプを外して law-rag.dump（分割時は law-rag.dump.part-NN）にリネーム。
#     - リリースタグは law-rag-<e-Gov 取得日 YYYYMMDD>（例 law-rag-20260705）。
#   利用者側は scripts/law-rag-import.sh（既定でこの配布先を参照）で取得・投入する。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="${1:-$REPO_ROOT/dist}"
TS="$(date +%Y%m%d-%H%M%S)"
SPLIT_BYTES="${SPLIT_BYTES:-1900M}"
LAW_TABLES=(dwh_laws app_laws_master app_laws_for_indexing)

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

COMPOSE_FILES=(-f docker-compose.yml)
[ -f docker-compose.secrets.yml ] && COMPOSE_FILES+=(-f docker-compose.secrets.yml)
dc() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

# container 内 env から DB 接続情報を取得（backup.sh と同一流儀）。
pg_user="$(dc exec -T postgres printenv POSTGRES_USER | tr -d '\r\n')"
pg_db="$(dc exec -T postgres   printenv POSTGRES_DB   | tr -d '\r\n')"

# テーブル存在チェック（migrate 済みか）。
for t in "${LAW_TABLES[@]}"; do
  exists="$(dc exec -T postgres psql -U "$pg_user" -d "$pg_db" -tAc \
    "SELECT to_regclass('public.$t') IS NOT NULL;" | tr -d '\r\n')"
  [ "$exists" = "t" ] || {
    echo "[export] エラー: テーブル $t が存在しません（migrate 未実行？）" >&2
    exit 1
  }
done

t_args=()
for t in "${LAW_TABLES[@]}"; do t_args+=(-t "$t"); done

OUT="$OUT_DIR/law-rag-${TS}.dump"
echo "[export] pg_dump data-only -F custom -Z 9 (${LAW_TABLES[*]}) -> $OUT"
# -F custom：pg_restore 可・圧縮内蔵。--data-only：スキーマは migrate 側。
# --no-owner --no-privileges：復元先のロール差分による失敗を回避。
dc exec -T postgres pg_dump -U "$pg_user" -d "$pg_db" \
  -F custom -Z 9 --data-only --no-owner --no-privileges \
  "${t_args[@]}" > "$OUT"
chmod 600 "$OUT"

echo "[export] 行数（控え）:"
for t in "${LAW_TABLES[@]}"; do
  n="$(dc exec -T postgres psql -U "$pg_user" -d "$pg_db" -tAc "SELECT count(*) FROM $t;" | tr -d '\r\n')"
  printf '  %-24s %s\n' "$t" "$n"
done

size_bytes="$(stat -c %s "$OUT")"
echo "[export] サイズ: ${size_bytes} bytes"

# 2GB 上限対策：閾値超過なら分割。
threshold_bytes="$(numfmt --from=iec "$SPLIT_BYTES")"
if [ "$size_bytes" -gt "$threshold_bytes" ]; then
  echo "[export] GitHub Releases 2GB 上限対策: ${SPLIT_BYTES} 単位で分割します"
  split -b "$SPLIT_BYTES" -d -a 2 "$OUT" "${OUT}.part-"
  rm -f "$OUT"
  echo "[export] 分割ファイル（すべてアップロードすること）:"
  ls -1 "${OUT}.part-"*
  for f in "${OUT}.part-"*; do sha256sum "$f"; done
  echo "[export] 利用者側はすべての .part-NN を取得→結合して投入する（import スクリプトが自動結合）。"
else
  sha256sum "$OUT"
fi

echo "[export] 完了。GitHub Releases にアセットとしてアップロードしてください。"
