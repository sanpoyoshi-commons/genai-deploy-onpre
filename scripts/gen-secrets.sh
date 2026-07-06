#!/usr/bin/env bash
# genai-deploy-onpre — docker secrets 用の秘密値ファイル生成＋テンプレ展開
#
# 生成物（すべて secrets/ 配下＝.gitignore の `secrets/*` ルールで管理外）：
#   postgres_password                       … 業務 DB の postgres スーパーユーザパスワード
#   keycloak_db_password                    … Keycloak 専用 DB のパスワード
#   keycloak_admin_password                 … Keycloak ブートストラップ管理者パスワード（master realm・IdP 管理）
#   keycloak_admin_user_password            … genai-realm 初回 SystemAdmin（人間 admin）の初期パスワード
#   keycloak_admin_client_secret            … api/worker のサービスアカウント client secret（Admin REST 用）
#   s3_secret_access_key                    … SeaweedFS S3 のシークレットキー（api/worker 用）
#   dozzle_admin_password                   … Dozzle simple 認証 admin の初期パスワード
#   s3.config.json                          … SeaweedFS が読む S3 認証設定の実体（テンプレから生成）
#   keycloak-import/genai-realm-realm.json  … Keycloak の realm import 実体（テンプレから生成）
#
# secrets/ 外の生成物：
#   dozzle/users.yml                        … Dozzle simple 認証のユーザー定義（.gitignore 対象・dozzle generate で生成）
#
# テンプレ展開（恒久対策）：
#   旧設計は SeaweedFS／Keycloak の管理下設定ファイルを sed で書き換える方式で、実行後そのまま
#   commit すると秘密値が history に永続化する重大リスクが露呈した。恒久対策として、git 管理下にはテンプレ
#   （@@...@@ placeholder 入り）のみを置き、本スクリプトでテンプレ → 実体（secrets/ 配下＝.gitignore 対象）
#   を sed で生成する：
#     - seaweedfs/s3.config.template.json            → secrets/s3.config.json（@@S3_SECRET_KEY@@ を置換）
#     - keycloak/import/genai-realm-realm.template.json → secrets/keycloak-import/genai-realm-realm.json
#       （@@KEYCLOAK_ADMIN_CLIENT_SECRET@@ と @@ADMIN_PASSWORD@@ を置換）
#   docker-compose は secrets/ 配下の実体を mount する（既存パスから変更済み）。
#   Keycloak realm は --import-realm で初回のみ取り込むため、変更反映には realm 再インポート、または
#   Keycloak Admin Console で client secret を別途更新すること（fresh deploy なら一発で完結）。
#
# 使い方：
#   ./scripts/gen-secrets.sh            … 既存があればスキップ（冪等）。テンプレ展開は毎回実行（実体を最新化）。
#   FORCE=1 ./scripts/gen-secrets.sh    … 強制再生成（DB 初期化済みの場合は要注意）
#
# 生成後、セキュリティハードニング起動：
#   docker compose -f docker-compose.yml -f docker-compose.secrets.yml up -d
#
# 注：本スクリプトは秘密値ファイルを生成するため手動で実行する。
#   生成済みパスワードは控えておくこと。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$REPO_ROOT/secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# 強い乱数パスワード（英数記号なし=取り回し優先＋sed 置換で特殊文字を含まない、32 バイト base64 相当）
gen_pw() {
  # openssl 優先、無ければ /dev/urandom
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '\n/+=' | cut -c1-32
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
  fi
}

# genai-realm 初回 SystemAdmin の初期パスワード生成。
# realm の password ポリシ（length(8) and upperCase(1) and digits(1) and specialChars(1)）を機械的に満たし、
# かつ sed 置換（s|@@..@@|値|）と JSON 文字列の双方で安全な文字のみで構成する。gen_pw（英数 32 字）に
# 大文字 'A'・数字 '7'・安全な記号 1 字を付与して各クラスを保証する（& \ / | " は記号集合から除外）。
gen_admin_pw() {
  local base spec
  base="$(gen_pw || true)"
  spec="$(LC_ALL=C tr -dc '!@#%^*_=+.-' < /dev/urandom 2>/dev/null | head -c 1 || true)"
  [ -n "$spec" ] || spec='!'
  printf '%s' "${base}A7${spec}"
}

