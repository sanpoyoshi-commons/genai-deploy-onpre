# Code Interpreter サンドボックス PoC ランブック（手動 e2e）

NsJail サンドボックスの**最小 CAP 集合の確定**・network off / 資源上限 / 日本語チャート生成の検証手順。

> 実 `docker compose up` を伴う検証手順。確定した値（最小 CAP・rlimit・mem_limit 等）は
> `sandbox/nsjail.cfg` と `docker-compose.yml` の sandbox ブロック、および本書「確定値」表へ反映すること。

## 0. 事前

- `docker compose config` がエラーなく通ること（CC 確認済）。
- WSL2 カーネルの user namespace 設定を確認（rootless 化の可否判断）:
  `cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null`（1 なら unprivileged userns 可）。

## 1. ビルド・起動

```bash
docker compose --profile sandbox build sandbox
COMPOSE_PROFILES=sandbox docker compose up -d sandbox
docker compose ps sandbox          # healthy になるか
docker compose logs -f sandbox     # 起動ログ・NsJail エラー確認
```

## 2. healthz 疎通（内部ネットワーク）

```bash
docker run --rm --network genai-deploy-onpre_genai_internal curlimages/curl \
  -s http://sandbox:8080/healthz
# 期待: {"status":"ok"}
```

## 3. 最小 CAP 確定（二分探索）

1. 初期 `cap_add: [SYS_ADMIN]`（現状値）で §4 のチャート生成が成功するか確認。
2. **rootless/userns 化を試行**: `sandbox/nsjail.cfg` を user-namespace モード（`clone_newuser: true` ＋
   uid/gid マッピング）にし、compose の `cap_add` を空（`cap_drop: [ALL]` のみ）にして起動。チャート生成が
   通れば **CAP ゼロ化成功**（最も望ましい）。`unprivileged_userns_clone=0` 等で失敗する場合は次へ。
3. SYS_ADMIN を保持しつつ、Docker 既定 seccomp が NsJail の clone を阻むか確認。阻む場合のみ
   `security_opt: [seccomp:unconfined]`（または用途特化の限定 profile）を付け、理由を脅威モデルへ記載。
4. 動作する**最小集合**を確定し、`docker-compose.yml` の sandbox `cap_add`/`security_opt` と `nsjail.cfg`、
   本書「確定値」へ記録。

## 4. 機能検証

### network off
```bash
# 外部到達を試みるコードを /eval に投げ、全て失敗（例外）することを確認。
docker run --rm --network genai-deploy-onpre_genai_internal curlimages/curl -s \
  -X POST http://sandbox:8080/eval -H 'content-type: application/json' \
  -d '{"code":"import urllib.request as u\ntry:\n u.urlopen(\"http://1.1.1.1\",timeout=2); print(\"REACHED\")\nexcept Exception as e:\n print(\"blocked:\",type(e).__name__)","files":[],"timeout_ms":5000}'
# 期待: stdout に "blocked: ..."（REACHED が出たら NW 遮断失敗＝要修正）
```

### 資源上限
- 無限ループ → `status:"timeout"`。
- メモリ爆発（`x=[0]*10**9` 等）→ `MemoryError`（rlimit_as）で `status:"error"`。
- fork 爆弾 → pids_limit で抑止。
- 巨大ファイル生成 → rlimit_fsize / 出力上限で除外。

### 日本語チャート生成（フォント実証）
```bash
# 実 CSV を base64 化して投げ、日本語ラベルの PNG が artifacts(base64) で返り、文字化けしないことを確認。
CSV=$(printf 'カテゴリ,売上\n電子機器,120\n書籍,80\n' | base64 -w0)
docker run --rm --network genai-deploy-onpre_genai_internal curlimages/curl -s \
  -X POST http://sandbox:8080/eval -H 'content-type: application/json' \
  -d "{\"code\":\"import pandas as pd, matplotlib.pyplot as plt\\ndf=pd.read_csv('data.csv')\\ndf.plot.bar(x='カテゴリ',y='売上'); plt.savefig('chart.png'); print('done')\",\"files\":[{\"name\":\"data.csv\",\"content_b64\":\"$CSV\"}],\"timeout_ms\":60000}"
# 期待: status ok / files に chart.png(base64) / 文字化けなし（base64 を保存し目視）
```

### 4.5 内側 kafel seccomp 検証（外側 unconfined の補償・実装済 2026-06-02）

