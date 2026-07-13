# 前提環境のセットアップ（起動手順の前に）

`genai-deploy-onpre` の [README の起動（初期設定〜起動）](../README.md#初期設定起動前の準備) は、**Docker Engine が入った環境で、リポジトリが clone 済み**であることを前提にしています。本書は、その手前の「土台づくり」を**ゼロから**通しで案内します。

- Windows 11 → WSL2 → Ubuntu → 更新 / セキュリティ → Docker Engine → git → clone

WSL2 だけでなく、**ネイティブ Linux** や **macOS** でも動かせます（後述）。最も検証実績があるのは **Windows 11 + WSL2（Ubuntu 24.04 / 26.04 LTS）/ x86_64** と **ネイティブ Linux / x86_64** です（Ubuntu 24.04・26.04 LTS の両方で全体起動を確認済み）。

> **メモリの目安は別途**：本基盤は embedding モデルやローカル LLM が常駐で大きなメモリを占有します。割り当て量の目安は README の [「システム要件」](../README.md#システム要件メモリの目安) を必ず確認してください（特に WSL2 は割当量を `.wslconfig` で明示する必要があります → [後述](#a-2-wsl2-に割り当てるメモリ)）。

---

## 0. どの環境で進めるか

| 環境 | Docker の入れ方 | 備考 |
|---|---|---|
| **Windows 11 + WSL2** (推奨) | Ubuntu 上に **Docker Engine**（Docker Desktop 不要） | → [ルート A](#ルート-a-windows-11--wsl2) |
| **ネイティブ Linux** (Ubuntu/Debian) | **Docker Engine**（apt） | → [ルート B](#ルート-b-ネイティブ-linux-ubuntudebian) |
| **macOS** | **Docker Desktop** か **colima / OrbStack** 等 | → [ルート C](#ルート-c-macos) |

> Docker は **Docker Desktop 非依存**（ライセンス都合や軽量化のため）で動くよう作られていますが、Docker Desktop で動かしても構いません。macOS / WSL を使わない Windows では、ネイティブな Docker Engine は使えないため Docker Desktop 等が必要です。

ルート（A/B/C）でやることが終わったら、共通の [git の導入と clone](#共通-git-の導入と-clone) → [動作確認](#共通-動作確認) → README の起動手順へ進みます。

---

## ルート A: Windows 11 + WSL2

### A-1. WSL2 と Ubuntu を入れる

**管理者権限の PowerShell**（または Windows Terminal）で：

```powershell
# WSL2 + 既定の Ubuntu を一括インストール（要再起動）
wsl --install
```

- 完了後に **PC を再起動**します。再起動後、Ubuntu のウィンドウが開き、**UNIX ユーザー名とパスワード**を求められるので設定します（このパスワードは `sudo` で使います。控えておく）。
- ディストリビューションを選びたい場合：

```powershell
wsl --list --online           # 選べる一覧
wsl --install -d Ubuntu-26.04 # 例：Ubuntu 26.04 LTS を指定（24.04 も可：Ubuntu-24.04）
```

- 既に古い WSL を使っている場合は最新化：`wsl --update`

### A-1b.（任意）使い捨ての試用インスタンスを作る

> **気軽に試せます**：このやり方で作るインスタンスは、いつでも `wsl --unregister` 一発で**跡形なく消せます**（消えるのはそのインスタンスの仮想ディスクだけ。普段使いの Ubuntu や Windows には一切影響しません）。

「まず試して、ダメなら丸ごと消す」をやるなら、Ubuntu 公式の WSL 用イメージを落として **別名のインスタンス**として取り込むのが最もクリーンです（既存環境のコピーではなく、公式の新品から始められる）。本基盤を本番投入する前の「まっさらな環境でゼロから通す」検証に向いています。

> **26.04 以降は公式 `.wsl` イメージが簡単**：Ubuntu 26.04 LTS 以降は、Canonical が配布する **`.wsl` イメージ**を取り込むのが最短です（本基盤は 26.04 LTS で全体起動を確認済み）。**通常ユーザー権限の PowerShell** で：
>
> ```powershell
> # 1) 公式 .wsl イメージ（約 396MB）と SHA256SUMS を取得
> Invoke-WebRequest -Uri "https://releases.ubuntu.com/26.04/ubuntu-26.04-wsl-amd64.wsl" -OutFile "$HOME\Downloads\ubuntu-26.04-wsl-amd64.wsl"
> Invoke-WebRequest -Uri "https://releases.ubuntu.com/26.04/SHA256SUMS" -OutFile "$HOME\Downloads\SHA256SUMS"
>
> # 2) SHA256 で改ざん検査（算出値と SHA256SUMS 内の該当行が一致すれば OK）
> Get-FileHash -Algorithm SHA256 "$HOME\Downloads\ubuntu-26.04-wsl-amd64.wsl"
> Get-Content "$HOME\Downloads\SHA256SUMS" | Select-String "ubuntu-26.04-wsl-amd64.wsl"
> ```
>
> 取り込みは、ダウンロードした `.wsl` を **ダブルクリック**するか、`wsl --install --from-file <ファイル>` で行います（Canonical 公式 doc 記載の手順）。取り込み後は下記 **4)（作業用ユーザー作成）以降**の共通手順へ進んでください。
> （`.wsl` ダブルクリック／`--from-file` の既定インスタンス名は既定に従います。以降で別名運用や `--name` を組み合わせる場合の可否は未検証です。）

以下の **rootfs 方式**（24.04 = noble の例）は 24.04 系でも使える一般手順です。**通常ユーザー権限の PowerShell** で実行します。`D:\wsl` は任意の作業フォルダです（容量に余裕のある SSD 等が望ましい。C ドライブでも可）。

**1) フォルダ作成 + 公式 rootfs / SHA256SUMS の取得**（Ubuntu 24.04 = noble の例・約 340 MB）

```powershell
New-Item -ItemType Directory -Path D:\wsl\genai-test -Force
New-Item -ItemType Directory -Path D:\wsl\downloads  -Force

$base = "https://cloud-images.ubuntu.com/wsl/releases/24.04/current"
Invoke-WebRequest -Uri "$base/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz" -OutFile "D:\wsl\downloads\ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz"
Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile "D:\wsl\downloads\SHA256SUMS"
```

**2) SHA256 で改ざん検査**（2 つのハッシュ文字列が一致することを確認）

```powershell
Get-FileHash -Algorithm SHA256 D:\wsl\downloads\ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz
Get-Content D:\wsl\downloads\SHA256SUMS | Select-String "wsl-amd64-wsl.rootfs.tar.gz"
```

→ 上（算出値）と下（正解値）のハッシュが一致すれば OK（大文字・小文字の違いは無視）。一致しなければ取り込まず 1) からやり直してください。

**3) 別名インスタンスとして取り込んで入る**

```powershell
wsl --import genai-test D:\wsl\genai-test D:\wsl\downloads\ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz
wsl -d genai-test
```

**4) 作業用ユーザーを作る**（取り込み直後の既定ユーザーは `root`）

