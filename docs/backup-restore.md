# バックアップ・リストア手順

`genai-deploy-onpre` のバックアップとリストアの運用手順をまとめます。
個人開発者 1 人が cron 登録だけで日次運用に乗せられる粒度を目指しています。

> ⚠ 本ドキュメントは「同一バージョンでのデータ消失復旧（通常リストア）」を中心に扱います。
> OSS のメジャーバージョンアップに伴う移行（切戻し）と災害復旧（PC 故障／ランサムウェア等）
> は手順テンプレートのみ示します。詳細手順は各 OSS の公式ドキュメントを参照してください。

## 目次

1. [対象データ](#1-対象データバックアップスコープ)
2. [バックアップ二層](#2-バックアップ二層)
3. [リストア三シナリオ](#3-リストア三シナリオ)
4. [鍵管理／secrets 取扱い](#4-鍵管理secrets-取扱い)
5. [免責](#5-免責)

---

## 1. 対象データ（バックアップスコープ）

| # | OSS／ボリューム | 内容 | 扱い |
|---|---|---|---|
| 1 | `postgres_data` | 業務 DB（pgvector + pg_bigm 拡張、Prisma 管理テーブル群） | **必須**／論理＋物理 |
| 2 | `keycloak_db_data` | 認証 DB（realm／client／user／event 等） | **必須**／論理＋物理 |
| 3 | `seaweedfs_data` | 添付ファイル＋filer メタデータ（at-rest 暗号化済） | **必須**／物理のみ |
| 4 | `ollama_models` / `tei_data` / `whisper_hf_cache` | LLM／embedding／文字起こしモデル | バックアップ対象外（モデル名＋タグを記録し、必要時に再ダウンロード） |
| 5 | `elasticmq_data` | キュー | バックアップ対象外（再起動で失っても良い設計） |
| 6 | `secrets/` 配下 | docker secrets 実体＋テンプレ展開済 config | **外部の鍵管理（パスワードマネージャ／別 NAS 等）で別管理**。本スクリプトの対象外 |

---

## 2. バックアップ二層

### 2-1. 論理バックアップ（業務 DB／認証 DB）

各 PostgreSQL から `pg_dump -F custom -Z 6` で取得します。**稼働中安全**（MVCC、ダウンタイムなし）。

```bash
# 既定 ./backups/ に出力
./scripts/backup.sh logical

# 出力先を指定（例：/var/backups/genai）
./scripts/backup.sh logical /var/backups/genai
```

生成物：

- `postgres_YYYYMMDD-HHMMSS.dump` … 業務 DB
- `keycloak_db_YYYYMMDD-HHMMSS.dump` … 認証 DB

出力ファイルは mode 600（実行ユーザ所有）、出力ディレクトリは mode 700 です。

### 2-2. 物理バックアップ（SeaweedFS、論理 + 物理の一括）

SeaweedFS の **コンテナを停止**してから `/data` 全体を tar gz で取得します。

- 現状（小規模データ）で約 **15〜20 秒のダウンタイム**
- データ量が増えると線形に増加（運用開始後の経過観察推奨）

```bash
./scripts/backup.sh full                    # 論理＋物理 一括
./scripts/backup.sh full /var/backups/genai # 出力先指定
```

生成物：

- `postgres_YYYYMMDD-HHMMSS.dump`
- `keycloak_db_YYYYMMDD-HHMMSS.dump`
- `seaweedfs_YYYYMMDD-HHMMSS.tar.gz`

### 2-3. なぜ「停止→tar→起動」が必要か（SeaweedFS 暗号化との整合）

SeaweedFS は at-rest 暗号化（`-s3.encryptVolumeData` / `-filer.encryptVolumeData`、デフォルト ON）を
有効化しています。実体は：

| 項目 | 場所 |
|---|---|
| filer store バックエンド | LevelDB2（`filer.toml`：`[leveldb2] dir="/data/filerldb2"`） |
| **暗号化鍵の保存実体** | **filer メタデータ（LevelDB2）内にチャンク毎ランダム鍵（AES256-GCM 256bit）** |
| volume データ | `/data/{N}.dat` / `.idx` / `.vif`（暗号化済バイト列） |
| master メタ | `/data/m9333/` |

→ **volume データと filer メタを同一時点で取得しないと、復元時に復号できなくなります**。
LevelDB2 はプロセスダウン時にロック解放＋整合状態になるため、SeaweedFS コンテナを停止してから
`/data` 全体を tar することで暗号化鍵保全と整合取得を同時に満たす設計です。

オンラインバックアップ（`weed filer.backup` 等）は鍵保全の検証が未完のため、現時点では
「停止→tar→起動」のみを推奨しています。

### 2-4. cron 登録例

```cron
# /etc/cron.d/genai-deploy-onpre-backup（root 所有・644）

# 日次（毎日 2:00、論理バックアップのみ・ダウンタイムなし）
0 2 * * * gennai cd /opt/genai-deploy-onpre && ./scripts/backup.sh logical /var/backups/genai >> /var/log/genai-backup.log 2>&1

# 週次（日曜 3:00、SeaweedFS 物理含む完全バックアップ・数分のダウンタイム）
0 3 * * 0 gennai cd /opt/genai-deploy-onpre && ./scripts/backup.sh full    /var/backups/genai >> /var/log/genai-backup.log 2>&1

# 30 日超の古いバックアップを削除（同じファイルの末尾に追記推奨）
0 4 * * * root find /var/backups/genai -maxdepth 1 -type f \( -name '*.dump' -o -name '*.tar.gz' \) -mtime +30 -delete
```

`gennai` の部分は実行ユーザ名（Docker グループに所属し、当該リポジトリに read 権限を持つユーザ）に
合わせて読み替えてください。systemd timer 派は `genai-backup-{logical,full}.{service,timer}` で同等の
運用ができます。

### 2-5. オフサイト保管（災害復旧前提）

`/var/backups/genai/` の中身を、別 PC／外部メディア／オフサイトストレージへ同期します。

```bash
# 例：rsync over SSH（cron 末尾に追記）
rsync -a --delete /var/backups/genai/ user@offsite:/srv/genai-backup/
```

外部メディア（USB 接続 HDD／NAS）／オフサイト（クラウドストレージ／別拠点 NAS）の選択は
環境依存です。

---

## 3. リストア三シナリオ

### 3-1. 通常リストア（バージョン同一・データ消失復旧）

バックアップ世代を選んで、運用者が**ターミナルで対話実行**します。`pg_restore --clean` を伴うため、
cron からの自動実行は不可です。

```bash
# 論理のみ（業務 DB と認証 DB の復元）
./scripts/restore.sh logical \
  /var/backups/genai/postgres_YYYYMMDD-HHMMSS.dump \
  /var/backups/genai/keycloak_db_YYYYMMDD-HHMMSS.dump

# 完全リストア（業務 DB ＋ 認証 DB ＋ SeaweedFS）
./scripts/restore.sh full \
  /var/backups/genai/postgres_YYYYMMDD-HHMMSS.dump \
  /var/backups/genai/keycloak_db_YYYYMMDD-HHMMSS.dump \
  /var/backups/genai/seaweedfs_YYYYMMDD-HHMMSS.tar.gz
```

スクリプトは冒頭で「`RESTORE` と入力するまで実行しない」確認 prompt を出します。

**復元後の app 層 restart は自動です**。DB／SeaweedFS を直下で差し替えると、Keycloak は realm を
メモリにキャッシュし、`api`／`worker` は古い DB 接続プールを保持するため、復元データが即座に反映され
ません。スクリプトは復元完了後に **稼働中の app 層（`keycloak` / `api` / `worker`）を自動で restart し、
healthy 復帰まで待機**します（`worker` は `--profile queue` 未起動なら自動でスキップ）。追加の手作業は
不要です。

> healthy 復帰待ちの上限は既定 120 秒です。大きめのデータや非力なホストで時間がかかる場合は
> `RESTORE_HEALTH_TIMEOUT=300 ./scripts/restore.sh ...` のように環境変数で延ばせます。

復元後（任意の整合確認）：

```bash
# コンテナが healthy か確認（app 層 restart・healthy 復帰は既にスクリプト内で完了済み）
docker compose -f docker-compose.yml -f docker-compose.secrets.yml ps
```

- ブラウザで web にログインできること（Keycloak 認証経路の整合）。
- チャットが応答すること（api↔DB／api↔Keycloak Admin REST の整合）。
- ファイルのアップロード・参照ができること（SeaweedFS/S3 経路の整合）。

### 3-2. 切戻し（OSS バージョンアップ後のロールバック）

バージョンアップ後の不具合発覚時に旧バージョンに戻すシナリオ。**PostgreSQL 16→17・Keycloak 26.0.0→26.6.2
で実機検証済み**（4-2、2026-05-29）。

> **結論：アップグレードを「論理移行」で行えば、切戻しも「論理バックアップ＋旧 image」で足ります。
> `pg_upgrade` のような物理 in-place 変換を使わない限り、切戻しに物理バックアップは不要です**（実機確定）。

#### 推奨：論理移行アップグレード（まずはこちら）

本配布物の `backup.sh` / `restore.sh` はこの論理移行を支援します。

1. **事前**：`backup.sh full` で**アップグレード前の論理バックアップ**を取得（DB は `pg_dump`、SeaweedFS は停止 tar）
2. **事前**：新バージョンの image を確保（`docker pull` または build）。**旧バージョンの image はローカルに残す**
   （Docker タグ＋digest 固定＝再取得可能。重要版は `docker save` でも退避）
3. 新バージョンへ compose を更新（PostgreSQL 業務 DB はカスタムイメージのため、`postgres/Dockerfile` の
   ベース（`pgvector/pgvector:0.8.2-pgXX`）と `postgresql-server-dev-XX` を新版へ変えて `docker compose build postgres`。
   keycloak-db / Keycloak は image タグ＋digest を差し替え）
4. `down -v` → 新バージョンで `up -d`（新 `initdb` で空起動）→ `restore.sh full <アップグレード前 dump>` で復元
5. アプリ動作確認。問題があれば下記の切戻しへ

**切戻し手順**（論理移行アップグレードからの戻し）：

1. compose / Dockerfile を旧バージョンへ戻す（`git checkout` または image タグ＋digest を revert）。
   **旧 image がローカルキャッシュに残っていれば再ビルド不要＝即時**
2. `down -v` → 旧バージョンで `up -d`（旧 `initdb` で空起動）
3. `restore.sh full <アップグレード前 dump>` で**アップグレード前の論理 dump を旧バージョンへ復元**
4. healthy 確認・整合確認（同一環境＝secrets 不変なら**パスワード整合作業は不要**）

実機検証（2026-05-29）で確認した事実：

- **PostgreSQL（Q-1）**：論理 dump（`pg_dump -F custom`）は**バージョン間で双方向に可搬**。pg16→pg17→pg16 の
  全周で、`vector`（pgvector 0.8.2）/ `pg_bigm`（1.2）拡張・HNSW/GIN インデックス・`vector(768)` データが
  完全に再構築・機能した。pg_bigm はソースビルドのため、新版では `postgresql-server-dev-XX` で再ビルドする
  （v1.2-20250903 は pg17 でビルド成功）。
- **Keycloak（Q-2）**：アップグレードで DB スキーマが**前方向に移行**する（26.0.0→26.6.2 で Liquibase の
  changeset が 144→188 に増加）。旧 Keycloak を新スキーマ DB に当てても**即座に起動失敗はしない**が、
  Keycloak 自身が「`Possibly incorrect state of migration … already migrated to newer version`」と警告する
  **非サポートの不整合状態**になる。**正しい切戻しは「アップグレード前 keycloak_db の論理 dump を旧 Keycloak へ
  復元」**（`restore.sh` がこれを担う）。これでスキーマが旧バイナリに一致し警告も消える。Keycloak も
  **論理 dump で切戻し可能・物理バックアップ不要**。

#### 物理 in-place アップグレード（`pg_upgrade`）を使う場合の注意

`pg_upgrade` で**物理 in-place 変換**を行うと、データディレクトリが新バージョン形式（`PG_VERSION` が 16→17）に
書き換わり、**旧バージョンのバイナリはそのデータディレクトリを起動時に拒否します**（実機観測：
`FATAL: database files are incompatible with server / The data directory was initialized by PostgreSQL
version 17, which is not compatible with this version 16`）。**この経路を選んだ場合に限り、切戻しには
アップグレード前の物理バックアップ（またはアップグレード前 volume の保全）が必要**です。本配布物は
論理移行（上記推奨）を前提とするため、通常はこの制約を受けません。

#### イメージのローカル退避（Docker Hub 削除リスクへの備え）

旧バージョンへ確実に戻せるよう、重要なイメージはローカルに退避します（タグ＋digest 固定で再取得可能ですが、
Docker Hub からの削除に備える）。

```bash
# 例：postgres 16.14 のイメージを tar に export しておく
docker save -o /var/backups/genai/postgres-pg16.14.tar \
  postgres:16.14-alpine@sha256:16bc17c64a573ef34162af9298258d1aec548232985b33ed7b1eac33ba35c229

# 業務 DB のカスタムイメージ（pgvector + pg_bigm）も同様に退避できる
docker save -o /var/backups/genai/genai-postgres-pg16.tar \
  genai-postgres-onpre:pg16-pgvector0.8.2-pgbigm1.2
```

#### SeaweedFS のバージョン跨ぎ（minor）と切戻し

> **結論：SeaweedFS の同一メジャー内 minor 跨ぎ（実機検証 4.22↔4.29、2026-05-30）は、image タグ＋digest を
> 差し替えて `up -d seaweedfs` するだけ（同一 volume の in-place recreate・`down -v` 不要）で版を上げられ、
> 既存の暗号化オブジェクトは版跨ぎ後もそのまま復号できます。切戻しも同じく旧版タグへ revert して
> `up -d seaweedfs` する in-place で戻せます（4.29→4.22 も実機成立）。**

PostgreSQL・Keycloak と異なり **SeaweedFS には論理 dump がありません**（バックアップは `backup.sh full` の
物理 tar のみ）。そのため「物理 vs 論理」の選択は無く、版跨ぎは on-disk データ（`/data` の volume＋filer メタ）
を新バイナリがそのまま読めるかどうかが本質になります。

実機検証（Q-3、2026-05-30）で確認した事実：

- **on-disk 形式の互換（Q-3a）**：同一メジャー内 minor 跨ぎ（4.22↔4.29）で、volume（`{N}.dat`/`.idx`/`.vif`）・
  filer メタ（LevelDB2 `filerldb2/`）・master raft（`m9333/`）・`vol_dir.uuid` を **migration なしで双方向に読込**。
  4.22→4.29 へ in-place recreate しても、4.29→4.22 へ戻しても healthy・全バケット健在。
- **at-rest 暗号鍵の互換（Q-3b・W-08-D2 の核）**：暗号鍵（filer LevelDB2 内のチャンク毎 AES256-GCM 鍵）の
  保存・復号方式は版跨ぎで不変。4.22 で投入した暗号化オブジェクトを **4.29 で S3 GetObject して平文が完全一致**
  （戻した 4.22 でも一致）。**鍵の再生成・移行は不要**。

**推奨手順（in-place・まずはこちら）**：

1. **事前**：`backup.sh full` で**アップグレード前の物理 tar を取得**（後述の非互換時フォールバックの安全網）。
   旧版 image はローカルに残す（タグ＋digest 固定＝即時切戻し）。
2. 新版 image を `docker pull`（`seaweedfs` と `seaweedfs-init` は同一 image）。
3. `docker-compose.yml` の `seaweedfs` / `seaweedfs-init` の image タグ＋digest を新版へ差し替え。
4. `docker compose -f docker-compose.yml -f docker-compose.secrets.yml up -d seaweedfs`（同一 volume で recreate）。
   healthy 後、既存オブジェクトを S3 GetObject（または `weed shell` の `fs.cat`）して**復号・平文一致を確認**。
5. 問題があれば image タグ＋digest を旧版へ revert（`git checkout docker-compose.yml`）→ 再度 `up -d seaweedfs`。

**非互換を観測した場合のフォールバック（major 跨ぎ等）**：新版が `/data` を新形式へ書き換え、旧版が読めなく
なるケースでは、旧版 image へ revert したうえで**アップグレード前の物理 tar を `restore.sh full` で吸収**します
（SeaweedFS では論理 dump が無いぶん、**物理バックアップが切戻しの正当な手段**＝PostgreSQL/Keycloak の
「論理で足り物理不要」とは結論が異なります）。

> ⚠ **メジャー跨ぎ（例 4.x→5.x）は on-disk 形式が非互換になりうるため未検証**です。実証済みは同一メジャー内
> minor 跨ぎ（4.22↔4.29）のみ。どのアップグレードでも**手順 1 の事前 `backup.sh full` を必ず取得**し、
> 新版起動後に既存オブジェクトの復号確認を行ってから本番運用に戻してください。

### 3-3. 災害復旧（PC 故障／ストレージ障害／ランサムウェア）

外部メディアまたはオフサイトストレージからの復旧。**新しい環境（別 secrets）で実機検証済み**（4-3、2026-05-30）。

> **鍵は「`secrets/` を外部の鍵管理ストレージ（パスワードマネージャ／別 NAS 等）にもバックアップしておく」
> ことです**（§4 参照）。`secrets/` を復元できれば、復旧は通常リストア（3-1）と同じで
> **パスワード整合作業は一切不要**です。

#### 正手順（`secrets/` を外部保管から復元できる場合）

1. 新しい PC で WSL2（または Linux）＋ Docker Engine をセットアップ
2. genai-deploy-onpre リポジトリを clone
3. **`secrets/` を外部保管から復元**（この場合 `gen-secrets.sh` は実行しない）
4. `docker compose build postgres` で postgres カスタムイメージをビルド
5. `docker compose -f docker-compose.yml -f docker-compose.secrets.yml up -d` で起動
6. オフサイトから backup ファイル群を取り寄せ
7. `./scripts/restore.sh full <postgres.dump> <keycloak_db.dump> <seaweedfs.tar.gz>` で復元
8. healthy 確認（app 層の自動 restart はスクリプト内で完了済み）

復元元と同じ `secrets/` で起動するため、業務 DB・認証 DB・SeaweedFS・Keycloak client/admin の
**すべての資格情報が backup と一致**します。**追加の整合作業は不要**です（実機確認済み）。

#### フォールバック（`secrets/` も失った二重障害時のみ）

外部保管の `secrets/` も失った場合に限り、`gen-secrets.sh` で新しい secrets を生成して復旧します。
このとき **Keycloak の資格情報だけ**整合が必要です（理由は下表）。

1〜2. 上と同じ
3. `./scripts/gen-secrets.sh` で secrets を**新規生成**
4〜7. 上と同じ（build → up -d → backup 取り寄せ → `restore.sh full`）
8. **`./scripts/dr-keycloak-reconcile.sh`** を実行（Keycloak の client secret と seed admin パスワードを
   新 secrets に整合。一時 admin を内部で発行・処理後に自動削除）
9. 整合確認：

```bash
# コンテナが healthy か確認
docker compose -f docker-compose.yml -f docker-compose.secrets.yml ps
```

- ブラウザで web にログインし、チャットが応答すること（Keycloak client_secret 整合の確認）。
- ファイルのアップロード・参照ができること（S3 健全の確認）。

**どの資格情報が整合を要するか（4-3 実機で確定、2026-05-30）**：

| 資格情報 | 復元後の状態 | 整合 |
|---|---|---|
| PostgreSQL ロール PW（業務 DB／認証 DB） | 新環境の `initdb` が新 PW でロールを作成。論理 dump（`pg_dump -F custom` の単一 DB）は **ロール（`pg_authid` の PW）を含まない**ため復元はスキーマ＋データのみ。アプリも新 PW で接続するため整合する。 | **不要** |
| SeaweedFS S3 creds（accessKey/secretKey） | バケットはアクセス creds 非依存。暗号鍵は復元した filer メタ由来のため、**新 creds でも復元オブジェクトを復号・取得できる**（実機 GetObject で確認）。 | **不要** |
| Keycloak: `genai-ai-api-admin` client secret | backup の keycloak_db で**上書き**され backup 時の値に戻る。api は新 secret を使うため client_credentials が **401** になる（api↔Keycloak Admin REST が機能不全）。 | **必要** |
| Keycloak: `genai-realm` seed admin（`admin`）の PW | 同上で backup 時 PW に戻り、新 PW で login できない。 | **必要** |
| Keycloak: master realm bootstrap admin の PW | 同上で backup 時 PW に戻る。`dr-keycloak-reconcile.sh` は一時 admin を発行して上 2 件を整合するが、master admin 自体の PW は必要なら別途 Admin Console / kcadm で再設定する。 | （任意） |

> `dr-keycloak-reconcile.sh` は、復元で master realm の admin も backup 時 PW に戻って Admin Console に
> 入れなくなる「鶏卵」を、Keycloak 26 の `kc.sh bootstrap-admin user`（一時 admin 発行）で解きます。
> 起動中コンテナとの port 衝突を避けるため一時 admin の発行は別ワンオフコンテナで行い、整合後に削除します。

---

## 4. 鍵管理／secrets 取扱い

| 対象 | 保管 | バックアップ |
|---|---|---|
| `secrets/postgres_password` 等の 5 つの秘密値 | `secrets/` 配下（mode 644／親ディレクトリ 700） | **外部の鍵管理ストレージで別管理**（本スクリプトの対象外） |
| `secrets/s3.config.json` 等のテンプレ展開実体 | `secrets/` 配下（`gen-secrets.sh` で再生成可能） | バックアップ不要（再生成できる） |
| SeaweedFS 暗号化鍵 | filer メタデータ内（`/data/filerldb2/`） | `backup.sh full` で volume データと同一時点取得 |
| ホスト FS／ディスク暗号化鍵（BitLocker／LUKS／dm-crypt） | OS／利用者側で別途管理 | Recovery Key は **オフラインで別保管必須** |

**重要**：DB ダンプ／tar gz は平文の業務データを含みます。ホスト FS 暗号化の保護下に置き、
オフサイト送信時は転送経路を暗号化（SSH／TLS）してください。

**災害復旧との関係**：`secrets/` を外部の鍵管理ストレージにバックアップしておくと、災害復旧（3-3）で
それを復元するだけでパスワード整合作業が不要になります。逆に `secrets/` を失うと、Keycloak の
資格情報だけ `dr-keycloak-reconcile.sh` での整合が必要になります（3-3 参照）。`secrets/` の外部保管を
強く推奨します。

---

## 5. 免責

- 本配布物は無保証で提供されます。バックアップ・リストアの実施・検証は利用者責任です。
- OSS のメジャーバージョンアップに伴うデータ非互換による損失は責任を負いません。
- 実際のダウンタイム（特に SeaweedFS 物理バックアップ）は環境・データ量に依存します。本ドキュメント
  の目安値は参考情報です。
- 災害復旧のためのオフサイトバックアップの取得・媒体管理は利用者責任です。

---

## 参考

- SeaweedFS Wiki: Filer Data Encryption — https://github.com/seaweedfs/seaweedfs/wiki/Filer-Data-Encryption
- PostgreSQL `pg_dump` — https://www.postgresql.org/docs/16/app-pgdump.html
- PostgreSQL `pg_restore` — https://www.postgresql.org/docs/16/app-pgrestore.html
- PostgreSQL Encryption Options — https://www.postgresql.org/docs/16/encryption-options.html