`sandbox/seccomp.policy`（`nsjail.cfg` の `seccomp_policy_file` で適用）が、子に対して危険 syscall を
`ERRNO(EPERM)` で塞ぐことを実機確認する。**陰性対照**（seccomp 無し）と対比して「EPERM の原因が内側 seccomp で
あること」を確定させる。

判定用 primitive は `unshare(CLONE_NEWUSER)`：CAP 不要で user-namespace を取得でき（nested-userns 系の権限昇格
primitive）、**seccomp 無しでは `ret=0`（成功）、内側 seccomp 適用で `EPERM`** という綺麗な差分が出る。

```bash
# 適用時（本番構成）: /eval に unshare を投げ、EPERM(errno 1) になることを確認
docker run --rm --network genai-deploy-onpre_genai_internal curlimages/curl -s \
  -X POST http://sandbox:8080/eval -H 'content-type: application/json' \
  -d '{"code":"import ctypes,ctypes.util\nlibc=ctypes.CDLL(ctypes.util.find_library(\"c\"),use_errno=True)\nctypes.set_errno(0); r=libc.unshare(0x10000000); print(\"unshare ret\",r,\"errno\",ctypes.get_errno())","files":[],"timeout_ms":10000}'
# 期待: stdout に "unshare ret -1 errno 1"（= EPERM）。同時に §4.3 の日本語チャートが緑のままであること。
```

確認済（2026-06-02・baked イメージ `genai-sandbox-onpre:nsjail-py313` server.py 経由 e2e）:
- 正常系: 日本語チャート PNG 生成（status ok・exit 0・文字化けなし）— **デナリストは pandas/matplotlib を壊さない**。
- ブロック系: `unshare(CLONE_NEWUSER)` → `ret=-1 errno=1`（EPERM）。
- 陰性対照（`seccomp_policy_file` 行を外した cfg）: 同 `unshare` が `ret=0 errno=0`（成功）→ EPERM の原因が内側
  seccomp であることを確定。

> kafel の syscall 識別子はビルドごとに差がある（本ビルドは amd64 `umount2` 不可・`umount` 可）。ポリシー更新時は
> 各候補を 1 つずつ nsjail に食わせ「`Undefined identifier`」が出ないことを確認してから採用する（パーサは最初の
> エラーで停止するため一括投入では検出漏れする）。

## 5. api 経由 e2e（生成 LLM↔サンドボックス一気通貫・要 profile llm＋生成 LLM）

§4 はサンドボックス単体（`/eval` 直叩き）。本節は **api 経由**で「生成 LLM がコード生成 → サンドボックス実行 →
結果整形」までを通す。**実走には profile `llm` の生成 LLMが要る**（モデル pull・ホスト資源が必要）。

### 5.0 前提 env（api コンテナ）

| env | 役割 | 例 |
|---|---|---|
| `SANDBOX_BASE_URL` | サンドボックス委譲先（未設定だと seam 未配線＝500） | `http://sandbox:8080` |
| `CODE_INTERPRETER_MODEL` | 生成 LLM（未設定時 `LLM_DEFAULT_MODEL` にフォールバック） | `mistral:7b`（CPU）/ 上位帯は局所モデル |
| `CODE_INTERPRETER_TIMEOUT_MS` | 実行タイムアウト（既定 60000） | `60000` |
| `CODE_INTERPRETER_MAX_ATTEMPTS` | 生成 LLM↔実行のリトライ上限（既定 3） | `3` |
| `CODE_INTERPRETER_MAX_FILE_BYTES` | 入力合計サイズ上限（既定 25MiB・超過は 400） | `26214400` |

### 5.1 起動

```bash
# 起動時リスク ack（SANDBOX_ACCEPT_RISK）未設定だと sandbox は警告を出して起動を中止する。
# entrypoint.sh / compose を変更しているため sandbox イメージの再ビルドも必須。
docker compose build sandbox
SANDBOX_ACCEPT_RISK=1 COMPOSE_PROFILES=llm,sandbox docker compose \
  -f docker-compose.yml -f docker-compose.secrets.yml up -d   # secrets オーバーレイ必須
docker compose ps                      # api / sandbox / llm が healthy
# 生成 LLMの事前 pull（例: Ollama 構成）。CPU 機は軽量モデル推奨。
docker compose exec llm ollama pull mistral:7b   # 構成に応じて
```

### 5.2 リクエスト契約（本プロジェクト独自 IF）

