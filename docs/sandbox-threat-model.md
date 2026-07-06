# Code Interpreter サンドボックス 脅威モデル

Code Interpreter（`POST /api/code-interpreter/responses`）は、LLM が生成した Python を実行して CSV/Excel を
分析しチャートを返す。**実行されるコードは敵対的入力とみなす**（プロンプトインジェクション等で意図しない
コードが生成され得る）。本書はその任意コード実行経路の脅威と多層防御を明文化する。

関連: `sandbox/`（実装）、`docs/sandbox-poc-runbook.md`（実機 PoC・最小 CAP 確定）、
api 側 `genai-ai-api-onpre/src/lib/sandbox/`・`src/routes/codeInterpreter/`。

## 資産と信頼境界

- **信頼**: api コンテナ（認証済みリクエストのみ到達）。
- **準信頼/危険**: サンドボックスコンテナ内で実行される **LLM 生成コード**。ここを信頼しない。
- 信頼境界は「api → サンドボックス」と「サンドボックス supervisor → NsJail 内の被実行コード」の二段。
- 守るべき資産: ホスト、他コンテナ（postgres/keycloak/seaweedfs 等）、内部ネットワーク、秘密情報
  （`.env`/secrets/トークン）、可用性。

## 脅威（STRIDE 簡略）と対策（多層防御）

| 脅威 | 具体 | NsJail 層 | compose 層 |
|---|---|---|---|
| ホスト脱出 | コンテナ/カーネル境界の突破 | 新 namespace・rootfs read-only bind・子を nobody・seccomp | `cap_drop:ALL`＋`cap_add:SYS_ADMIN` のみ・`no-new-privileges`・`read_only` |
| 横移動 | 他コンテナ/DB/S3 へ到達 | `clone_newnet`（NW 名前空間・loopback も無し） | `networks: genai_internal` のみ・ポート公開なし・nginx 非経由 |
| データ流出 | 外部へ送信（C2/exfil） | network off（DNS/socket 全不可） | 内部ネットワークのみ・egress なし |
| 資源枯渇 | 無限ループ・メモリ爆発・fork 爆弾・巨大ファイル | `time_limit`／`rlimit_cpu`／`rlimit_as`／`rlimit_nproc`／`rlimit_fsize` | `mem_limit`／`pids_limit`／`cpus`／`tmpfs size`／server.py の wall-time backstop・出力上限 |
| 永続化/改ざん | ファイル書込で痕跡/汚染 | rootfs read-only・書込は tmpfs と作業 dir のみ・ONCE モード | `read_only: true`・tmpfs はサイズ上限・job ごとに mkdtemp→実行後削除 |
| 情報漏えい | 秘密情報の読取 | サンドボックスに secrets を一切マウント/注入しない・最小マウント | api の secrets はサンドボックスへ渡らない（SANDBOX_BASE_URL のみ） |
| 入力悪用 | パストラバーサル・巨大入力 | （境界外）| api 層: CSV/Excel 拡張子限定・合計サイズ上限。server.py: filename を basename 化・body サイズ上限・同時実行上限(429) |

## 残存リスク

- **カーネル 0-day / seccomp バイパス**: NsJail も seccomp もカーネルに依存。カーネル脆弱性で境界が破られる
  可能性は残る。対策: ホストカーネルの更新、`mem_limit` 等での被害局限、必要なら gVisor（`runsc`）への切替で
  ホスト攻撃面を縮小（CPU +5〜20% のコスト。PoC で比較）。
- **CAP_SYS_ADMIN の攻撃面**: supervisor が root＋CAP_SYS_ADMIN を持つ。NsJail の脆弱性があれば影響大。
  緩和: user-namespace 化による CAP ゼロ化・rootless 化を PoC で試行 → **本環境（WSL2/Docker rootful runc）では
  ネスト userns の uid_map/gid_map 書込がカーネルに一律拒否され不可と確定（2026-06-02）**。到達できる最小は
  `SYS_ADMIN/SETUID/SETGID/SETPCAP`＋seccomp=unconfined（`docs/sandbox-poc-runbook.md` 確定値表）。