```bash
adduser genai             # 対話：パスワード等を設定
usermod -aG sudo genai    # sudo を使えるように
```

毎回このユーザーで起動し、systemd も有効にするには、`/etc/wsl.conf` に既定ユーザーと systemd をまとめて設定します（インポートしたインスタンスは既定ユーザーが `root` のため、`[boot]` に加えて `[user]` も要ります）：

```bash
sudo tee /etc/wsl.conf > /dev/null <<'EOF'
[user]
default=genai

[boot]
systemd=true
EOF
```

PowerShell で `wsl --shutdown` → `wsl -d genai-test` で開き直すと、`genai` ユーザーで起動します。

**5) OS を最新化する**（`genai` ユーザーになったので `sudo` 付き）

公式 rootfs は最小イメージです。まず OS を最新化します（これは後述 [B-1](#b-1-os-を最新化する) と同じ更新です。ここで済ませれば B-1 は飛ばして構いません）。

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt autoremove -y
```

> ここで `/etc/wsl.conf`（既定ユーザー＋systemd）を設定済みなら、後述 [A-4](#a-4-wsl2-特有docker-を自動起動させる) の `wsl.conf` 作成は**飛ばし**、`sudo systemctl enable --now docker` だけ実行してください（A-4 の手順はファイルを上書きするため、ここで足した `[user]` 行が消えます）。

以降は本書 [A-2（メモリ割り当て）](#a-2-wsl2-に割り当てるメモリ) → [A-3](#a-3-これ以降は-ubuntu-の中で) の共通手順へ進みます。

**試用が終わったら丸ごと破棄**

```powershell
wsl --list --verbose            # 名前と状態を確認
wsl --unregister genai-test     # このインスタンスを完全削除（取り消し不可）
```

> `--unregister` は **そのインスタンスのデータを完全に消す**操作です（取り消し不可）。名前を取り違えないよう、必ず `wsl -l -v` で確認してから実行してください。普段使いの `Ubuntu` / `Ubuntu-24.04` を消さないこと。

> **補足**：新しめの WSL（`--name` 対応）なら、ダウンロードの代わりに `wsl --install -d Ubuntu-24.04 --name genai-test` でも別名インスタンスを作れます（`wsl --version` で対応を確認。使えなければ上の rootfs 方式を使う）。

### A-2. WSL2 に割り当てるメモリ

WSL2 は既定でホスト RAM の一部しか使いません。README の「システム要件」（RAG + chat 同時は 16 GB 以上推奨）に合わせ、**Windows 側**で割当量を明示します。

`C:\Users\<あなた>\.wslconfig` を作成（メモ帳等で。WSL からは `/mnt/c/Users/<あなた>/.wslconfig`）：

```ini
[wsl2]
memory=12GB      # ホストの搭載量に応じて調整（例：搭載16GBなら12GB程度）
swap=8GB         # OOM 緩和のため余裕をもって
```

反映するには **PowerShell** で WSL を一度落とします：

```powershell
wsl --shutdown
```

次に Ubuntu を開き直し、`free -h` で `Mem` / `Swap` を確認します。

### A-3. これ以降は Ubuntu の中で

ここから先は **Ubuntu のターミナルの中**で行います。次の 3 つはネイティブ Linux（ルート B）と内容が同じなので、リンク先を順に実施してください：

1. [B-1. OS を最新化する](#b-1-os-を最新化する) — A-1b の使い捨てインスタンスで実施済みなら飛ばす
2. [B-2. セキュリティの最低限](#b-2-セキュリティの最低限) — WSL2 では `ufw` は不要（OS 更新と強いパスワードのみ）
3. [B-3. Docker Engine を入れる](#b-3-docker-engine-を入れる公式-apt-リポジトリ) — **Docker Engine 本体のインストール**

3 つが終わったら本書に戻り、WSL2 特有の [A-4（Docker を自動起動させる）](#a-4-wsl2-特有docker-を自動起動させる) 以降（A-5・A-6）を続けてください。

### A-4. WSL2 特有：Docker を自動起動させる

WSL2 では、Docker デーモンが自動で立ち上がりません。**systemd を有効化**して、`docker` をサービスとして起動するのが簡単です。

Ubuntu 内で `/etc/wsl.conf` を編集（無ければ作成）：

```bash
sudo tee /etc/wsl.conf > /dev/null <<'EOF'
[boot]
systemd=true
EOF
```

PowerShell で `wsl --shutdown` → Ubuntu を開き直し、Docker を有効化：

```bash
sudo systemctl enable --now docker
```

> systemd を使わない場合は、WSL を開くたびに `sudo service docker start` が必要です。systemd 有効化を推奨します。

### A-5. WSL2 の注意：リポジトリは Linux 側に置く

clone 先は必ず **Linux ファイルシステム配下**（例：`~/work`）にします。`/mnt/c/...`（Windows 側）に置くと、**ビルドが極端に遅く・ファイル権限の不整合**が起きます。

### A-6.（推奨）WSL2 カーネルの脆弱性対応：カーネル更新（＋未使用モジュールの無効化）

> **なぜ WSL2 固有か**：WSL2 のカーネルは **Microsoft 提供**で、Ubuntu の `apt upgrade` ではパッチされません（カーネル更新は `wsl --update`）。
> （ネイティブ Linux（ルート B）は `apt full-upgrade`＋再起動でカーネルごと修正版へ更新されるため、この手順は不要です。Ubuntu 24.04 の修正カーネルは配布済み＝`linux` 6.8.0-124.124 以上。）

2026 年春、Ubuntu 24.04 系が影響を受ける Linux カーネルのローカル特権昇格（LPE）脆弱性が相次いで公表されました。**いずれも修正済みカーネルが配布済みです（確認時点：2026 年 7 月）**。

| 通称 | CVE | 対象モジュール | 修正済み上流カーネル（6.18 系） |
|---|---|---|---|
| Copy Fail | CVE-2026-31431 | `algif_aead`（AF_ALG userspace crypto） | 6.18.22 |
| Dirty Frag | CVE-2026-43284 / -43500 | `esp4` / `esp6`（IPsec ESP）/ `rxrpc`（AFS RPC） | 6.18.28 / 6.18.29 |
| Fragnesia | CVE-2026-46300 | `esp4` / `esp6` / `rxrpc`（Dirty Frag と同一） | 6.18.33 |

**最善の対応＝カーネル更新（恒久対策）**。Microsoft 配布の WSL2 カーネルは 2026 年 6 月以降 6.18.33 系以上が配布されています（[microsoft/WSL2-Linux-Kernel releases](https://github.com/microsoft/WSL2-Linux-Kernel/releases)）。**PowerShell（Windows 側）**で：

```powershell
wsl --update
wsl --shutdown
```

その後 Ubuntu を開き直して確認します：

```bash
uname -r   # 6.18.33 以上なら上表 3 系統すべて修正済み
```

**暫定緩和策（未使用モジュールの無効化）**：`uname -r` がまだ修正版に届かない場合や、すぐにカーネル更新できない場合のつなぎです。Ubuntu Security Team が「該当モジュールの無効化」を緩和策として案内しています。本基盤は対象モジュール（userspace 暗号 API・IPsec ESP・AFS RPC）を**使わない**ため、無効化による副作用はなく、**カーネル更新後も多層防御として残して構いません**。

**Ubuntu の中**で、該当モジュールを `install <mod> /bin/false` で無効化します（blacklist だけでは不十分なため、Ubuntu 公式と同じく `install ... /bin/false` を使います）：

```bash
# Copy Fail (CVE-2026-31431)
echo "install algif_aead /bin/false" | sudo tee /etc/modprobe.d/disable-algif.conf
sudo rmmod algif_aead 2>/dev/null || true

# Dirty Frag / Fragnesia (CVE-2026-43284 / -43500 / -46300)
sudo tee /etc/modprobe.d/dirty-frag.conf > /dev/null <<'EOF'
install esp4 /bin/false
install esp6 /bin/false
install rxrpc /bin/false
EOF
sudo rmmod esp4 esp6 rxrpc 2>/dev/null || true

# 確認（出力が空＝いずれも未ロードなら OK）
lsmod | grep -E 'algif_aead|esp4|esp6|rxrpc' || echo "対象モジュールは未ロード（OK）"
```

> **`update-initramfs` は不要**：WSL2 は initramfs を使わず、`modprobe` が `/etc/modprobe.d/*.conf` を直接参照するため、再起動後も無効化が維持されます。
> **恒久対策は冒頭のカーネル更新（`wsl --update`）です**。緩和策のみで運用している場合は、更新後に `uname -r` で修正版到達を確認してください。最新の対応状況は一次情報を確認：Ubuntu Security Team（[Copy Fail](https://ubuntu.com/blog/copy-fail-vulnerability-fixes-available) / [Dirty Frag](https://ubuntu.com/blog/dirty-frag-linux-vulnerability-fixes-available) / [CVE-2026-46300](https://ubuntu.com/security/CVE-2026-46300)）。

> **→ ここまでで WSL2（ルート A）の土台づくりは完了です。次は [共通: git の導入と clone](#共通-git-の導入と-clone) へ進みます。**

---

## ルート B: ネイティブ Linux (Ubuntu/Debian)

> 以降は **Ubuntu 22.04 / 24.04 系** を前提にしたコマンドです。WSL2 (ルート A) の方も、A-3 の指示でここに来ます。

### B-1. OS を最新化する

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt autoremove -y
```

### B-2. セキュリティの最低限

個人開発・**localhost 用途**の前提での最小限です（本基盤は開発・実験用途・無保証。[DISCLAIMER](../DISCLAIMER.md) 参照）。

```bash
# 自動セキュリティ更新（任意・推奨）
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

- **強いパスワード**を UNIX ユーザーに設定し、不要なサービスは動かさない。
- **ネイティブ Linux で LAN 公開する場合**はファイアウォール（`ufw`）で必要ポートだけ開ける：

  ```bash
  sudo apt install -y ufw
  sudo ufw default deny incoming
  sudo ufw allow ssh        # SSH を使う場合のみ
  sudo ufw allow 443/tcp    # nginx(HTTPS) を LAN 公開する場合のみ
  sudo ufw enable
  ```

> **WSL2 の方**：WSL2 は Windows の NAT 配下にあり、LAN からの着信は既定で素通しされません。主な防御は **Windows 側（Windows Defender ファイアウォール）**です。Ubuntu 内の `ufw` は基本的に不要で、上のブロックは飛ばして構いません。OS の更新（B-1）と強いパスワードは WSL2 でも有効です。

### B-3. Docker Engine を入れる（公式 apt リポジトリ）

```bash
# 1) 競合する古いパッケージを除去（入っていなければ無害）
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg 2>/dev/null || true
done

# 2) Docker 公式 apt リポジトリを登録
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# 3) Docker Engine + Compose プラグインをインストール
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

> Debian の場合は URL の `ubuntu` を `debian` に置き換えてください。

**sudo なしで docker を使えるようにする**（任意・推奨）：

```bash
sudo usermod -aG docker $USER
# 反映には再ログインが必要。WSL2 なら PowerShell で `wsl --shutdown` 後に開き直す。
```

> **WSL2 の方**：この後 [A-4（Docker の自動起動）](#a-4-wsl2-特有docker-を自動起動させる) と [A-5（リポジトリ配置）](#a-5-wsl2-の注意リポジトリは-linux-側に置く) に戻ってください。
> **ネイティブ Linux の方**：systemd が docker を自動起動します。必要なら `sudo systemctl enable --now docker`。**→ ここまでで土台づくりは完了です。次は [共通: git の導入と clone](#共通-git-の導入と-clone) へ進みます。**

---

## ルート C: macOS

macOS では Linux のネイティブ Docker Engine は使えません。次のいずれかを入れます。

- **Docker Desktop**（最も簡単）
- **colima**（CLI 互換・軽量）：`brew install colima docker docker-compose` → `colima start --cpu 4 --memory 12`
- **OrbStack** / **Rancher Desktop** 等

git は `xcode-select --install` または Homebrew (`brew install git`) で入ります。以降の clone は共通手順と同じです。

> **Apple Silicon (arm64) の注意**：同梱 OSS イメージの一部は arm64 での検証が十分でない可能性があります（GPU 前提の機能は特に）。まずは **chat のみの最小構成**から試すことを推奨します。確実なのは **x86_64 (Windows11/WSL2 または ネイティブ Linux)** です。

> **→ ここまでで土台づくりは完了です。次は [共通: git の導入と clone](#共通-git-の導入と-clone) へ進みます。**

---

## 共通: git の導入と clone

### git を入れる（無ければ）

```bash
# Ubuntu/WSL2
sudo apt install -y git
git --version
```

> 本書の目的（clone して `docker compose up`）には `git config` のユーザー設定は不要です。自分で変更を `git commit` する場合のみ `git config --global user.name` / `user.email` を設定してください。

### リポジトリを clone（配置が重要）

本基盤は **3 つのリポジトリ**で構成されます。本リポジトリ（deploy）は `api` コンテナを **`../genai-ai-api-onpre`**（**同じ親ディレクトリ**）からビルドするため、**3 つを横並び**に clone します。

| リポジトリ | 役割 | clone |
|---|---|---|
| `genai-deploy-onpre` | デプロイ／インフラ層（docker compose を実行） | 必須 |
| `genai-ai-api-onpre` | AI アプリ API（`api` のビルド元 `../genai-ai-api-onpre`） | 必須 |
| `genai-web-onpre` | Web フロントエンド（ソース） | 推奨 |

```bash
mkdir -p ~/work && cd ~/work

# 本リポジトリ（deploy）
git clone https://github.com/sanpoyoshi-commons/genai-deploy-onpre.git genai-deploy-onpre

# api（同じ親ディレクトリに横並びで配置）
git clone https://github.com/sanpoyoshi-commons/genai-ai-api-onpre.git genai-ai-api-onpre

# web（フロントエンド・横並びで配置）
git clone https://github.com/sanpoyoshi-commons/genai-web-onpre.git genai-web-onpre
```

配置が次のようになっていれば OK です：

```
~/work/
├── genai-deploy-onpre/      ← ここで docker compose を実行
│   └── docker-compose.yml
├── genai-ai-api-onpre/      ← api のビルド元（../genai-ai-api-onpre）
└── genai-web-onpre/         ← Web フロントエンドのソース
```

> **web の動かし方（補足）**：本リポジトリは web のビルド済み成果物を**同梱しません**。横並びの `genai-web-onpre`（ソース）を clone し、`./scripts/build-web.sh` でビルドして deploy の `web/` に配置すると、nginx がそれを配信します（下記「次のステップ」参照）。`web/` は `.gitignore` 対象のローカルビルド出力です。フロントエンドを改変したいときは `genai-web-onpre` を編集して再ビルドします。

> URL は配布元に合わせて読み替えてください。**WSL2 の方は必ず Linux 側（例 `~/work`）に置く**こと（[A-5](#a-5-wsl2-の注意リポジトリは-linux-側に置く)）。

---

## 共通: 動作確認

Docker が使える状態かを確認します。

```bash
docker version            # Client/Server 両方が表示されれば OK
docker compose version    # Compose v2 プラグインの確認
docker run --rm hello-world   # 実際にコンテナが動くか
```

- `permission denied`（docker.sock）→ `usermod -aG docker $USER` 後の再ログインがまだ。WSL2 は `wsl --shutdown` 後に開き直す。
- `Cannot connect to the Docker daemon` → デーモン未起動。WSL2 は [A-4](#a-4-wsl2-特有docker-を自動起動させる)、ネイティブ Linux は `sudo systemctl start docker`。

---

## 次のステップ

ここまで完了したら、本リポジトリ（`~/work/genai-deploy-onpre`）に移動します。

```bash
cd ~/work/genai-deploy-onpre
```

### Web フロントエンドをビルドして配置する（初回・更新時）

本リポジトリは web のビルド済み成果物を同梱しません。横並びの `genai-web-onpre` から
ビルドして `web/` に配置します（**Docker 内でビルド**するのでホストに node は不要）：

```bash
./scripts/build-web.sh
```

> `genai-web-onpre` を更新したら再実行してください。`api` は `docker compose build` が
> `../genai-ai-api-onpre` から直接ビルドするため、別途のビルドは不要です。

→ **[README「初期設定・起動」](../README.md#初期設定起動前の準備)**（`.env` 作成 → 証明書生成 → secrets 生成 → web ビルド → `docker compose build` → `docker compose up -d`）
