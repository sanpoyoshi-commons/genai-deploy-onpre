# LICENSES-THIRD-PARTY

本ディレクトリは、`genai-deploy-onpre` の `docker-compose.yml` が起動する同梱 OSS
（コンテナイメージ）の第三者ライセンスを集約・保全します（CLAUDE.md §6）。

本配布物は各 OSS の**ソースコードを再配布せず**、公開レジストリから**コンテナイメージを
取得して起動**します。本ディレクトリは、各 OSS の**上流が配布する LICENSE / NOTICE
ファイルを逐語のまま保全**し、ライセンス種別・権利者・上流 authoritative 出典を明示します。

## 回収方針

各 OSS の LICENSE / NOTICE は、`scripts/fetch-third-party-licenses.sh` により
**固定バージョンのタグから逐語（raw バイト列）で回収**しました（初回 2026-05-25、
再 pin 追従の再回収 2026-07-06）。全 LICENSE は version タグからの取得に成功し、
`main`/`master` へのフォールバックは発生していません（固定版との本文ズレ無し）。

ファイル名規約：
- `<OSS>_<SPDX>.txt` — 上流の LICENSE 本文（逐語）
- `<OSS>-NOTICE.txt` — 上流の NOTICE 本文（逐語、配布している OSS のみ）

## 同梱 OSS 一覧（digest は 2026-05-25 一次取得、2026-06-20 の CVE 対応再 pin を 2026-07-06 反映、2026-07-12 定期棚卸し再 pin を反映）

| OSS | バージョン | イメージ@digest | SPDX | 保全ファイル | 回収元タグ |
|---|---|---|---|---|---|
| PostgreSQL | 16.14 | `postgres:16.14-alpine@sha256:e013e867…5a28cb`（keycloak-db）/ pgvector 同梱（業務 DB） | PostgreSQL | [`PostgreSQL_PostgreSQL-License.txt`](./PostgreSQL_PostgreSQL-License.txt) | `REL_16_14`（COPYRIGHT） |
| pgvector | 0.8.5 | `pgvector/pgvector:0.8.5-pg16@sha256:1d533553…79f0fb` | PostgreSQL | [`pgvector_PostgreSQL-License.txt`](./pgvector_PostgreSQL-License.txt) | `v0.8.5` |
| pg_bigm | v1.2-20250903 | postgres カスタムビルドで導入（`postgres/Dockerfile` でソースビルド） | PostgreSQL | [`pg_bigm_PostgreSQL-License.txt`](./pg_bigm_PostgreSQL-License.txt) | `v1.2-20250903` |
| Keycloak | 26.6.4 | `quay.io/keycloak/keycloak:26.6.4@sha256:0aae0de7…8cbce4` | Apache-2.0 | [`Keycloak_Apache-2.0.txt`](./Keycloak_Apache-2.0.txt) | `26.6.4` |
| SeaweedFS | 4.39 | `chrislusf/seaweedfs:4.39@sha256:c7d6c721…3c12c6` | Apache-2.0 | [`SeaweedFS_Apache-2.0.txt`](./SeaweedFS_Apache-2.0.txt) | `4.39` |
| ElasticMQ | v1.7.1 | `softwaremill/elasticmq:1.7.1@sha256:f1de391a…69da82` | Apache-2.0 | [`ElasticMQ_Apache-2.0.txt`](./ElasticMQ_Apache-2.0.txt) / [`ElasticMQ-NOTICE.txt`](./ElasticMQ-NOTICE.txt) | `v1.7.1`（`LICENSE.txt`＋NOTICE） |
| Ollama | v0.31.2 | `ollama/ollama:0.31.2@sha256:509fdf54…c62c0a` | MIT | [`Ollama_MIT.txt`](./Ollama_MIT.txt) | `v0.31.2` |
| Text Embeddings Inference (TEI) | v1.9.3 (cpu) | `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.3@sha256:ad950d30…1fea07` | Apache-2.0 | [`TEI_Apache-2.0.txt`](./TEI_Apache-2.0.txt) | `v1.9.3` |
| nginx | 1.30.3 stable | `nginx:1.30.3-alpine3.23@sha256:1bbb1c7e…c675e4` | BSD-2-Clause | [`nginx_BSD-2-Clause.txt`](./nginx_BSD-2-Clause.txt) | `release-1.30.3` |
| Mailpit | v1.30.4 | `axllent/mailpit:v1.30.4@sha256:5a49a77c…82d4f6` | MIT | [`Mailpit_MIT.txt`](./Mailpit_MIT.txt) | `v1.30.4` |
| Dozzle | v10.6.9 | `amir20/dozzle:v10.6.9@sha256:6f464481…65866b` | MIT | [`Dozzle_MIT.txt`](./Dozzle_MIT.txt) | `v10.6.9` |
| speaches | 0.8.3 (cpu) | `ghcr.io/speaches-ai/speaches:0.8.3-cpu@sha256:21e3df06…f53ef8` | MIT | [`speaches_MIT.txt`](./speaches_MIT.txt) | `v0.8.3` |
| Node.js | v24.15.0 LTS | （api リポ自前ビルドのベースイメージ `node:24.15.0-alpine`） | Node.js（MIT 系） | [`Node.js_MIT.txt`](./Node.js_MIT.txt) | `v24.15.0` |

