#!/usr/bin/env bash
# genai-deploy-onpre — バックアップ統合スクリプト
#
# 「論理＋物理の二層」のうち、本スクリプトは個人開発者 1 人の運用を想定し
# 以下の二モードを提供する：
#   logical  業務 DB（postgres）＋ 認証 DB（keycloak-db）の論理バックアップのみ
#            ＝ pg_dump（稼働中安全、MVCC、ダウンタイムゼロ）
#   full     上記＋ SeaweedFS の物理バックアップ
#            ＝ コンテナ停止 → /data 全体を tar gz → 再起動（数分〜のダウンタイムを許容）
#
# SeaweedFS の物理バックアップを「停止→tar→起動」で取る理由：
#   SeaweedFS の at-rest 暗号化（-s3.encryptVolumeData / -filer.encryptVolumeData）は
#   AES256-GCM ・ チャンク毎ランダム鍵で暗号化し、その鍵は filer メタデータ（LevelDB2、
#   /data/filerldb2/）に保存される。volume データ（/data/{N}.dat/.idx/.vif）と filer メタの
#   どちらか一方のみを復元すると復号不能となるため、両者を「同一時点」で取得する必要がある。
#   LevelDB2 はプロセスダウン時にロック解放＋整合状態になるため、コンテナを停止してから
#   /data 全体を tar することで暗号化鍵保全と整合取得を同時に満たす。
#   オンラインバックアップ（weed filer.backup 等）は暗号化鍵保全の検証が未完であり
#   現時点では「停止→tar→起動」が最も堅実な解。
#
# 使い方:
#   ./scripts/backup.sh logical                    既定: ./backups/ に出力（日次 cron 想定）
#   ./scripts/backup.sh full                       既定: ./backups/ に出力（週次 cron 想定）
#   ./scripts/backup.sh logical /path/to/outdir    出力先指定
#   ./scripts/backup.sh full    /path/to/outdir    出力先指定
#
# cron 登録例（運用テンプレ）：
#   # /etc/cron.d/genai-deploy-onpre-backup（root）
#   # 日次（2:00、論理バックアップのみ・ダウンタイムなし）
#   0 2 * * * youruser cd ~/work/genai-deploy-onpre && ./scripts/backup.sh logical /var/backups/genai >> /var/log/genai-backup.log 2>&1
#   # 週次（日曜 3:00、SeaweedFS 物理含む完全バックアップ・数分のダウンタイム）
#   0 3 * * 0 youruser cd ~/work/genai-deploy-onpre && ./scripts/backup.sh full    /var/backups/genai >> /var/log/genai-backup.log 2>&1
#
# 注意:
#   - 出力先（既定 ./backups/）の保持期間管理は cron 呼び出し側で行う（find -mtime -delete 等）。
#   - 出力ファイルは平文の DB ダンプ／tar gz であり、ホスト FS 暗号化（既定）の保護下に置くこと。
#   - secrets/ 配下は本スクリプトの対象外（gen-secrets.sh で再生成可、外部 vault に別管理）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

usage() {
  cat <<EOS
使い方:
  $(basename "$0") logical [出力先ディレクトリ]   業務DB＋認証DB の論理バックアップ
  $(basename "$0") full    [出力先ディレクトリ]   上記＋SeaweedFS 物理バックアップ
既定出力先: $REPO_ROOT/backups
EOS
}

MODE="${1:-}"
case "$MODE" in
  logical|full) ;;
  *) usage; exit 2 ;;
esac

OUT_DIR="${2:-$REPO_ROOT/backups}"
TS="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

COMPOSE_FILES=(-f docker-compose.yml)
[ -f docker-compose.secrets.yml ] && COMPOSE_FILES+=(-f docker-compose.secrets.yml)

dc() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

backup_logical_postgres() {
  local svc="$1" outname="$2"
  local pg_user pg_db
  # container 内 env から DB 接続情報を取得（compose の env と整合）。
  pg_user="$(dc exec -T "$svc" printenv POSTGRES_USER | tr -d '\r\n')"
  pg_db="$(dc exec -T "$svc"   printenv POSTGRES_DB   | tr -d '\r\n')"
  echo "[backup] $svc: pg_dump -F custom -Z 6 (user=$pg_user db=$pg_db) -> $outname"
  # -F custom：pg_restore 並列復元可・圧縮内蔵。-Z 6：圧縮レベル中。
  dc exec -T "$svc" pg_dump -U "$pg_user" -d "$pg_db" -F custom -Z 6 > "$OUT_DIR/$outname"
  chmod 600 "$OUT_DIR/$outname"
}

# SeaweedFS image を tar 用 utility としても流用（追加 OSS ゼロ＝0-14a 整合）。
# entrypoint は weed のため /bin/sh で上書き。digest は compose と同一。
readonly SWFS_IMAGE='chrislusf/seaweedfs:4.22@sha256:84429e5f21fad82246f5cfae7b39e9a17da18afb62f2b79c25ccd364ab02793b'

resolve_seaweedfs_volume() {
  local vol
  # compose project プレフィクス + "_seaweedfs_data" のフルネーム解決。
  vol="$(docker volume ls --filter "name=_seaweedfs_data$" --format '{{.Name}}' | head -n 1)"
  if [ -z "$vol" ]; then
    echo "[backup] エラー: seaweedfs_data volume が見つかりません。" >&2
    return 1
  fi
  echo "$vol"
}

backup_seaweedfs_full() {
  local outname="seaweedfs_${TS}.tar.gz"
  local volume_name
  volume_name="$(resolve_seaweedfs_volume)"
  echo "[backup] seaweedfs: stop -> tar gz -> start (volume=$volume_name)"

  # 途中失敗時も必ずサービスを起動状態に戻す（trap）。
  # shellcheck disable=SC2064
  trap "docker compose ${COMPOSE_FILES[*]} start seaweedfs >/dev/null 2>&1 || true" EXIT
  dc stop seaweedfs

  # tar はコンテナ内 root で実行（/data の read 権限確保）。出力ファイルは
  # docker 内で host UID/GID へ chown + 600 まで済ませる（外で chmod すると
  # root 所有のため Permission denied になる）。
  local host_uid host_gid
  host_uid="$(id -u)"
  host_gid="$(id -g)"
  docker run --rm \
    --entrypoint /bin/sh \
    -v "$volume_name:/data:ro" \
    -v "$OUT_DIR:/backup" \
    "$SWFS_IMAGE" \
    -c "tar czf '/backup/$outname' -C /data . && chown ${host_uid}:${host_gid} '/backup/$outname' && chmod 600 '/backup/$outname'"

  dc start seaweedfs
  trap - EXIT

  echo "[backup] seaweedfs: $outname"
}

echo "[backup] 開始: mode=$MODE out=$OUT_DIR ts=$TS"

case "$MODE" in
  logical)
    backup_logical_postgres postgres    "postgres_${TS}.dump"
    backup_logical_postgres keycloak-db "keycloak_db_${TS}.dump"
    ;;
  full)
    backup_logical_postgres postgres    "postgres_${TS}.dump"
    backup_logical_postgres keycloak-db "keycloak_db_${TS}.dump"
    backup_seaweedfs_full
    ;;
esac

echo "[backup] 完了: mode=$MODE out=$OUT_DIR"
