# Code Interpreter サンドボックス セキュリティ posture 受容判断シート

> 本書は **運用者が一度判断し記録する**ためのシート。Code Interpreter（任意コード実行）を有効化する際の
> セキュリティ posture と残存リスクを一枚に集約する。背景の詳細は `docs/sandbox-threat-model.md`（脅威モデル）と
> `docs/sandbox-poc-runbook.md`（PoC 確定値・検証手順）。

## 1. 判断する事項

**Code Interpreter（`profile: sandbox`・既定 off）を、下記 posture のまま有効化してよいか。**

具体的には「**外側 docker `seccomp=unconfined`＋4 cap（SYS_ADMIN/SETUID/SETGID/SETPCAP）**」という、当初
アスピレーション（userns による CAP ゼロ化）より privileged 寄りの構成を、**opt-in・既定 off・localhost 単独運用**
前提で受容するか否か。

## 2. なぜこの posture なのか（不可避だった制約）

- 当初目標は **userns 化で CAP をゼロにする**ことだった。
- **本環境（WSL2／Docker rootful runc）はネストした user namespace の uid_map/gid_map 書込をカーネルが一律
  EPERM で拒否**する（`unshare -Ur` 単体でも再現・PoC 2026-06-02 確定）。→ userns 化＝CAP ゼロ化は**不可**。
- 到達できた最小は **4 cap ＋ 外側 seccomp=unconfined**（各 cap は除去すると nsjail 起動不可を実機確認）。
- 外側 unconfined が要るのは、**Docker 既定 seccomp が CAP_SYS_ADMIN 保持下でも nsjail の `pivot_root` を EPERM で
  阻む**ため（nsjail の隔離セットアップ自体が通らない）。

## 3. 残存リスク（受容対象）

| # | リスク | 重大度の見立て |
|---|---|---|
| R1 | **外側 seccomp 喪失**：被実行コード→ホストカーネルの syscall 攻撃面が広い | 中（→ §4 ① で大幅補償済） |
| R2 | **CAP_SYS_ADMIN を supervisor が保持**：nsjail に脆弱性があれば影響大 | 中（localhost・opt-in で露出限定） |
| R3 | **カーネル 0-day / seccomp バイパス**：境界はカーネル依存 | 低〜中（ホスト更新・被害局限で緩和） |
| R4 | **per-job workdir 0o777**：nobody 降格のため作業 dir を開放 | 低（単一 jail・netoff・他ジョブ非共有） |

## 4. 補償コントロール（既に効いている多層防御）

被実行コードは**敵対的入力**とみなした上で、以下が**重畳**で効く：

- **① 内側 kafel seccomp（実装済 2026-06-02）** — `sandbox/seccomp.policy`。外側 unconfined の代償（R1）を
  内側で補償。`unshare`/`setns`/`mount`/`ptrace`/`bpf`/`perf_event_open`/`keyctl`/モジュール/`kexec`/時刻設定 等を
  子に `ERRNO(EPERM)`。実機 e2e で `unshare(CLONE_NEWUSER)` が無効化時 `ret=0`→適用時 `EPERM` に変わること、かつ
  pandas/matplotlib 日本語チャートが緑のままを確認（陰性対照付き・runbook §4.5）。
- **namespace 隔離** — mount/pid/net/ipc/uts/cgroup を新規取得。
- **network off** — 新 net namespace・loopback も上げず（DNS/socket 全不可＝C2/exfil 不可）。
- **rootfs read-only**＋書込は tmpfs と per-job 作業 dir のみ・ONCE モード。
- **uid=nobody(65534)** へ setuid 降格・無 CAP。
- **資源上限** — rlimit（as/cpu/fsize/nofile/nproc）＋ compose 側 mem_limit/pids_limit/cpus/tmpfs size ＋
  server.py の wall-time backstop・出力上限。
- **入口の補助検証** — api 層で CSV/Excel 拡張子限定・合計サイズ上限、server.py で filename basename 化・
  body サイズ上限・同時実行上限(429)。
- **秘密情報を渡さない** — サンドボックスへ secrets を一切マウント/注入しない（`SANDBOX_BASE_URL` のみ）。

## 5. 採らなかった代替と理由

| 代替 | 状態 | 理由 |
|---|---|---|
| userns 化（CAP ゼロ） | **不可** | 本環境でカーネルが uid_map 書込を一律拒否（§2） |
| ② custom 外側 seccomp profile（既定＋pivot_root のみ許可） | 未実施 | ①で内側を固めたため優先度低。外側復活の根治策だが profile 保守コスト |
| ③ gVisor(runsc) 移行 | 未実施 | ホスト攻撃面を最も縮小（CPU +5〜20%）。本番相当用途で別途検討 |

## 6. 受容の前提条件（これらが崩れたら再判断）

1. **opt-in・既定 off**：`profile: sandbox` を明示起動した時のみ有効。既定構成では起動しない。
2. **localhost 単独運用**：個人開発者の開発・実験用途。インターネット公開・マルチテナントは想定外。
3. **無保証**：本番業務での任意コード実行の安全性は保証しない（`DISCLAIMER.md`）。本番相当で使うなら
   gVisor/microVM 等への強化と運用監視を各自の責任で行う。
4. **ホストカーネルを更新し続ける**：境界はカーネル依存（R3）。

## 7. 判断記録（運用者が記入）

- [x] §3 残存リスク（R1〜R4）と §4 補償を理解した。
- [x] §6 の前提条件（opt-in・既定 off・localhost・無保証・カーネル更新）を受容する。
- 判断: ☑ **受容して有効化を許可** ／ ☐ 条件付き（下記） ／ ☐ 非受容（②/③ を先に要求）
- 条件・備考（任意）: opt-in・既定 off の前提を維持する。有効化（`sandbox` profile）には `SANDBOX_ACCEPT_RISK=1` の明示を必須とし、起動時に posture 警告を表示する（利用者への二段確認）。本番相当用途に持ち込む場合は §5 の ②custom 外側 seccomp profile ／ ③gVisor 移行を別途検討する。
- 判断者・日付: 運用者 / 2026-06-03