- ルート: `POST /api/code-interpreter/responses`（`requireAuth`＝Keycloak。Bearer JWT 必須）
- ボディ: `{ "inputs": { "input_text": str, "files": [ { "key": str, "files": [ { "filename": "*.csv|*.xlsx|*.xls", "content": base64 } ] } ] } }`
  - `input_text` 必須。`files` の `key` は上流互換のため受理して破棄。**拡張子は CSV/Excel 限定**（それ以外は 400）。
- 成功応答: `200 { "outputs": <文字列>, "artifacts": [ { "display_name": <文字列>, "content": <base64> } ] }`
  - `outputs` は実行 stdout（生成コードの `print()` 出力。空なら「分析が完了しました。」）の**文字列**。`artifacts` は
    生成 PNG ごとの `{display_name, content(base64)}` 配列（実装ソース `orchestrator.js`/`responses.js` で確認・2026-06-03）。
- エラー: 入力不正 400／サンドボックス到達不可・実行失敗 500（`stderr` は秘匿しログのみ）。

### 5.3 実行（要 JWT）

```bash
TOKEN="<Keycloak で取得した access_token>"
CSV=$(printf 'カテゴリ,売上\n電子機器,120\n書籍,80\n食品,45\n' | base64 -w0)
curl -s -X POST http://localhost:8080/api/code-interpreter/responses \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d "{\"inputs\":{\"input_text\":\"カテゴリ別の売上を棒グラフにして\",\"files\":[{\"key\":\"f1\",\"files\":[{\"filename\":\"sales.csv\",\"content\":\"$CSV\"}]}]}}"
# 期待: 200 / outputs に分析テキスト / artifacts に PNG(base64)。保存して日本語が文字化けしないこと。
```

### 5.4 確認観点・トラブルシュート

- **500「サンドボックスに接続できませんでした」**: `SANDBOX_BASE_URL` 未設定 or sandbox 未起動（profile sandbox）。
- **500「コードの実行に失敗しました」**: 生成 LLM が `MAX_ATTEMPTS` 回とも有効コードを出せず。stderr は api ログ参照
  （`code_interpreter_failed` イベント）。モデルを上位帯にするか `input_text` を具体化。
- **生成 LLM未配線で 5xx**: profile `llm` 未起動 or `CODE_INTERPRETER_MODEL`/`LLM_DEFAULT_MODEL` 双方未設定。
- **artifacts が空**: 生成コードが PNG を吐いていない（`output_globs` 既定 `*.png`）。input_text で図示を明示。
  - 旧因の一つ＝**生成 LLM が列名を誤認**（日本語列 `カテゴリ/売上` を英語 `Category/Sales` で決め打ち）。コードは exit 0 で
    「列が無い」と print → 再試行も発火せず PNG 不発。**対処済（api `prompt.ts`・2026-06-03）**：system プロンプトに
    CSV 先頭プレビューを添付し「列名を推測せず df.columns/df.head() で実列を確認」を明示。弱い局所モデル（gemma4:e2b）
    でも正しい日本語チャートを生成することを実機確認。
- ホスト資源が薄い場合、生成 LLM とサンドボックス同時起動でメモリ逼迫しうる（embeddings/RAG の e2e と同傾向）。

### 5.5 利用者向けの再確認（web の「データ分析」UI）

§5.3 の手叩き curl は host curl 不可環境では通らない。利用者が動作を再確認する最も簡単な手段は、web に
ログインして**「データ分析」UI** から CSV/Excel を添付し、日本語ラベルのグラフ生成を依頼することである
（認可・トークン取得・生成 LLM↔サンドボックスの一気通貫が UI 経由でそのまま通る）。認証情報は web の
ログイン（realm 初回 SystemAdmin＝`admin`／初期パスワードは `secrets/keycloak_admin_user_password`）を使う。

> 開発時は認可の負側（no-token=401）→ password grant → 認証済み POST → artifacts の PNG 保存まで自動化した
> 検証ハーネス（配布物には含まれない）で確認している。配布物では上記 web UI での確認を推奨する。

### 確認済（api 経由 e2e・実機 2026-06-03）

JWT（Keycloak `admin`）→ api（`requireAuth`＋`requireUseCase(codeInterpreter)`）→ 生成 LLM `gemma4:e2b`（既定 `LLM_DEFAULT_MODEL`・
CPU）→ NsJail サンドボックス → 結果整形 の一気通貫を実走し、**200／`outputs` に分析テキスト／`artifacts` に日本語ラベル
PNG（文字化けなし）** を確認（開発時の検証ハーネス＝配布物には含まれない・所要 227s／コールドロード込み）。`SANDBOX_ACCEPT_RISK=1`＋
secrets オーバーレイで起動、sandbox は再ビルドで ack ゲート反映済。**生成 LLMは既定の局所 `gemma4:e2b` のまま緑**（上位帯/
cloud-api 不要）＝列名プレビュー対処（§5.4）が個人開発者のハードルを下げる根本対処として有効。