> **注（2026-07-06）**：2026-06-20 の CVE 対応でイメージタグ・digest を再 pin し（上表の
> バージョン・digest 列に反映済み）、`scripts/fetch-third-party-licenses.sh` を新タグへ更新して
> **2026-07-06 に全ライセンス本文を再回収した**（全件 version タグから取得成功・main/master
> フォールバックなし）。再回収の結果、**既存の全ライセンス本文は旧タグ版とバイト単位で同一**
> （版間で本文不変を実確認）。NOTICE の上流不存在（Keycloak／SeaweedFS／TEI／vLLM／NsJail）も
> 新タグで再確認済み（取得時 404）。speaches（profile: transcribe、STT エンジン faster-whisper
> 〔MIT〕同梱・Whisper モデルは運用者が実行時 pull）は 2026-07-06 に追加・逐語回収済。

> **注（2026-07-12）**：定期棚卸しで再 pin（Keycloak 26.6.4〔CVE-2026-11800 認証バイパス等
> セキュリティ修正 8 件〕／SeaweedFS 4.39／Ollama v0.31.2／Mailpit v1.30.4／Dozzle v10.6.9／
> pgvector 0.8.5）。上表のバージョン・digest・回収元タグ列と
> `scripts/fetch-third-party-licenses.sh` の取得タグに反映済み。NOTICE の上流不存在
> （Keycloak 26.6.4／SeaweedFS 4.39）は新タグで再確認済み（NOTICE／NOTICE.txt とも 404）。
> ライセンス本文は同スクリプトを 2026-07-12 に再実行して新タグから再回収済み（全件 version
> タグから取得成功・main/master フォールバックなし）。**全ライセンス本文は旧タグ版と
> バイト単位で同一**（版間で本文不変を実確認）。

`Node.js_MIT.txt` は Node.js 本体（MIT）に加え、同梱される第三者コンポーネント
（V8 / ICU / OpenSSL 等）のライセンスを上流 LICENSE がそのまま列挙しているため大容量です。

### 任意・既定構成外
| OSS | バージョン | SPDX | 保全ファイル | 備考 |
|---|---|---|---|---|
| vLLM | v0.21.0 | Apache-2.0 | [`vLLM_Apache-2.0.txt`](./vLLM_Apache-2.0.txt) | GPU 前提のため既定構成から除外。将来オプションとして追加する際に再掲。本文は参考として保全。 |

## web フロントエンド（ソースからローカルビルド・本リポジトリには同梱しない）

