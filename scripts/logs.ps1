# scripts/logs.ps1 — ログ抽出ヘルパースクリプト（PowerShell 版）
#
# Windows 環境向けの構造化 JSON ログ抽出ラッパー。
# bash 版（scripts/logs.sh）と同じサブコマンド体系・同じ出力仕様。
#
# 使い方:
#   .\scripts\logs.ps1 error              # 全サービスから ERROR / FATAL を抽出
#   .\scripts\logs.ps1 req <request_id>   # 1 リクエストの全 hop ログ
#   .\scripts\logs.ps1 llm                # LLM 呼び出し系
#   .\scripts\logs.ps1 db                 # DB クエリ系
#   .\scripts\logs.ps1 tail [service]     # ライブ追尾（Ctrl+C で停止）
#   .\scripts\logs.ps1 since <duration>   # 指定期間のログ
#   .\scripts\logs.ps1 help               # ヘルプ表示
#
# 構造化解析は ConvertFrom-Json を使用（PowerShell 標準・jq 不要）。
# 出力は JSON 1 行（ConvertTo-Json -Compress）または raw 行（非 JSON ログの場合）。

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'

$ComposeCmd  = if ($env:COMPOSE_CMD) { $env:COMPOSE_CMD } else { 'docker compose' }
$DefaultSince = if ($env:DEFAULT_SINCE) { $env:DEFAULT_SINCE } else { '30m' }

function Show-Usage {
    @'
使い方:
  .\scripts\logs.ps1 <サブコマンド> [引数]

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
'@ | Write-Host
}

# docker compose logs の prefix（"api-1  | "）を取り除き、JSON 部分のみ取り出す
# 同時に元のサービス名を保持したい場合は呼び出し側で別途記録
# ConvertFrom-Json は PowerShell 標準のため不在シナリオはない。テスト用に LOGS_FORCE_NO_JSON=1 で
# Json パース失敗扱いし raw 行のみ表示する経路を確認できる（jq fallback と同等の意味づけ）。

function Strip-Prefix {
    param([Parameter(ValueFromPipeline)]$Line)
    process {
        if ($Line -match '^\s*\S+\s*\|\s*(.*)$') {
            $Matches[1]
        } else {
            $Line
        }
    }
}

# JSON 行を ConvertFrom-Json でパース（失敗時は null）
function Try-ParseJson {
    param([Parameter(ValueFromPipeline)]$Line)
    process {
        if ($env:LOGS_FORCE_NO_JSON -eq '1') { return $null }
        try { $Line | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    }
}

function Invoke-ComposeLogs {
    param([string]$Since = $null, [string]$Service = $null, [switch]$Follow)
    $cmdParts = $ComposeCmd -split ' '
    $cmd = $cmdParts[0]
    $cmdArgs = @($cmdParts[1..($cmdParts.Length - 1)]) + @('logs', '--no-color')
    if ($Since) { $cmdArgs += @('--since', $Since) }
    if ($Follow) { $cmdArgs += @('-f', '--tail', '50') }
    if ($Service) { $cmdArgs += $Service }
    & $cmd @cmdArgs 2>&1
}

function Cmd-Error {
    Invoke-ComposeLogs -Since $DefaultSince | ForEach-Object {
        $raw = $_
        $json = $raw | Strip-Prefix | Try-ParseJson
        if ($null -ne $json -and ($json.level -eq 'ERROR' -or $json.level -eq 'FATAL' -or $json.level -eq 50 -or $json.level -eq 60)) {
            $json | ConvertTo-Json -Compress -Depth 10
        }
    }
}

function Cmd-Req {
    if (-not $Args -or -not $Args[0]) {
        Write-Error '[エラー] request_id を指定してください。例: .\scripts\logs.ps1 req r_abc123'
        exit 2
    }
    $rid = $Args[0]
    Invoke-ComposeLogs -Since '1h' | ForEach-Object {
        $raw = $_
        $json = $raw | Strip-Prefix | Try-ParseJson
        if ($null -ne $json) {
            $xrid = $null
            if ($json.res -and $json.res.headers) { $xrid = $json.res.headers.'x-request-id' }
            if ($json.request_id -eq $rid -or ($json.req -and $json.req.id -eq $rid) -or $xrid -eq $rid) {
                $json | ConvertTo-Json -Compress -Depth 10
            }
        } elseif ($raw -match [regex]::Escape($rid)) {
            # 非 JSON 行に request_id 文字列が含まれていれば素通し
            $raw
        }
    }
}

function Cmd-Llm {
    Invoke-ComposeLogs -Since $DefaultSince | ForEach-Object {
        $json = $_ | Strip-Prefix | Try-ParseJson
        if ($null -ne $json) {
            $comp = if ($json.component) { $json.component } else { '' }
            $evt  = if ($json.event)     { $json.event }     else { '' }
            if ($comp.StartsWith('api.llm') -or $evt.StartsWith('llm_call_')) {
                $json | ConvertTo-Json -Compress -Depth 10
            }
        }
    }
}

function Cmd-Db {
    Invoke-ComposeLogs -Since $DefaultSince | ForEach-Object {
        $json = $_ | Strip-Prefix | Try-ParseJson
        if ($null -ne $json) {
            $comp = if ($json.component) { $json.component } else { '' }
            $evt  = if ($json.event)     { $json.event }     else { '' }
            if ($comp -eq 'api.db' -or $evt -eq 'db_query_failed' -or $evt -eq 'db_query_slow') {
                $json | ConvertTo-Json -Compress -Depth 10
            }
        }
    }
}

function Cmd-Tail {
    $svc = if ($Args -and $Args[0]) { $Args[0] } else { $null }
    Invoke-ComposeLogs -Follow -Service $svc
}

function Cmd-Since {
    if (-not $Args -or -not $Args[0]) {
        Write-Error '[エラー] 期間を指定してください。例: .\scripts\logs.ps1 since 5m / 1h / 30s'
        exit 2
    }
    Invoke-ComposeLogs -Since $Args[0]
}

switch ($Command) {
    'error'   { Cmd-Error }
    'req'     { Cmd-Req }
    'llm'     { Cmd-Llm }
    'db'      { Cmd-Db }
    'tail'    { Cmd-Tail }
    'since'   { Cmd-Since }
    'help'    { Show-Usage }
    '-h'      { Show-Usage }
    '--help'  { Show-Usage }
    default   {
        Write-Error "[エラー] 未知のサブコマンド: $Command"
        Show-Usage
        exit 2
    }
}
