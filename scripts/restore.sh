#!/usr/bin/env bash
# genai-deploy-onpre — 通常リストアスクリプト
#
# ⚠ 危険コマンド境界：本スクリプトは運用担当者がターミナルで対話実行する。
#   cron からの自動実行は不可。下記の二つは破壊的操作であり、誤実行はデータ全損につながる：
#     - pg_restore --clean --if-exists：対象 DB の既存スキーマを破壊的に再構築
#     - SeaweedFS リストア：seaweedfs_data volume の既存内容を完全置換
#   実行前に必ず「事前バックアップ取得済み」「投入する dump／tar の世代」を確認すること。
#
# 切戻し・災害復旧は本スクリプトの対象外（デプロイ手順書のテンプレ参照）。
# 本スクリプトは「通常リストア」＝ バージョン同一・データ消失復旧 のみを扱う。
#
# 使い方:
#   ./scripts/restore.sh logical <postgres.dump> <keycloak_db.dump>
#   ./scripts/restore.sh full    <postgres.dump> <keycloak_db.dump> <seaweedfs.tar.gz>
#
# 推奨手順:
#   1) docker compose ps で全コンテナ healthy を確認
#   2) 本スクリプトを実行（RESTORE 入力で確認）
#   3) 本スクリプトが復元後に app 層（keycloak/api/worker）を自動 restart し healthy 復帰まで待つ
#      （DB／SeaweedFS 直下差替えで stale 化する realm キャッシュ・接続プールの更新）
#   4) web にログインし主要機能（チャット・アップロード等）で整合確認

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

usage() {
  cat <<EOS
使い方:
  $(basename "$0") logical <postgres.dump> <keycloak_db.dump>
  $(basename "$0") full    <postgres.dump> <keycloak_db.dump> <seaweedfs.tar.gz>
EOS
}

MODE="${1:-}"
case "$MODE" in
  logical|full) ;;
  *) usage; exit 2 ;;
esac

shift
PG_DUMP="${1:-}"
KC_DUMP="${2:-}"
SWFS_TAR="${3:-}"

[ -f "$PG_DUMP" ] || { echo "[restore] エラー: postgres dump 不在: $PG_DUMP" >&2; exit 1; }
[ -f "$KC_DUMP" ] || { echo "[restore] エラー: keycloak-db dump 不在: $KC_DUMP" >&2; exit 1; }
if [ "$MODE" = "full" ]; then
  [ -f "$SWFS_TAR" ] || { echo "[restore] エラー: seaweedfs tar 不在: $SWFS_TAR" >&2; exit 1; }
fi

confirm() {
  local prompt="$1"
  echo ""
  echo "⚠  危険コマンドを実行します: $prompt"
  echo "    続行するには RESTORE と入力してください（その他のキーで中止）:"
  IFS= read -r reply
  if [ "$reply" != "RESTORE" ]; then
    echo "[restore] 中止"
    exit 1
  fi
}

COMPOSE_FILES=(-f docker-compose.yml)
[ -f docker-compose.secrets.yml ] && COMPOSE_FILES+=(-f docker-compose.secrets.yml)

dc() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

restore_postgres() {
  local svc="$1" dump="$2"
  local pg_user pg_db
  pg_user="$(dc exec -T "$svc" printenv POSTGRES_USER | tr -d '\r\n')"
  pg_db="$(dc exec -T "$svc"   printenv POSTGRES_DB   | tr -d '\r\n')"
  echo "[restore] $svc: pg_restore --clean --if-exists --no-owner --no-privileges (user=$pg_user db=$pg_db) <- $dump"
  # --no-owner --no-privileges：所有者／権限差分による失敗を回避（DB ロールが本番と検証で異なるケース対応）。
  # --clean --if-exists：既存スキーマを drop してから restore（破壊的）。
  dc exec -T "$svc" pg_restore \
    --clean --if-exists --no-owner --no-privileges \
    -U "$pg_user" -d "$pg_db" < "$dump"
}

readonly SWFS_IMAGE='chrislusf/seaweedfs:4.22@sha256:84429e5f21fad82246f5cfae7b39e9a17da18afb62f2b79c25ccd364ab02793b'

resolve_seaweedfs_volume() {
  local vol
  vol="$(docker volume ls --filter "name=_seaweedfs_data$" --format '{{.Name}}' | head -n 1)"
  if [ -z "$vol" ]; then
    echo "[restore] エラー: seaweedfs_data volume が見つかりません。" >&2
    return 1
  fi
  echo "$vol"
}