上記の同梱 OSS は**コンテナイメージを pull して起動**するのみでソース／バイナリを再配布
しません。web フロントエンドも**本リポジトリにはビルド済み成果物を同梱せず**、利用者環境で
姉妹リポジトリ `genai-web-onpre` のソースから `scripts/build-web.sh` でビルドし、nginx が配信
します（ビルド出力先 `web/` は `.gitignore` 対象で再配布物に含まれません）。本配布物が起動する
スタックの一部としてこのフロントエンドを配信するため、その著作権・許諾表示を保全します。

| 項目 | 内容 |
|---|---|
| コンポーネント | web フロントエンド（`genai-web-onpre` からビルド・nginx が配信） |
| 由来 | genai-web（MIT License, Copyright (c) 2026 Rifu.Sakamoto） |
| 上流 | digital-go-jp/genai-web（v1.0.3 由来の派生。詳細は姉妹リポ genai-web-onpre の UPSTREAM.md） |
| ライセンス本文 | [`genai-web_MIT.txt`](./genai-web_MIT.txt) |
| 第三者表記 | [`genai-web_THIRD-PARTY-NOTICES.txt`](./genai-web_THIRD-PARTY-NOTICES.txt)（ビルド時にバンドルされる npm 依存＝@aws-amplify〔Apache-2.0〕・多数の MIT/BSD ライブラリ等の権利表記を逐語保全） |

**位置づけの明記**：本リポジトリは web のビルド済み成果物を再配布しません（`web/` は
`.gitignore` 対象のローカルビルド出力）。ただし利用者がビルドして配信するフロントエンドには
MIT／第三者ライセンスの**帰属義務が及ぶ**ため、その表示を上記 2 ファイルで保全しています。
再配布形態の最終的な扱い（保全をこのリポジトリに置くか `genai-web-onpre` 側へ寄せるか）は
**別途の法務確認で確定**します。

## NOTICE 回収結果（Apache-2.0 §4(d) 関連）

Apache-2.0 §4(d) の NOTICE 同梱義務は、本来「Work または Derivative Works を**再配布**する者」に
課されます。本配布物はコンテナイメージを pull して起動するのみで OSS のソース／バイナリを
再配布しないため、当該義務は直接は生じない可能性が高いと考えられます（最終的な法的判断は
別途の法務確認によります）。それでも透明性のため、上流が NOTICE を配布している OSS は逐語保全しました。

| OSS | NOTICE | 結果 |
|---|---|---|
| ElasticMQ | あり | [`ElasticMQ-NOTICE.txt`](./ElasticMQ-NOTICE.txt) 逐語保全 |
| Keycloak | なし | 上流タグ `26.6.4` に NOTICE ファイル無し（取得時 404 で確認・2026-07-12 再確認） |
| SeaweedFS | なし | 上流タグ `4.39` に NOTICE ファイル無し（同上） |
| TEI | なし | 上流タグ `v1.9.3` に NOTICE ファイル無し（同上） |
| vLLM | なし | 上流タグ `v0.21.0` に NOTICE ファイル無し（同上） |
| NsJail | なし | 固定 SHA `079d70dd…` のリポルートに NOTICE ファイル無し（GitHub contents API で確認・2026-06-02）。自前ビルドで同梱するが NOTICE 不存在のため §4(d) 義務は発生しない |

## ElasticMQ の LICENSE ファイルについて（注記・2026-06-02 訂正）

ElasticMQ（softwaremill/elasticmq）の LICENSE は上流タグ `v1.7.1` に **`LICENSE.txt` として存在**し、
[`ElasticMQ_Apache-2.0.txt`](./ElasticMQ_Apache-2.0.txt) は**そこから逐語回収**した標準 Apache License 2.0
本文（201 行）です。NOTICE も同梱されています（[`ElasticMQ-NOTICE.txt`](./ElasticMQ-NOTICE.txt)）。

