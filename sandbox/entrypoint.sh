#!/bin/sh
# サンドボックス起動: 作業ルート（tmpfs 上）を用意して HTTP wrapper を exec する。
# matplotlib のフォントキャッシュはビルド時に /opt/sandbox/mpl へ焼き込み済（read-only・per-run 再構築回避）。
#
# 起動時リスク ack ゲート（受容判断 2026-06-03・docs/sandbox-acceptance-decision.md §7）:
#   Code Interpreter は任意コードを実行する。本サービスを実際に立てる開発者へ「改めて警告」するため、
#   SANDBOX_ACCEPT_RISK が未設定なら posture 要約バナーを出して起動を中止する（opt-in の二段確認）。
#   設定済みなら警告バナーのみ出して続行する。profile sandbox は既定 up 外＝既定構成には一切影響しない。
set -eu

print_banner() {
  printf '%s\n' \
    '============================================================' \
    '⚠ Code Interpreter は任意コードを実行します' \
    '  posture: 外側 seccomp なし + 限定 cap（多層防御で補償）' \
    '  localhost / opt-in / 無保証 前提。本番業務向けではありません。' \
    '  詳細・受容判断: docs/sandbox-acceptance-decision.md' \
    '============================================================' 1>&2
}

case "${SANDBOX_ACCEPT_RISK:-}" in
  1 | true | TRUE | yes | YES)
    print_banner
    printf '%s\n' '  → SANDBOX_ACCEPT_RISK 受容済み。続行します。' 1>&2
    ;;
  *)
    print_banner
    printf '%s\n' \
      '  続行するには SANDBOX_ACCEPT_RISK=1 を設定してください。' \
      '  (未設定のため起動を中止しました)' 1>&2
    exit 78  # EX_CONFIG: 設定不備による意図的な起動中止
    ;;
esac

mkdir -p "${SANDBOX_WORK_ROOT:-/tmp/work}"
exec python3 /opt/sandbox/server.py