restore_seaweedfs() {
  local tar_path="$1"
  local volume_name tar_abs tar_dir tar_base
  volume_name="$(resolve_seaweedfs_volume)"
  tar_abs="$(cd "$(dirname "$tar_path")" && pwd)/$(basename "$tar_path")"
  tar_dir="$(dirname "$tar_abs")"
  tar_base="$(basename "$tar_abs")"

  echo "[restore] seaweedfs: stop -> volume 内容クリア -> tar 展開 -> start (volume=$volume_name)"

  # shellcheck disable=SC2064
  trap "docker compose ${COMPOSE_FILES[*]} start seaweedfs >/dev/null 2>&1 || true" EXIT
  dc stop seaweedfs

  # volume 内容クリア＋tar 展開を 1 コンテナで実施（filer メタと volume の同一時点復元）。
  # /data/* のみでなく dotfile も含めて全消去（vol_dir.uuid 等）。
  docker run --rm \
    --entrypoint /bin/sh \
    -v "$volume_name:/data" \
    -v "$tar_dir:/backup:ro" \
    "$SWFS_IMAGE" \
    -c "rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null; tar xzf '/backup/$tar_base' -C /data"

  dc start seaweedfs
  trap - EXIT

  echo "[restore] seaweedfs: 完了"
}

# ---- 復元後の app 層 restart -----------------------------------
# DB／SeaweedFS を直下で差し替えるため、app 層は古い状態を保持する：
#   - Keycloak：realm をメモリキャッシュ／api・worker：DB 接続プール
# これらを restart して復元データを即座に反映する（logical/full 両モードで stale 化＝両方で実施）。
# worker は profile queue（既定 up 外）のため、実際に稼働中のコンテナだけを対象にする
# （未起動 profile サービスへの restart はエラーになりうるため積集合で構造的に回避）。
APP_SERVICES=(keycloak api worker)
HEALTH_TIMEOUT="${RESTORE_HEALTH_TIMEOUT:-120}"  # restart 後の healthy 復帰待ち上限（秒）

# 対象サービスが running かつ（healthy または healthcheck 未定義＝health 空）になるまで待つ。
wait_healthy() {
  local elapsed=0 interval=3 svc line state health all_ready
  echo "[restore] app 層 healthy 復帰待ち（最大 ${HEALTH_TIMEOUT}s）: $*"
  while [ "$elapsed" -lt "$HEALTH_TIMEOUT" ]; do
    all_ready=1
    for svc in "$@"; do
      line="$(dc ps "$svc" --format '{{.State}}|{{.Health}}' 2>/dev/null | head -n1 || true)"
      state="${line%%|*}"
      health="${line#*|}"
      # running 未満は未復帰。healthcheck 有り（health 非空）なら healthy 必須。
      if [ "$state" != "running" ]; then all_ready=0; break; fi
      if [ -n "$health" ] && [ "$health" != "healthy" ]; then all_ready=0; break; fi
    done
    if [ "$all_ready" -eq 1 ]; then
      echo "[restore] app 層 healthy 復帰: $*"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "[restore] ⚠ healthy 復帰がタイムアウト（${HEALTH_TIMEOUT}s）。docker compose ps で状態を確認してください。" >&2
  # タイムアウトでもスクリプト自体は失敗扱いにしない（復元自体は完了済み・整合確認案内は出す）。
  return 0
}

restart_app_layer() {
  local running targets=() svc
  # 稼働中サービス一覧（profile 無指定でも running なら列挙される＝実機確認済）。
  running="$(dc ps --status running --services 2>/dev/null || true)"
  for svc in "${APP_SERVICES[@]}"; do
    if printf '%s\n' "$running" | grep -qx "$svc"; then
      targets+=("$svc")
    fi
  done
  if [ "${#targets[@]}" -eq 0 ]; then
    echo "[restore] app 層: 稼働中の対象サービスなし（restart スキップ）"
    return 0
  fi
  echo "[restore] app 層 restart: ${targets[*]}（復元データ反映＝realm キャッシュ／接続プール更新）"
  dc restart "${targets[@]}"
  wait_healthy "${targets[@]}"
}

confirm "$MODE リストア (postgres + keycloak-db$([ "$MODE" = "full" ] && echo " + seaweedfs"))"

restore_postgres postgres    "$PG_DUMP"
restore_postgres keycloak-db "$KC_DUMP"
[ "$MODE" = "full" ] && restore_seaweedfs "$SWFS_TAR"

# 復元データを app 層へ即時反映（realm キャッシュ／接続プールの更新）。
restart_app_layer

echo ""
echo "[restore] 完了: mode=$MODE（app 層 restart・healthy 復帰まで実施済み）"
echo "[restore] 次工程（任意）:"
echo "  - 整合確認: web にログインし主要機能（チャット・アップロード等）が動作することを確認"