> **自己訂正**：旧記載は「上流に標準 LICENSE ファイル同梱なし（404 確認）→ canonical 標準本文を供給」と
> していたが、これは誤りだった。初回 `scripts/fetch-third-party-licenses.sh` が拡張子なしの `LICENSE`／
> `master/LICENSE` のみを試行し、実ファイル名 `LICENSE.txt` を取りこぼしていたための誤検出。実ファイル名を
> GitHub contents API で特定し（`v1.7.1` ルートに `LICENSE.txt`）、逐語回収に訂正した。本文は標準 Apache-2.0
> （Keycloak 同梱版と同一・md5 `3b83ef96…`）だが、出所は**上流リポの逐語ファイル**である。
> スクリプトの該当行も `LICENSE.txt` を候補に追加済み。

## embedding モデルのライセンス

TEI が serving する embedding モデル `cl-nagoya/ruri-v3-310m`（ModernBERT ベース、Apache-2.0）の
ライセンスを本ディレクトリに保全しました。ソフトウェア TEI とモデルウェイトは別ライセンス層
である点に留意（TEI 自体は [`TEI_Apache-2.0.txt`](./TEI_Apache-2.0.txt)）。

| 項目 | 内容 |
|---|---|
| モデル | `cl-nagoya/ruri-v3-310m`（cl-nagoya、ModernBERT ベース、768 次元） |
| SPDX | Apache-2.0（一次出典 huggingface.co） |
| 上流 | Hugging Face `https://huggingface.co/cl-nagoya/ruri-v3-310m` |
| 保全ファイル | [`ruri-v3-310m_Apache-2.0.txt`](./ruri-v3-310m_Apache-2.0.txt) |
| 配布形態 | **モデルウェイトは同梱せず**、TEI が初回起動時に Hugging Face から DL（オンライン自動 DL）。本配布物はモデルを再配布しない |

**標準本文供給の明記**：[`ruri-v3-310m_Apache-2.0.txt`](./ruri-v3-310m_Apache-2.0.txt) は
**標準 Apache License 2.0 本文**（canonical、md5 `3b83ef96…`）を供給したものであり、モデルカードからの
逐語回収ではありません。モデルウェイトは再配布しない（ランタイム DL）ため、Apache-2.0 §4(d) の
NOTICE 同梱義務は直接 trigger しない可能性が高い（上記「NOTICE 回収結果」と同じ整理）。モデルカード
記載の追加 NOTICE／帰属の逐語確認が必要な場合は、外部公開直前に Hugging Face から取得して追補できます
（`scripts/fetch-third-party-licenses.sh` と同方式）。

## chat LLM モデルのライセンス（ハードウェア階層別メニュー、運用者 pull・再配布なし）

chat LLM（ollama）の重みは**配布物に同梱せず**、運用者が選んで実行時に pull します
（README「chat LLM モデルの選定」参照）。embedding モデルと同じく**モデルウェイトは再配布しない**
ため、各ライセンスの再配布起因義務は直接 trigger しない可能性が高い（上記「NOTICE 回収結果」と同じ整理）。
本メニューは**ライセンス清潔度（寛容な OSS ライセンス・再配布容易性）**を基準に選定しています（序列：Apache-2.0 ◎ ＞ Llama 系 ○）。

| 階層 | モデル（ollama タグ） | SPDX / ライセンス | 一次出典 | 保全 |
|---|---|---|---|---|
| 軽量 | `mistral:7b` | Apache-2.0 | huggingface.co/mistralai | 標準 Apache-2.0 本文（既存・canonical）を適用 |
| 軽量 | `llama3.2:3b` | Llama 3.2 Community License | llama.com/llama3_2/license | **要逐語取得**（下記） |
| 軽量／中量／大型 | `gemma4:e2b` / `e4b` / `26b` / `31b` | **Apache-2.0**（Gemma 4・2026-04〜） | ai.google.dev/gemma | 標準 Apache-2.0 本文（既存・canonical）を適用 |
| 日本語8B | ELYZA-JP Llama 3 8B（HF/コミュニティ） | Meta Llama 3 Community License | huggingface.co/elyza | **要逐語取得**（下記） |
| 日本語8B | Llama 3.x Swallow 8B（コミュニティ） | Meta Llama 3.x Community License（3.1/3.3 は Gemma 利用規約の Use Restriction 継承） | swallow-llm.github.io | **要逐語取得**（下記） |
| 大型 | `mixtral` | Apache-2.0 | huggingface.co/mistralai | 標準 Apache-2.0 本文（既存・canonical）を適用 |
| 大型 | `llama3.3:70b` | Llama 3.3 Community License | llama.com/llama3_3/license | **要逐語取得**（下記） |

