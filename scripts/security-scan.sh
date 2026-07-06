#!/usr/bin/env bash
#
# security-scan.sh (SAST+SCA 補完)
#
# web/api 2 リポに SAST（semgrep）と SCA（osv-scanner）を実行し、結果を
# security-reports/ に保存する。network が可能なターミナルで手動実行する前提。
#
# 実行方式の優先順位（自動判定）：
#   1. ネイティブ binary（semgrep / osv-scanner が PATH にあれば優先）
#   2. Docker 公式イメージ（binary が無く docker があればこちら。host を汚さない）
# 本プロジェクトは Docker ネイティブのため通常は 2 が使われる。
# ※ semgrep/osv-scanner は配布スタック外の「開発用ツール」なので、
#   タグ＋SHA 固定対象ではない（ローカル検証専用、latest 可）。
#
# 使い方（別ターミナルで）：
#   cd genai-deploy-onpre
#   bash scripts/security-scan.sh
#   # 完了後、表示される SUMMARY を確認してください。
#   # security-reports/*.json / *.log を確認して所見を判定します。
#
# 注意：レポートは security-reports/（.gitignore 済）に出力。commit しない。

set -u
cd "$(dirname "$0")/.." || exit 1
DEPLOY_ROOT="$(pwd)"
DEPLOY_BASE="$(basename "$DEPLOY_ROOT")"
WORK_PARENT="$(cd "$DEPLOY_ROOT/.." && pwd)"   # 例: ~/work（3 リポの親）
OUT="$DEPLOY_ROOT/security-reports"
mkdir -p "$OUT"

# Docker 内から見たレポート出力先（WORK_PARENT を /work にマウントする前提）
OUT_IN_CTR="/work/$DEPLOY_BASE/security-reports"

SEMGREP_IMG="semgrep/semgrep:latest"
OSV_IMG="ghcr.io/google/osv-scanner:latest"

SUMMARY=()
have() { command -v "$1" >/dev/null 2>&1; }

# 走査対象リポ（name:basename）
REPOS=("web:genai-web-onpre" "api:genai-ai-api-onpre")

# ---- 実行モード判定 ----
if have semgrep; then SEMGREP_MODE=native
elif have docker; then SEMGREP_MODE=docker
else SEMGREP_MODE=none; fi

if have osv-scanner; then OSV_MODE=native
elif have docker; then OSV_MODE=docker
else OSV_MODE=none; fi

echo "== modes: semgrep=$SEMGREP_MODE / osv-scanner=$OSV_MODE =="

# ---- SAST: semgrep ----
case "$SEMGREP_MODE" in
  none) SUMMARY+=("MISS semgrep 実行不可 (binary も docker も無し)") ;;
  *)
    for pair in "${REPOS[@]}"; do
      name="${pair%%:*}"; base="${pair#*:}"; dir="$WORK_PARENT/$base"
      [ -d "$dir" ] || { SUMMARY+=("SKIP semgrep $name (dir なし: $dir)"); continue; }
      if [ "$SEMGREP_MODE" = native ]; then
        semgrep scan --config=p/default --metrics=off \
          --exclude node_modules --exclude aws --exclude azure --exclude google-cloud \
          --json -o "$OUT/semgrep-$name.json" "$dir" \
          > "$OUT/semgrep-$name.log" 2>&1
      else
        docker run --rm -v "$WORK_PARENT":/work -w /work "$SEMGREP_IMG" \
          semgrep scan --config=p/default --metrics=off \
          --exclude node_modules --exclude aws --exclude azure --exclude google-cloud \
          --json -o "$OUT_IN_CTR/semgrep-$name.json" "/work/$base" \
          > "$OUT/semgrep-$name.log" 2>&1
      fi
      findings=$(grep -o '"check_id"' "$OUT/semgrep-$name.json" 2>/dev/null | wc -l | tr -d ' ')
      if [ -s "$OUT/semgrep-$name.json" ]; then
        SUMMARY+=("OK   semgrep $name -> semgrep-$name.json (findings: $findings)")
      else
        SUMMARY+=("WARN semgrep $name 出力空 (semgrep-$name.log を確認)")
      fi
    done ;;
esac

# ---- SCA: osv-scanner ----
case "$OSV_MODE" in
  none) SUMMARY+=("MISS osv-scanner 実行不可 (binary も docker も無し)") ;;
  *)
    for pair in "${REPOS[@]}"; do
      name="${pair%%:*}"; base="${pair#*:}"; dir="$WORK_PARENT/$base"
      lock_rel=$(cd "$dir" 2>/dev/null && find . -maxdepth 2 -name package-lock.json -not -path '*/node_modules/*' 2>/dev/null | head -1 | sed 's|^\./||')
      [ -n "$lock_rel" ] || { SUMMARY+=("SKIP osv-scanner $name (package-lock.json なし)"); continue; }
      if [ "$OSV_MODE" = native ]; then
        osv-scanner --lockfile "$dir/$lock_rel" --format json --output "$OUT/osv-$name.json" \
          > "$OUT/osv-$name.log" 2>&1
      else
        docker run --rm -v "$WORK_PARENT":/work "$OSV_IMG" \
          --lockfile "/work/$base/$lock_rel" --format json --output "$OUT_IN_CTR/osv-$name.json" \
          > "$OUT/osv-$name.log" 2>&1
      fi
      vulns=$(grep -o '"id"' "$OUT/osv-$name.json" 2>/dev/null | wc -l | tr -d ' ')
      if [ -s "$OUT/osv-$name.json" ]; then
        SUMMARY+=("OK   osv-scanner $name -> osv-$name.json (id 出現: $vulns ※要中身確認)")
      else
        SUMMARY+=("WARN osv-scanner $name 出力空 (osv-$name.log を確認)")
      fi
    done ;;
esac

echo ""
echo "================ SUMMARY ================"
printf '%s\n' "${SUMMARY[@]}"
echo "レポート出力先: $OUT"
echo "================================================================================"
echo "Docker 初回は image pull に時間がかかります。OK のレポートは内容を確認して判定します。"