## 6. gVisor 比較（任意）

`runtime: runsc` で起動し、CAP 削減量・チャート生成成否・CPU オーバーヘッド（+5〜20%）を記録。

## 確定値（PoC 実機確定 2026-06-02）

> 環境：Docker 29.4.3 / runtime runc(rootful) / WSL2 カーネル / seccomp builtin。実機 PoC で全機能（nobody 実行・
> network off・timeout・rlimit メモリ・**日本語チャート生成＝文字化けなし**）green を確認。

| 項目 | 初期値 | 確定値 | 備考 |
|---|---|---|---|
| user namespace（clone_newuser） | true（既定） | **false** | 本環境はネスト userns の uid_map/gid_map 書込を一律 EPERM（`unshare -Ur` 単体でも再現）。userns 化＝CAP ゼロ化は**不可**と確定 |
| cap_add | `SYS_ADMIN` | **`SYS_ADMIN` `SETUID` `SETGID` `SETPCAP`** | userns 不使用＝setuid で nobody 降格。SETUID/SETGID=降格、SETPCAP=securebits(PR_SET_SECUREBITS)。各々**除去すると起動不可**を実機確認 |
| security_opt seccomp（外側） | 既定 | **unconfined** | 既定 seccomp が CAP_SYS_ADMIN 保持下でも nsjail の pivot_root を EPERM で阻む。代償は nsjail namespace/setuid/ro-rootfs/netoff/rlimit ＋ **内側 kafel seccomp（下行）** で多層補償 |
| nsjail 内 seccomp（内側・kafel） | 無し | **`seccomp.policy`（DEFAULT ALLOW デナリスト）実装済 2026-06-02** | 外側 unconfined の代償（syscall 攻撃面拡大）を内側で補償。危険 syscall 群を子に `ERRNO(EPERM)`。pivot_root 等は nsjail セットアップ後・exec 直前適用で阻害せず。e2e 緑（§4.5） |
| security_opt no-new-privileges | true | **付与しない** | nsjail の setuid 降格（PR_SET_SECUREBITS）を阻むため。子は nsjail が無権限 nobody に確実に落とす |
| security_opt apparmor | 既定 | **既定のまま（緩和不要）** | seccomp 緩和のみで動作 |
| iface_no_lo | 未設定 | **true** | 新 net namespace で lo を上げない＝NET_ADMIN 不要 |
| workdir 権限 | mkdtemp 0700 | **chmod 0o777（server.py）** | nobody が cwd(/sandbox=bind) へ chdir・生成物書込するため。per-job・単一 jail・network off で許容 |
| /sandbox マウントポイント | 実行時 mkdir | **image に焼く（Dockerfile）** | ro-bind rootfs 上で実行時 mkdir 不可のため空 dir を同梱 |
| rlimit_as (MB) | 1024 | 1024（据え置き） | メモリ爆発で MemoryError を実機確認。pandas/matplotlib 標準チャートは収まる |
| mem_limit | 1536m | 1536m（据え置き） | OOM 観測なし |
| time_limit / SANDBOX_WALL_MS | 8s / 60000ms | 据え置き | 無限ループ→timeout を実機確認 |

### セキュリティ posture（運用判断事項）

userns 化（CAP ゼロ）が本環境で不可のため、到達できる最小は上表（**SYS_ADMIN 含む 4 cap ＋ 外側 seccomp=unconfined ＋ no-new-privileges 無し**）。これは当初アスピレーション（CAP ゼロ userns）より privileged 寄り。**維持される多層防御**：mount/pid/net/ipc/uts/cgroup namespace・rootfs read-only・network off・rlimit（as/cpu/fsize/nofile/nproc）・pids_limit・mem_limit・uid=nobody、**および内側 kafel seccomp（外側 unconfined を補償・実装済 2026-06-02）**。**localhost 単独運用・opt-in（profile sandbox・既定 off）**前提での妥当性を運用者が判断する（判断シート：`docs/sandbox-acceptance-decision.md`）。**後続ハードニング**：① nsjail 内 kafel seccomp（**実装済**・§4.5）② custom 外側 seccomp profile（既定＋pivot_root 許可のみ＝unconfined 回避・未実施）③ gVisor(runsc) 比較（未実施）。