**Apache-2.0 モデル**（Mistral 系・Gemma 4・Mixtral）：再配布しないため、既存の標準 Apache License 2.0
本文（canonical、md5 `3b83ef96…`、例 [`ruri-v3-310m_Apache-2.0.txt`](./ruri-v3-310m_Apache-2.0.txt)）が
そのまま適用されます。Gemma は **Gemma 3 までは独自「Gemma 利用規約」だが Gemma 4（2026-04）で
Apache-2.0 へ移行**した点に注意（本メニューは Gemma **4** を採用）。

**Llama 系モデル**（Llama 3.2/3.3・ELYZA・Swallow）：**Meta Llama Community License** に従う限り
商用利用可（月間アクティブユーザ 7 億未満）。標準 Apache-2.0 と異なる**モデル固有ライセンス本文**
のため、本ディレクトリには未保全です。

> **補足**：Llama Community License（3.2/3.3）本文の逐語保全、および ELYZA／Swallow が依拠する
> Llama 利用規約・AUP・Swallow（Llama 3.1/3.3 系）の Gemma 利用規約の Use Restriction 継承に関する
> 法的評価は、別途の法務確認に委ねます。本節は SPDX・一次出典の確認までを記録したものです。

## 画像生成サーバ sdcpp（profile: image・自前ビルド）

`profile image` の画像生成サーバ（`sdcpp/Dockerfile`）は、sandbox / postgres と同じく
**利用者環境で Dockerfile からビルド**して使う（ビルド済みイメージを本リポが再配布するわけではない）。
ビルドされる `sd-server` バイナリは leejet/stable-diffusion.cpp 由来のため、ライセンス・帰属を保全する。

| コンポーネント | バージョン | SPDX / ライセンス | 配布形態 | 一次出典 | 保全ファイル |
|---|---|---|---|---|---|
| stable-diffusion.cpp | 固定 SHA `92dc7268…`（2026-05-26 時点 master） | MIT（Copyright (c) 2023 leejet） | Dockerfile で自前ビルド・イメージに同梱 | github.com/leejet/stable-diffusion.cpp | [`stable-diffusion.cpp_MIT.txt`](./stable-diffusion.cpp_MIT.txt) 逐語回収済（固定 SHA・2026-07-06） |

画像生成モデル（SD1.5 等）は**同梱せず**、運用者が `sdcpp/models/` に任意配置する
（モデルウェイトは再配布しない。各モデルのライセンスは配布元の条件に従う）。

## Code Interpreter サンドボックス同梱コンポーネント（profile: sandbox・自前ビルド）

`profile sandbox` の Python サンドボックス（`sandbox/Dockerfile`）は、sdcpp / postgres と同じく
**利用者環境で Dockerfile からビルド**して使う（ビルド済みイメージを本リポが再配布するわけではない）。
ただしイメージには NsJail バイナリ・日本語フォント・Python 分析ライブラリが**同梱**されるため、各々の
ライセンス・帰属を保全する。HTTP wrapper（`sandbox/server.py`）は標準ライブラリのみで第三者コードを含まない
（snekbox は**設計参考のみ・コード非流用**＝再配布物なし）。

