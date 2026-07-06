#!/usr/bin/env bash
# genai-deploy-onpre — 自己署名 TLS 証明書生成
#
# 生成物（certs/、.gitignore 対象）：
#   ca.crt / ca.key       … 内部 CA（各端末でこの ca.crt を rootCA として信頼登録 → README）
#   nginx.crt / nginx.key … 外部向けサーバ証明書（client→nginx HTTPS、A-外部=Z）
#   api.crt / api.key     … 内部向けサーバ証明書（nginx↔api 内部 TLS、A-内部）
#
# 使い方：
#   ./scripts/gen-certs.sh              … 既存があればスキップ
#   FORCE=1 ./scripts/gen-certs.sh      … 強制再生成
#   HOST_IP=192.168.1.50 ./scripts/gen-certs.sh   … LAN 公開時、外部証明書 SAN に IP 追加
#
# 注（簡略）：鍵は chmod 644。ホスト UID とコンテナ node ユーザ(UID 1000)が異なる環境で
#   api コンテナが鍵を読めるようにするため。ローカル自己署名・再生成可。本番は適切な秘密管理へ。

set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/certs"
DAYS="${CERT_DAYS:-825}"
HOST_IP="${HOST_IP:-}"

mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/ca.crt" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "[gen-certs] 証明書は既に存在します（再生成は FORCE=1）: $CERT_DIR"
  exit 0
fi

echo "[gen-certs] 内部 CA を生成..."
openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$CERT_DIR/ca.key" -sha256 -days "$DAYS" \
  -subj "/CN=genai-local internal CA" -out "$CERT_DIR/ca.crt"

gen_cert() {
  local name="$1" cn="$2" san="$3"
  echo "[gen-certs] サーバ証明書を生成: $name (SAN: $san)"
  openssl genrsa -out "$CERT_DIR/$name.key" 2048 2>/dev/null
  openssl req -new -key "$CERT_DIR/$name.key" -subj "/CN=$cn" -out "$CERT_DIR/$name.csr"
  openssl x509 -req -in "$CERT_DIR/$name.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -days "$DAYS" -sha256 \
    -extfile <(printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$san") \
    -out "$CERT_DIR/$name.crt" 2>/dev/null
  rm -f "$CERT_DIR/$name.csr"
}

# 外部（client→nginx）：localhost / 127.0.0.1 ＋ 任意の LAN IP
NGINX_SAN="DNS:localhost,IP:127.0.0.1"
[ -n "$HOST_IP" ] && NGINX_SAN="$NGINX_SAN,IP:$HOST_IP"
gen_cert "nginx" "localhost" "$NGINX_SAN"

# 内部（nginx→api）：コンテナ名 api で検証
gen_cert "api" "api" "DNS:api,DNS:localhost,IP:127.0.0.1"

rm -f "$CERT_DIR/.srl" "$CERT_DIR/ca.srl" 2>/dev/null || true
chmod 644 "$CERT_DIR"/*.crt "$CERT_DIR"/*.key

echo "[gen-certs] 完了: $CERT_DIR"
echo "[gen-certs] 各端末で $CERT_DIR/ca.crt を rootCA として信頼登録してください（手順は README 参照）。"
