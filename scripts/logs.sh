#!/usr/bin/env bash
# scripts/logs.sh — ログ抽出ヘルパースクリプト（bash 版）
#
# 構造化 JSON ログ抽出ラッパー。Dozzle GUI（http://localhost:9980）と
# 役割分担で併存（GUI＝主・本スクリプト＝従／フォールバック／自動化／SSH 経由）。
#
# 使い方:
#   ./scripts/logs.sh error              # 全サービスから ERROR / FATAL を抽出
#   ./scripts/logs.sh req <request_id>   # 1 リクエストの全 hop ログ
#   ./scripts/logs.sh llm                # LLM 呼び出し系（component=api.llm.* / llm_call_*）
#   ./scripts/logs.sh db                 # DB クエリ系（api.db / db_query_failed / _slow）
#   ./scripts/logs.sh tail [service]     # ライブ追尾（service 未指定で全サービス）
#   ./scripts/logs.sh since <duration>   # docker compose logs --since（例：5m / 1h）
#   ./scripts/logs.sh help               # ヘルプ表示
#
# jq が無い環境でも動作（grep フォールバック）。jq 導入を強く推奨（構造化検索のため）。

set -u

COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"
DEFAULT_SINCE="${DEFAULT_SINCE:-30m}"

# ---- jq 存在チェック ----------------------------------------------------------
# LOGS_FORCE_NO_JQ=1 で jq があっても grep fallback パスを使う（fallback 動作確認用）。

have_jq() {
    [ "${LOGS_FORCE_NO_JQ:-0}" = "1" ] && return 1
    command -v jq >/dev/null 2>&1
}

show_jq_guide() {
    cat <<'EOF' >&2

[警告] jq が見つかりません。構造化 JSON フィルタの代わりに grep でフォールバックします。
       grep は文字列一致検索のため、複合条件（component と event の AND など）が弱くなります。
       jq を導入すると、ログレベル・component・event ごとに正確に絞り込めます。

  Linux (Debian/Ubuntu)  : sudo apt-get install -y jq
  Linux (RHEL/AlmaLinux) : sudo dnf install -y jq
  macOS                  : brew install jq
  Windows (PowerShell)   : winget install jqlang.jq

  権限が無く /usr/local/bin に置けない場合（一般ユーザー領域に配置）:
    mkdir -p ~/bin && \
    curl -L https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64 -o ~/bin/jq && \
    chmod +x ~/bin/jq && \
    export PATH="$HOME/bin:$PATH"

EOF
}

# ---- ヘルプ ------------------------------------------------------------------

usage() {
    cat <<'EOF'
使い方:
  ./scripts/logs.sh <サブコマンド> [引数]

サブコマンド一覧:
  error               全サービスから ERROR / FATAL を抽出（数値 level=50/60 と "ERROR"/"FATAL" 両対応）
  req <request_id>    指定 request_id の全 hop ログ（nginx→web→api→postgres を 1 本に串刺し）
  llm                 LLM 呼び出し系（component=api.llm.*、event=llm_call_*、error.code 表示）
  db                  DB クエリ系（component=api.db、db_query_failed / db_query_slow）
  tail [service]      ライブ追尾出力（service 未指定で全サービス、Ctrl+C で停止）
  since <duration>    指定期間のログ（例: 5m / 1h / 30s、docker compose logs --since 形式）
  help                このヘルプ表示

検索対象期間（error/llm/db）のデフォルト: 直近 30 分（環境変数 DEFAULT_SINCE で上書き可）
compose コマンド既定: docker compose（環境変数 COMPOSE_CMD で差し替え可）

障害切り分け 4 ケース（画面真っ白／LLM 応答なし／アップロード失敗／ログイン失敗）は
README §ログ を参照。
EOF
}

