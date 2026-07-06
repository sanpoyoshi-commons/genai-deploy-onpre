#!/usr/bin/env bash
# genai-deploy-onpre — 災害復旧フォールバック: Keycloak 資格情報の整合
#
# ⚠ 位置づけ（重要・先に読むこと）:
#   災害復旧の【正手順】は「secrets/ を外部 vault から復元」すること（整合作業ゼロ）。
#   docs/backup-restore.md §4 / デプロイ手順書 §5 のとおり secrets/ は外部 vault で別管理する。
#   復元元 backup と同じ secrets/ で起動すれば全資格情報が一致し、本スクリプトは不要。
#
#   本スクリプトは「vault バックアップも失い、gen-secrets.sh で新 secrets を再生成した」
#   二重障害時のフォールバック専用。新環境（別 secrets）で ./scripts/restore.sh full の後に実行する。
#
# なぜ Keycloak だけ整合が要るか（災害復旧の実機検証で確定）:
#   backup の keycloak_db を復元すると、realm import で投入されたはずの
#     - genai-ai-api-admin client secret（api→Keycloak Admin REST 用）
#     - genai-realm seed admin（username=admin）の password
#   が backup 時の値で上書きされる。一方 api は新 secrets（/run/secrets）を使うため client_credentials が
#   401 になり、seed admin も新パスワードで login 不可。さらに master realm の bootstrap admin も
#   backup 時 PW のため Admin Console / kcadm に入れない（鶏卵）。本スクリプトは kc.sh bootstrap-admin で
#   一時 master admin を発行してこれを解き、上記 2 値を新 secrets へ整合し、最後に一時 admin を削除する。
#
#   PostgreSQL（postgres_password / keycloak_db_password）と SeaweedFS（s3_secret_access_key）は
#   【整合不要】。単一 DB dump はロール（pg_authid の PW）を含まず新環境 initdb の新 PW と整合し、
#   SeaweedFS バケットはアクセス creds 非依存・暗号鍵は復元 filer メタ由来で新 s3 creds でも復号できる。
#
# 使い方:
#   ./scripts/restore.sh full <postgres.dump> <keycloak_db.dump> <seaweedfs.tar.gz>
#   ./scripts/dr-keycloak-reconcile.sh
#   # 確認: web にログインし主要機能（チャット・アップロード等）が動作すること

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_FILES=(-f docker-compose.yml)
[ -f docker-compose.secrets.yml ] && COMPOSE_FILES+=(-f docker-compose.secrets.yml)
dc() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

CSEC_FILE="secrets/keycloak_admin_client_secret"
APW_FILE="secrets/keycloak_admin_user_password"
[ -f "$CSEC_FILE" ] || { echo "[dr-reconcile] エラー: $CSEC_FILE が無い（gen-secrets.sh 未実行？）" >&2; exit 1; }
[ -f "$APW_FILE" ]  || { echo "[dr-reconcile] エラー: $APW_FILE が無い（gen-secrets.sh 未実行？）" >&2; exit 1; }

NEW_CSEC="$(cat "$CSEC_FILE")"
NEW_APW="$(cat "$APW_FILE")"

# 一時 master admin の使い捨て資格情報（本スクリプト内のみ・永続しない）。
TS="$(date +%s)"
RECUSER="dr-recovery-${TS}"
# 記号/数字を含む十分長い使い捨てパスワード（realm ポリシ非依存＝master realm）。
RECPW="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)Aa1#"

echo "[dr-reconcile] 一時 master admin を発行: $RECUSER（使い捨て・処理後に削除）"
# 起動中 keycloak と同一コンテナ内では management port 9000 が衝突するため、別ワンオフコンテナで実行。
# KC_BOOTSTRAP_ADMIN_* はラッパ/overlay 由来の干渉を避けて unset し、KC_DB_PASSWORD のみ /run/secrets から注入。
dc run --rm --no-deps --entrypoint bash \
  -e RECUSER="$RECUSER" -e RECPW="$RECPW" \
  keycloak -c '
    unset KC_BOOTSTRAP_ADMIN_USERNAME KC_BOOTSTRAP_ADMIN_PASSWORD
    export KC_DB_PASSWORD="$(< /run/secrets/keycloak_db_password)"
    exec /opt/keycloak/bin/kc.sh bootstrap-admin user --username "$RECUSER" --password:env RECPW --no-prompt
  ' >/dev/null

echo "[dr-reconcile] kcadm で client_secret 更新 / seed admin PW reset / 一時 admin 削除"
dc exec -T \
  -e RECUSER="$RECUSER" -e RECPW="$RECPW" -e NEW_CSEC="$NEW_CSEC" -e NEW_APW="$NEW_APW" \
  keycloak bash -c '
    set -e
    KC=/opt/keycloak/bin/kcadm.sh
    "$KC" config credentials --server http://localhost:8080 --realm master --user "$RECUSER" --password "$RECPW" >/dev/null
    CID="$("$KC" get clients -r genai-realm -q clientId=genai-ai-api-admin --fields id --format csv --noquotes | tr -d "\r" | tail -n1)"
    [ -n "$CID" ] || { echo "  エラー: genai-ai-api-admin client が見つからない" >&2; exit 1; }
    "$KC" update "clients/$CID" -r genai-realm -s secret="$NEW_CSEC"
    echo "  [fix] genai-ai-api-admin client_secret 更新 OK (id=$CID)"
    "$KC" set-password -r genai-realm --username admin --new-password "$NEW_APW"
    echo "  [fix] genai-realm seed admin(admin) PW reset OK"
    RID="$("$KC" get users -r master -q username="$RECUSER" --fields id --format csv --noquotes | tr -d "\r" | tail -n1)"
    if [ -n "$RID" ]; then "$KC" delete "users/$RID" -r master; echo "  [cleanup] 一時 admin 削除 OK"; fi
  '

echo ""
echo "[dr-reconcile] 完了。整合確認:"
echo "  web にログインし主要機能（チャット・アップロード等）が動作することを確認"
echo "  （チャットで Keycloak client_secret 整合・アップロードで S3 健全を確認）"
echo "[dr-reconcile] 注意: master realm の bootstrap admin は依然 backup 時 PW です。"
echo "  Admin Console での管理は seed admin(admin/新PW) か、別途 master admin の PW 再設定で行ってください。"
