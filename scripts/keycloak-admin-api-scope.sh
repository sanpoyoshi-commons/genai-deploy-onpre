#!/usr/bin/env bash
# genai-deploy-onpre — Keycloak 26.8.2 以降：api の Admin REST 用クライアントに kc-admin-api を付ける
#
# Keycloak 26.8.2 から、Admin REST API は、トークンに scope「kc-admin-api」（と、その scope が付ける
# Admin API の audience）が無いと 401 を返す（CVE-2026-19688 の修正）。上げたときに Keycloak がこの
# scope を自動で付けるのは admin-cli と security-admin-console だけで、api が使う genai-ai-api-admin
# には付かない。付けないと、api の Admin REST 呼び出し（招待・findUserByEmail・グループの加入と離脱）
# が 401 になる。
#   上流の案内: https://www.keycloak.org/docs/latest/upgrading/#migration-changes
#   （26.8.2 の「Admin REST API now enforces an audience check」）
#
# 新しく import する realm は、realm のテンプレート（keycloak/import/genai-realm-realm.template.json）で
# genai-ai-api-admin に kc-admin-api を付けてあるので、本スクリプトは要らない。
# 次のときに 1 回流す。何度流しても結果は同じ（付いていれば何もしない）。
#   - 26.8.2 より前から使っている環境で、Keycloak を 26.8.2 以降へ上げた後
#   - 26.8.2 より前に取った keycloak-db のバックアップを戻した後
#
# 使い方:
#   docker compose up -d                      # keycloak を 26.8.2 以降で起動
#   ./scripts/keycloak-admin-api-scope.sh     # keycloak が healthy になるのを待ってから付ける
#
# 一時の master admin を kc.sh bootstrap-admin で発行して使い、最後に削除する
# （scripts/dr-keycloak-reconcile.sh と同じやり方。bootstrap admin のパスワードには依らない）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_FILES=(-f docker-compose.yml)
[ -f docker-compose.secrets.yml ] && COMPOSE_FILES+=(-f docker-compose.secrets.yml)
dc() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

WAIT_SECONDS="${WAIT_SECONDS:-900}"

KC_CONTAINER="$(dc ps -q keycloak)"
[ -n "$KC_CONTAINER" ] || { echo "[admin-api-scope] エラー: keycloak が動いていない（先に docker compose up -d）" >&2; exit 1; }
echo "[admin-api-scope] keycloak が healthy になるのを待つ（最大 ${WAIT_SECONDS} 秒）"
STATE=""
for _ in $(seq 1 $(( WAIT_SECONDS / 5 ))); do
  STATE="$(docker inspect -f '{{.State.Health.Status}}' "$KC_CONTAINER" 2>/dev/null || true)"
  [ "$STATE" = healthy ] && break
  sleep 5
done
[ "$STATE" = healthy ] || { echo "[admin-api-scope] エラー: keycloak が healthy にならない（状態: ${STATE:-不明}）" >&2; exit 1; }

# 一時 master admin の使い捨て資格情報（本スクリプト内のみ・永続しない）。
TS="$(date +%s)"
TMPUSER="admin-api-scope-${TS}"
TMPPW="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)Aa1#"

echo "[admin-api-scope] 一時 master admin を発行: $TMPUSER（処理の後に削除）"
# 起動中 keycloak と同一コンテナ内では management port 9000 が衝突するため、別ワンオフコンテナで実行。
# KC_BOOTSTRAP_ADMIN_* はラッパ/overlay 由来の干渉を避けて unset する。secrets オーバーレイのときだけ
# KC_DB_PASSWORD を /run/secrets から注入する（.env 方式では環境変数の値をそのまま使う）。
dc run --rm --no-deps --entrypoint bash \
  -e TMPUSER="$TMPUSER" -e TMPPW="$TMPPW" \
  keycloak -c '
    unset KC_BOOTSTRAP_ADMIN_USERNAME KC_BOOTSTRAP_ADMIN_PASSWORD
    if [ -f /run/secrets/keycloak_db_password ]; then
      export KC_DB_PASSWORD="$(< /run/secrets/keycloak_db_password)"
    fi
    exec /opt/keycloak/bin/kc.sh bootstrap-admin user --username "$TMPUSER" --password:env TMPPW --no-prompt
  ' >/dev/null

echo "[admin-api-scope] genai-ai-api-admin の default client scope に kc-admin-api を付ける"
dc exec -T -e TMPUSER="$TMPUSER" -e TMPPW="$TMPPW" keycloak bash -c '
  set -eu
  KC=/opt/keycloak/bin/kcadm.sh
  CFG=/tmp/kcadm-admin-api-scope.config
  R=genai-realm
  "$KC" config credentials --config "$CFG" --server http://localhost:8080 --realm master --user "$TMPUSER" --password "$TMPPW" >/dev/null
  cleanup() {
    RID="$("$KC" get users --config "$CFG" -r master -q username="$TMPUSER" --fields id --format csv --noquotes 2>/dev/null | tr -d "\r" | tail -n1 || true)"
    if [ -n "$RID" ]; then "$KC" delete "users/$RID" --config "$CFG" -r master && echo "  [cleanup] 一時 admin を削除"; fi
    rm -f "$CFG"
  }
  trap cleanup EXIT
  has() {  # has <一覧の path> <名前>：その一覧に名前があれば 0
    local n
    while IFS= read -r n; do [ "$n" = "$2" ] && return 0; done < <("$KC" get "$1" --config "$CFG" -r "$R" --fields name --format csv --noquotes | tr -d "\r")
    return 1
  }
  CID="$("$KC" get clients --config "$CFG" -r "$R" -q clientId=genai-ai-api-admin --fields id --format csv --noquotes | tr -d "\r" | tail -n1)"
  [ -n "$CID" ] || { echo "  エラー: genai-ai-api-admin が見つからない" >&2; exit 1; }
  SID=""
  while IFS=, read -r id name; do [ "$name" = kc-admin-api ] && SID="$id"; done < <("$KC" get client-scopes --config "$CFG" -r "$R" --fields id,name --format csv --noquotes | tr -d "\r")
  [ -n "$SID" ] || { echo "  エラー: kc-admin-api の client scope が無い（Keycloak が 26.8.2 より前？）" >&2; exit 1; }
  if has "clients/$CID/default-client-scopes" kc-admin-api; then
    echo "  [ok] 既に付いている（何もしない）"
    exit 0
  fi
  if has "clients/$CID/optional-client-scopes" kc-admin-api; then
    "$KC" delete "clients/$CID/optional-client-scopes/$SID" --config "$CFG" -r "$R"
  fi
  "$KC" update "clients/$CID/default-client-scopes/$SID" --config "$CFG" -r "$R"
  has "clients/$CID/default-client-scopes" kc-admin-api || { echo "  エラー: 付けられなかった" >&2; exit 1; }
  echo "  [fix] genai-ai-api-admin に kc-admin-api を付けた（default）"
'
echo "[admin-api-scope] 完了。api は 401 を受けるとトークンを取り直すので、api の再起動は要らない。"