# ---- docker compose logs の prefix 除去（jq に通すための前処理） --------------
# 入力例:  api-1  | {"level":30,"time":...}
# 出力例:  {"level":30,"time":...}
strip_prefix() {
    sed -E 's/^[^|]*\| //'
}

# ---- 各サブコマンド実装 ------------------------------------------------------

cmd_error() {
    if ! have_jq; then
        show_jq_guide
        $COMPOSE_CMD logs --no-color --since "$DEFAULT_SINCE" 2>&1 \
            | grep -E '"level":(50|60)|"level":"(ERROR|FATAL)"'
        return
    fi
    $COMPOSE_CMD logs --no-color --since "$DEFAULT_SINCE" 2>&1 \
        | strip_prefix \
        | jq -rR 'fromjson? | select((.level=="ERROR") or (.level=="FATAL") or (.level==50) or (.level==60))'
}

cmd_req() {
    local rid="${1:-}"
    if [ -z "$rid" ]; then
        echo "[エラー] request_id を指定してください。例: ./scripts/logs.sh req r_abc123" >&2
        exit 2
    fi
    if ! have_jq; then
        show_jq_guide
        $COMPOSE_CMD logs --no-color --since 1h 2>&1 \
            | grep -F "\"request_id\":\"$rid\"" \
            || $COMPOSE_CMD logs --no-color --since 1h 2>&1 | grep -F "$rid"
        return
    fi
    $COMPOSE_CMD logs --no-color --since 1h 2>&1 \
        | strip_prefix \
        | jq -rR --arg rid "$rid" 'fromjson? | select((.request_id==$rid) or (.req.id==$rid) or ((.res.headers // {})["x-request-id"]==$rid))'
}

cmd_llm() {
    if ! have_jq; then
        show_jq_guide
        $COMPOSE_CMD logs --no-color --since "$DEFAULT_SINCE" 2>&1 \
            | grep -E '"component":"api\.llm[^"]*"|"event":"llm_call_'
        return
    fi
    $COMPOSE_CMD logs --no-color --since "$DEFAULT_SINCE" 2>&1 \
        | strip_prefix \
        | jq -rR 'fromjson? | select(((.component // "") | startswith("api.llm")) or ((.event // "") | startswith("llm_call_")))'
}

cmd_db() {
    if ! have_jq; then
        show_jq_guide
        $COMPOSE_CMD logs --no-color --since "$DEFAULT_SINCE" 2>&1 \
            | grep -E '"component":"api\.db"|"event":"db_query_failed"|"event":"db_query_slow"'
        return
    fi
    $COMPOSE_CMD logs --no-color --since "$DEFAULT_SINCE" 2>&1 \
        | strip_prefix \
        | jq -rR 'fromjson? | select(((.component // "")=="api.db") or ((.event // "")=="db_query_failed") or ((.event // "")=="db_query_slow"))'
}

cmd_tail() {
    local svc="${1:-}"
    if [ -n "$svc" ]; then
        exec $COMPOSE_CMD logs -f --tail 50 --no-color "$svc"
    else
        exec $COMPOSE_CMD logs -f --tail 50 --no-color
    fi
}

cmd_since() {
    local dur="${1:-}"
    if [ -z "$dur" ]; then
        echo "[エラー] 期間を指定してください。例: ./scripts/logs.sh since 5m / 1h / 30s" >&2
        exit 2
    fi
    $COMPOSE_CMD logs --no-color --since "$dur"
}

# ---- main ---------------------------------------------------------------------

cmd="${1:-help}"
shift || true

case "$cmd" in
    error)             cmd_error ;;
    req)               cmd_req "$@" ;;
    llm)               cmd_llm ;;
    db)                cmd_db ;;
    tail)              cmd_tail "$@" ;;
    since)             cmd_since "$@" ;;
    help|-h|--help|"") usage ;;
    *)
        echo "[エラー] 未知のサブコマンド: $cmd" >&2
        echo >&2
        usage >&2
        exit 2
        ;;
esac
