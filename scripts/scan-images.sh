#!/usr/bin/env bash
# genai-deploy-onpre — コンテナ image の脆弱性リリースゲート（trivy image）。
#
# 既存の pre-push フック（.pre-commit-config.yaml）の trivy は **fs モード**（ソース/
# Dockerfile/lockfile）のみで、pull/build される image の OS パッケージ層 CVE は走査しない。
# 本スクリプトはその穴を埋める **image モード**の棚卸しゲート。per-push は重いのでフックには
# 入れず、**公開スナップショット前のリリースゲート＋定期再 pin** として手動/CI で走らせる。
#
# 判定：CRITICAL を1件でも検出したら exit 1（.trivyignore に記録済みのものは除外）。
#       HIGH は情報表示のみ（非ブロック）。上流 image の no-fix/未再ビルドが大半のため。
#
# 使い方（deploy リポジトリ直下）：
#   ./scripts/scan-images.sh            # compose の image + 各 Dockerfile の base を走査
#
# 前提：docker（trivy 公式 image をコンテナ実行）。.trivyignore を ignorefile として適用。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TRIVY_IMAGE="aquasec/trivy:latest"
CACHE_VOL="trivy-cache"

# 走査対象 = compose の `image: ...@sha256:...` 群 ＋ 各 Dockerfile の base（ARG ...=...@sha256:...）。
mapfile -t IMAGES < <(
  { grep -hoE 'image: [^ ]+@sha256:[0-9a-f]+' docker-compose.yml 2>/dev/null | sed 's/^image: //'
    grep -rhoE '[A-Za-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]+' \
      postgres/Dockerfile sandbox/Dockerfile sdcpp/Dockerfile 2>/dev/null
  } | sort -u
)

echo "[scan-images] 対象 ${#IMAGES[@]} image を trivy image で走査（CRITICAL=ブロック / HIGH=情報）"
trivy() {
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$CACHE_VOL":/root/.cache/trivy \
    -v "$REPO_ROOT":/src \
    "$TRIVY_IMAGE" "$@"
}

fail=0
for img in "${IMAGES[@]}"; do
  echo "----- $img"
  # HIGH 情報表示（非ブロック）
  trivy image --severity HIGH,CRITICAL --quiet --no-progress --scanners vuln \
    --ignorefile /src/.trivyignore "$img" 2>/dev/null \
    | grep -oE 'Total: [0-9]+ \(HIGH: [0-9]+, CRITICAL: [0-9]+\)' | sed 's/^/  /' || echo "  (記録除外後 0 件)"
  # CRITICAL ブロック判定（.trivyignore 適用後に残れば exit 1）
  if ! trivy image --severity CRITICAL --exit-code 1 --quiet --no-progress --scanners vuln \
        --ignorefile /src/.trivyignore "$img" >/dev/null 2>&1; then
    echo "  ❌ 未記録の CRITICAL が残存（.trivyignore に到達性根拠付きで記録するか、現行パッチへ再 pin すること）"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "[scan-images] FAIL: 未記録の CRITICAL あり。公開スナップショット前に解消/記録すること。"
  exit 1
fi
echo "[scan-images] OK: CRITICAL は 0 件（または .trivyignore 記録済みのみ）。"