| コンポーネント | バージョン | SPDX / ライセンス | 配布形態 | 一次出典 | 保全ファイル |
|---|---|---|---|---|---|
| NsJail | 固定 SHA `079d70dd…`（タグ 3.4） | Apache-2.0 | Dockerfile で自前ビルド・イメージに同梱 | github.com/google/nsjail | [`NsJail_Apache-2.0.txt`](./NsJail_Apache-2.0.txt) 逐語回収済（固定 SHA） |
| IPAex Gothic | （fonts-ipaexfont-gothic） | IPA Font License v1.0 | apt パッケージ・イメージに同梱 | moji.or.jp/ipafont | [`IPAexGothic_IPA-Font-License.txt`](./IPAexGothic_IPA-Font-License.txt) 抽出済（イメージ内 copyright・347 行） |
| pandas | 2.2.3 | BSD-3-Clause | pip・イメージに同梱 | github.com/pandas-dev/pandas | [`pandas_BSD-3-Clause.txt`](./pandas_BSD-3-Clause.txt) 逐語回収済（`v2.2.3`） |
| NumPy | 2.2.1 | BSD-3-Clause | pip・イメージに同梱 | github.com/numpy/numpy | [`NumPy_BSD-3-Clause.txt`](./NumPy_BSD-3-Clause.txt) 逐語回収済（`v2.2.1`） |
| matplotlib | 3.10.0 | matplotlib License（PSF/BSD 系・要文面確認） | pip・イメージに同梱 | github.com/matplotlib/matplotlib | [`matplotlib_License.txt`](./matplotlib_License.txt) 逐語回収済（`v3.10.0`） |
| openpyxl | 3.1.5 | MIT | pip・イメージに同梱 | foss.heptapod.net/openpyxl | [`openpyxl_MIT.txt`](./openpyxl_MIT.txt) 逐語回収済（`3.1.5`） |
| Python | 3.13（slim ベース） | PSF License | ベースイメージ同梱 | github.com/python/cpython | [`Python_PSF.txt`](./Python_PSF.txt) 逐語回収済（`3.13`） |

**回収完了（2026-06-02）**：上記は `scripts/fetch-third-party-licenses.sh`（curl 可能端末で運用者が手動実行）で
逐語回収済。NsJail は Dockerfile の `ARG NSJAIL_REF` と一致する**固定 SHA** から取得し再現性を担保。IPA Font
License はビルド済みイメージ内 `/usr/share/doc/fonts-ipaexfont-gothic/copyright`（authoritative）から抽出した
（IPA Font License v1.0 全文＋`.ttf` の `License: IPA-1` 表示を含む。`debian/*` のパッケージング部のみ GPL-3+）。

> **法務確認に向けた整理（回収後の更新・2026-06-02）**：
> 1. **NsJail（Apache-2.0）NOTICE は上流に不存在を確認**（固定 SHA のリポルートに NOTICE ファイル無し）。
>    Apache-2.0 §4(d) の NOTICE 同梱義務は「NOTICE が存在する場合」に課されるため、**NsJail については当該義務が
>    そもそも発生しない**（LICENSE 本文は逐語保全済）。→ **本項目は解消**。
> 2. **IPA Font License v1.0**：全文を保全済（再配布時の固有条項＝改変フォントの命名制限・同一ライセンス継承・
>    販売制限等の条項適合判断は、配布形態に依存する。**ソース配布限定**〔利用者が手元でイメージをビルド〕なら
>    フォントを再頒布するのは利用者のローカルビルドで本リポではない、という整理が立つ。**ビルド済みイメージを
>    配布する場合は条項適合の確認が必要**）。
> 3. snekbox（MIT）は**設計参考のみでコード非流用**＝再配布物なしの認識。流用が生じた場合は MIT 本文保全＋帰属を追加。
>
> **総括**：formal な法務レビューが要るかは「配布形態（ソース限定 or ビルド済みイメージ）」に帰着する。
> ソース配布限定＋`DISCLAIMER.md`（個人開発・実験用途・無保証）前提なら、上記 1〜3 はいずれも本リポに直接の
> 再配布義務を課さない整理で閉じられる（最終判断は運用者）。