write_secret() {
  local name="$1"
  # 生成器を差し替え可能に（既定は英数 gen_pw、ポリシ要件があるものは gen_admin_pw 等を指定）。
  local gen="${2:-gen_pw}"
  local path="$SECRETS_DIR/$name"
  if [ -f "$path" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "[gen-secrets] 既存のためスキップ（再生成は FORCE=1）: $name"
    return 0
  fi
  # 末尾改行を付けない（_FILE 読込時に改行混入を避ける）
  printf '%s' "$("$gen")" > "$path"
  # mode 644：file ベース docker secret は source の権限のまま bind マウントされる。
  # Keycloak は非 root（uid 1000）でラッパが secret を読むため、所有者限定 600 では
  # ホスト uid ≠ 1000 のとき Permission denied になる（実機検証で確認）。
  # ディレクトリ 700 でホスト側アクセスを制限しているため、ファイル 644 でも安全。
  chmod 644 "$path"
  echo "[gen-secrets] 生成: $name"
}

# 恒久対策：テンプレ → 実体（secrets/ 配下）を sed で生成（管理下ファイルを書き換えない）。
# gen_pw は英数のみのため sed 置換文字列として安全（/ & \ を含まない）。
# placeholder @@...@@ は shell/Keycloak/JSON のいずれの構文とも衝突しない形式（${...} 系は避ける）。
render_secret_configs() {
  local s3_tpl="$REPO_ROOT/seaweedfs/s3.config.template.json"
  local s3_out="$SECRETS_DIR/s3.config.json"
  local kc_tpl="$REPO_ROOT/keycloak/import/genai-realm-realm.template.json"
  local kc_dir="$SECRETS_DIR/keycloak-import"
  local kc_out="$kc_dir/genai-realm-realm.json"
  local s3_secret kc_secret kc_admin_pw cnt
  s3_secret="$(cat "$SECRETS_DIR/s3_secret_access_key")"
  kc_secret="$(cat "$SECRETS_DIR/keycloak_admin_client_secret")"
  kc_admin_pw="$(cat "$SECRETS_DIR/keycloak_admin_user_password")"

  # SeaweedFS s3.config.json：テンプレから実体生成。SeaweedFS は -s3.config 引数で実体を直読み（env 補間なし）。
  if [ ! -f "$s3_tpl" ]; then
    echo "[gen-secrets] エラー: テンプレ不在 $s3_tpl" >&2
    return 1
  fi
  sed "s|@@S3_SECRET_KEY@@|${s3_secret}|g" "$s3_tpl" > "$s3_out"
  chmod 644 "$s3_out"
  cnt="$(grep -c '@@' "$s3_out" || true)"
  if [ "$cnt" != "0" ]; then
    echo "[gen-secrets] 警告: secrets/s3.config.json に未置換 placeholder が残存（${cnt} 件）" >&2
  fi
  echo "[gen-secrets] 生成: secrets/s3.config.json"

  # Keycloak realm import：テンプレから実体生成。Keycloak 26.x は realm import の env 補間に regression あり
  # （Issue #33578 等）のためテンプレ方式で安全側に倒す。実体は --import-realm で初回のみ取込。
  mkdir -p "$kc_dir"
  if [ ! -f "$kc_tpl" ]; then
    echo "[gen-secrets] エラー: テンプレ不在 $kc_tpl" >&2
    return 1
  fi
  # client secret（service-account）と初回 SystemAdmin の初期パスワードを 1 パスで置換。
  # 双方とも sed 安全（& \ / | を含まない）・JSON 安全（" \ を含まない）な生成器の出力。
  sed -e "s|@@KEYCLOAK_ADMIN_CLIENT_SECRET@@|${kc_secret}|g" \
      -e "s|@@ADMIN_PASSWORD@@|${kc_admin_pw}|g" "$kc_tpl" > "$kc_out"
  chmod 644 "$kc_out"
  cnt="$(grep -c '@@' "$kc_out" || true)"
  if [ "$cnt" != "0" ]; then
    echo "[gen-secrets] 警告: secrets/keycloak-import/genai-realm-realm.json に未置換 placeholder が残存（${cnt} 件）" >&2
  fi
  echo "[gen-secrets] 生成: secrets/keycloak-import/genai-realm-realm.json"

  echo "[gen-secrets] 注意: 既に realm をインポート済みの場合、変更反映には realm 再インポートまたは Admin Console での更新が必要。"
}

# .env 方式（README 既定）のための自動整合（案1）。
# なぜ必要か：.env 方式では api/worker は compose fallback（dev 既定値）または .env の値を読む。一方
# gen-secrets.sh は client secret / S3 secret のランダム生成値を「レンダリング実体」に焼き込む
#   - secrets/keycloak-import/genai-realm-realm.json … Keycloak realm import（Admin REST の client secret）
#   - secrets/s3.config.json                          … SeaweedFS S3 認証（S3 署名キー）
# 両者が食い違うと Keycloak Admin REST 401（チーム作成 500）・S3 署名不一致が起きる（新環境で実証）。
# そこで .env が存在する場合に該当 2 変数を生成値へ自動整合し、レンダリング実体と揃える。
# secrets オーバーレイ運用ではこの 2 値は /run/secrets から読まれ .env 側は未使用のため、整合しても無害。
# 生成値は英数のみ（gen_pw 仕様）で sed 置換に安全。秘密値は stdout に出さない。冪等（再実行しても常に整合）。
DEV_DEFAULT_KC_SECRET="genai-admin-dev-secret-change-me"
DEV_DEFAULT_S3_SECRET="genai-s3-dev-secret-change-me"

align_env_var() {
  # $1=変数名 $2=生成値（secret ファイルの中身） $3=dev 既定値
  local var="$1" gen="$2" dev_default="$3"
  local env_file="$REPO_ROOT/.env"

  # アクティブ行（先頭が VAR= の非コメント行）。コメント行（# 始まり）は含めない。
  local active
  active="$(grep -E "^[[:space:]]*${var}=" "$env_file" || true)"

  if [ -z "$active" ]; then
    # 行なし or コメントアウトのみ → 生成値で末尾追記
    printf '%s=%s\n' "$var" "$gen" >> "$env_file"
    echo "[gen-secrets] .env: ${var} を生成値に設定（追記）"
    return 0
  fi

  # アクティブ行（複数あれば compose が採用する最後の行）の値部分
  local cur_val
  cur_val="$(printf '%s\n' "$active" | tail -n1 | sed -E "s/^[[:space:]]*${var}=//")"

  if [ "$cur_val" = "$gen" ]; then
    echo "[gen-secrets] .env: ${var} は既に生成値と一致（変更なし）"
    return 0
  fi

  if [ -z "$cur_val" ] || [ "$cur_val" = "$dev_default" ]; then
    # 空 or dev 既定値 → 生成値へ置換（アクティブ行のみ・行頭インデントは保持）
    sed -i -E "s|^([[:space:]]*)${var}=.*|\1${var}=${gen}|" "$env_file"
    echo "[gen-secrets] .env: ${var} を生成値に更新"
    return 0
  fi

  # それ以外の独自値 → 変更せず警告（値は表示しない）
  echo "[gen-secrets] 警告: .env の ${var} は独自値のため変更しません。レンダリング実体（secrets/ 配下）と一致しているか確認してください。" >&2
}

align_env_with_secrets() {
  local env_file="$REPO_ROOT/.env"
  # .env 不在（secrets オーバーレイ専用運用や未初期化）は無言でスキップ
  [ -f "$env_file" ] || return 0
  align_env_var "KEYCLOAK_ADMIN_CLIENT_SECRET" "$(cat "$SECRETS_DIR/keycloak_admin_client_secret")" "$DEV_DEFAULT_KC_SECRET"
  align_env_var "S3_SECRET_ACCESS_KEY"          "$(cat "$SECRETS_DIR/s3_secret_access_key")"          "$DEV_DEFAULT_S3_SECRET"
}

# Dozzle simple 認証のユーザー定義 dozzle/users.yml を生成（secrets/ 外・.gitignore 対象）。
# compose が ./dozzle/users.yml:/data/users.yml:ro でマウントするため、未生成のまま up すると
# Docker がマウント先を空ディレクトリとして自動生成し、Dozzle が "users.yml: is a directory" で
# crash-loop する。これを防ぐため先に実体ファイルを作る。bcrypt 化は dozzle イメージの generate に委譲。
# イメージは docker-compose.yml の dozzle と同一 digest に固定する。
DOZZLE_IMAGE="amir20/dozzle:v10.5.3@sha256:1cc972250626553009ddacbdf1f5725b681cdcbabe551fec69cd728882ffbc58"
render_dozzle_users() {
  local out="$REPO_ROOT/dozzle/users.yml"
  local user="admin"
  local pw tmp
  # マウント footgun で出来た空ディレクトリがあれば除去してファイルに作り直す
  if [ -d "$out" ]; then
    echo "[gen-secrets] dozzle/users.yml がディレクトリ化していたため削除して作り直します"
    rmdir "$out" 2>/dev/null || rm -rf "$out"
  fi
  if [ -f "$out" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "[gen-secrets] 既存のためスキップ（再生成は FORCE=1）: dozzle/users.yml"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "[gen-secrets] 警告: docker 不在のため dozzle/users.yml を生成できません。docker 導入後に再実行してください。" >&2
    return 0
  fi
  pw="$(cat "$SECRETS_DIR/dozzle_admin_password")"
  mkdir -p "$REPO_ROOT/dozzle"
  tmp="$(mktemp)"
  if docker run --rm "$DOZZLE_IMAGE" generate "$user" --password "$pw" --name "$user" > "$tmp"; then
    mv "$tmp" "$out"
    chmod 644 "$out"
    echo "[gen-secrets] 生成: dozzle/users.yml（ユーザー $user / パスワードは secrets/dozzle_admin_password）"
  else
    rm -f "$tmp"
    echo "[gen-secrets] エラー: dozzle/users.yml の生成に失敗（dozzle イメージ取得失敗等）。手動生成可：" >&2
    echo "[gen-secrets]   docker run --rm $DOZZLE_IMAGE generate $user --password <pw> --name $user > dozzle/users.yml" >&2
    return 1
  fi
}

write_secret "postgres_password"
write_secret "keycloak_db_password"
write_secret "keycloak_admin_password"
write_secret "keycloak_admin_client_secret"
# 初回 SystemAdmin の初期パスワードはポリシ充足生成器で（記号必須）。
write_secret "keycloak_admin_user_password" gen_admin_pw
write_secret "s3_secret_access_key"
write_secret "dozzle_admin_password"

# テンプレ → 実体（secrets/ 配下）を生成。管理下ファイルは書き換えない（恒久対策）。
render_secret_configs
# .env 方式のとき、client secret / S3 secret を生成値へ整合（レンダリング実体と揃える。案1）。
align_env_with_secrets
# Dozzle simple 認証のユーザー定義（dozzle/users.yml）を生成（マウント footgun 回避）。
render_dozzle_users

# テンプレート（.example）も配置（中身はダミー）。.gitignore 対象＝commit せず、本スクリプトが生成する
# ローカル参照（必要な機密名の一覧。.example は静的 commit せず script 生成に一本化）。
for n in postgres_password keycloak_db_password keycloak_admin_password keycloak_admin_user_password keycloak_admin_client_secret s3_secret_access_key dozzle_admin_password; do
  ex="$SECRETS_DIR/$n.example"
  [ -f "$ex" ] || printf '%s' "replace-with-a-strong-secret" > "$ex"
done

echo "[gen-secrets] 完了: $SECRETS_DIR"
echo "[gen-secrets] 起動: docker compose -f docker-compose.yml -f docker-compose.secrets.yml up -d"