- **外側 seccomp=unconfined の代償（PoC 確定 2026-06-02）**: 本環境は既定 seccomp が CAP_SYS_ADMIN 保持下でも
  nsjail の `pivot_root` を EPERM で阻むため、コンテナ外側の seccomp を unconfined にしている。これにより
  **被実行コードからホストカーネルへの syscall 攻撃面が広がる**（外側 seccomp フィルタが無い）。補償＝nsjail の
  namespace 隔離・setuid(nobody)・rootfs read-only・network off・rlimit 群、**および ① 内側 kafel seccomp（下記）**。
  **後続ハードニング**：
  - **① nsjail 内 kafel seccomp ポリシー＝実装済（2026-06-02）**: `sandbox/seccomp.policy`（`nsjail.cfg` の
    `seccomp_policy_file` で適用）。DEFAULT ALLOW のデナリストで、Docker 既定 seccomp が「特権なしでは塞ぐ」
    危険 syscall 群（`unshare`/`setns`/`mount`/`ptrace`/`bpf`/`perf_event_open`/`keyctl`/モジュール/`kexec`/時刻設定
    等）を子に対し `ERRNO(EPERM)` で塞ぐ。nsjail は pivot_root/mount/setuid 完了後・exec 直前に子へ適用するため
    自身のセットアップは阻害しない。**外側 unconfined を内側で補償**する。実機 e2e で `unshare(CLONE_NEWUSER)` が
    seccomp 無し時 `ret=0`（成功）→ 適用時 `EPERM` に変わること、かつ pandas/matplotlib 日本語チャート生成が
    緑のままであることを確認（陰性対照付き・`docs/sandbox-poc-runbook.md` §4.5）。**残る攻撃面**：デナリストに
    無い syscall・カーネル 0-day は依然到達しうる（②③で更に縮小）。`clone(CLONE_NEWUSER)` は ALLOW のまま
    （スレッド用に clone を残す／clone3 は flags が seccomp 非参照のポインタ／未検証の kafel 引数フィルタは
    起動不能リスク）だが、本環境はカーネルが uid_map/gid_map 書込を一律拒否するため新 user-ns でも uid
    マッピング不能＝昇格不可、かつ本フィルタは子へ継承され新 ns 内でも有効＝**中和済み**（`sandbox/seccomp.policy` 注記）。
  - **② custom 外側 seccomp profile**（既定＋`pivot_root` 許可のみ＝unconfined 回避）: 未実施。①で内側を固めた
    ため優先度低。外側フィルタ復活の根治策だが profile 保守コストとのトレードオフ。
  - **③ gVisor(runsc) 移行**: 未実施。ホスト攻撃面を最も縮小（CPU +5〜20%）。本番相当用途で検討。

  ①実装後も **opt-in（profile sandbox・既定 off）・localhost 単独運用前提での受容**を運用者が判断する
  （判断シート：`docs/sandbox-acceptance-decision.md`）。
- **per-job workdir 0o777**: nobody 降格のため per-job 作業 dir を 0o777 にする。単一 jail にのみ bind・network off・
  他ジョブ非共有のため横展開リスクは限定的。出力回収（glob 展開）は jail 外（supervisor=root）で走るため、
  `output_globs` は workdir 直下の相対 glob のみに制限（絶対パス・`/`・`..` を破棄、`server.py:_safe_globs`）し、
  さらに回収候補は `realpath` で workdir 配下に収まることを確認（被実行コードが `chart.png -> /etc/passwd` 等の
  symlink を仕込んでも root が読み戻さない）。実運用では api が常に既定 `['*.png']` を渡すため通常は無害だが、
  境界サービスとして内部直叩きにも耐える多層防御（実装 2026-06-03）。
- **サイドチャネル**: CPU/メモリのタイミング等は本モデルの対象外（個人開発者の開発・実験用途の前提）。

## 静的・動的チェックの織り込み

- **静的**: `sandbox/server.py`・`requirements.txt`・`Dockerfile` を Semgrep / OSV(pip-audit) / Gitleaks /
  Checkov（既存 `scripts/security-scan.sh`・`security-reports/` の枠組み）に含める。公開前に `/security-review`
  ゲートを通す。
- **動的**: `docs/sandbox-poc-runbook.md` の network off 検証・資源上限検証を実機で実施。

## 前提（無保証）

本サンドボックスは**個人開発者の開発・実験用途**を想定した多層防御であり、**本番業務での任意コード実行の
安全性を保証しない**（[DISCLAIMER.md](../DISCLAIMER.md)）。本番相当で使う場合は gVisor/microVM 等への
強化と運用監視を各自の責任で行うこと。
