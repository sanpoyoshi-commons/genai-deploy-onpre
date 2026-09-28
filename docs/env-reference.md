# 環境変数リファレンス（.env / docker-compose）

`docker compose up -d` は **すべての設定に既定値**を持つため、`.env` は機密値だけ変えれば動きます。
本書は「何を弄れるか」を用途別にまとめた一覧です。各値は `docker-compose.yml` の
`${VAR:-default}` と一致しています（`.env` に書かなければ既定で動作）。

- 機密値（パスワード・API キー・暗号鍵）は `.env` 直書きより **docker secrets 推奨**（[セキュリティハードニング](#12-機密値と-secrets)）。
- `.env.example` をコピーして `.env` を作成します：`cp .env.example .env`（編集は手動）。
- 機能の ON/OFF は基本 `COMPOSE_PROFILES`（[§8](#8-機能トグルprofile)）。個別 env は微調整用です。

---

## 1. ネットワーク / 公開ポート

| 変数 | 既定 | 説明 |
|---|---|---|
| `HTTP_BIND` | `127.0.0.1` | 全公開ポートの bind アドレス。LAN 公開時は実 IP（例 `192.168.x.x`）に。 |
| `HTTP_PORT` / `HTTPS_PORT` | `80` / `443` | nginx の HTTP / HTTPS。 |
| `S3_PORT` | `8443` | SeaweedFS(S3) 公開ポート。`S3_PUBLIC_ENDPOINT` の `:port` と一致させる。 |
| `KEYCLOAK_HTTP_PORT` | `8088` | Keycloak 管理コンソール（localhost のみ）。 |
| `MAILPIT_UI_PORT` | `8025` | Mailpit Web UI。 |
| `DOZZLE_PORT` | `9980` | Dozzle ログ閲覧 UI。 |
| `LOG_LEVEL` | `info` | api / worker のログレベル。 |

## 2. 認証（Keycloak）

| 変数 | 既定 | 説明 |
|---|---|---|
| `KEYCLOAK_HOSTNAME` | `https://localhost/auth` | 外部到達ホスト名。**変更時は `KEYCLOAK_ISSUER` も連動**（token の `iss` と一致が必要）。 |
| `KEYCLOAK_ADMIN` | `admin` | ブートストラップ管理者ユーザー名。 |
| `KEYCLOAK_ISSUER` | `https://localhost/auth/realms/genai-realm` | JWT 検証の issuer。通常は `KEYCLOAK_HOSTNAME` に合わせる（内部既定で十分）。 |
| `KEYCLOAK_JWKS_URI` / `KEYCLOAK_AUDIENCE` | コンテナ内部既定 | JWKS 取得 URL / 受け入れ aud。通常変更不要。 |
| `KEYCLOAK_ADMIN_BASE_URL` / `_REALM` / `_CLIENT_ID` | 内部既定 | Admin REST 連携（teams CRUD）。非秘密の固定値。 |

> `KEYCLOAK_ADMIN_PASSWORD` / `KEYCLOAK_DB_PASSWORD` / `KEYCLOAK_ADMIN_CLIENT_SECRET` は機密 → [§12](#12-機密値と-secrets)。

## 3. 業務 DB（PostgreSQL）

| 変数 | 既定 | 説明 |
|---|---|---|
| `POSTGRES_DB` / `POSTGRES_USER` | `genai` / `genai` | DB 名・ユーザー。 |
| `POSTGRES_PASSWORD` | （必須） | 機密 → [§12](#12-機密値と-secrets)。`DATABASE_URL` はこの値から自動組み立て（直接書かない）。 |

## 4. LLM（チャット / 生成）

| 変数 | 既定 | 説明 |
|---|---|---|
| `LLM_BACKEND` | `ollama` | **経路選択の主役**。`ollama`(ローカル) / `vllm` / `openai` / `anthropic` / `gemini` / `bedrock`。 |
| `LLM_DEFAULT_MODEL` | `gemma4:e2b` | リクエスト未指定時の既定モデル（空なら `MODEL_IDS[0]`）。 |
| `LLM_DEFAULT_TIMEOUT_MS` | `1800000` | 推論タイムアウト（30 分）。CPU 推論で重いモデル/大きいプロンプトが完走できるよう長め。api 起動時に undici(fetch) の既定 300s も本値へ揃える。nginx `proxy_read_timeout` とも整合させる（短い方が律速）。 |
| `LLM_DEFAULT_TEMPERATURE` | 空 | 既定サンプリング温度（0〜2）。空＝バックエンド既定（ollama OpenAI 互換は 1.0）。リクエストが温度を指定しない全 chat に効く既定値。**ダイアグラム生成は web が個別に低温（0.2）を送る**ため本値の設定は不要（diagram 用途では本値より優先される）。 |
| `MODEL_IDS` | JSON 配列 | web セレクタ＋api 許可リスト（単一の真実）。変更は nginx/api 再起動で反映。 |
| `OLLAMA_BASE_URL` | `http://ollama:11434/v1` | 同梱 ollama を指す。外部 ollama 利用時のみ変更。 |
| `OLLAMA_DEFAULT_CHAT_MODEL` | `gemma4:e2b` | ollama 経路の既定モデル。 |
| `OLLAMA_CONTEXT_LENGTH` | `8192` | ollama の既定 context 長（トークン）。ollama 自身の既定は 4096 だが、本構成は **8192** を既定にする：4096 ではダイアグラム生成のプロンプト（〜7.3千トークン）が切り詰められて図が出ず（[operations.md](operations.md#ダイアグラム生成フローチャート等の設定と前提) の実機検証。CPU・11GB 級でも 8192 で描画成功）、チャットの添付から取り出した文字のための余白もほとんど残らないため（既定の上限 5000 字は `gemma4:e2b` で約 2800 トークン。4096 ではこれが文脈の大半を占め、会話と答えの余白が足りずに切り詰められるおそれがある）。KV キャッシュの分メモリを使うので、さらに小さい機械では `4096` に下げてよい（そのときは `ATTACHMENT_MAX_CHARS` / `ATTACHMENT_TOTAL_MAX_CHARS` も下げる）。api の判定ルートはこの値を切り詰め検知の基準に使う。 |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | ollama が同時常駐するモデル数の上限。既定 1（低 RAM 単一ボックス向け）。1 なら新モデルのロード時に旧モデルを自動アンロードするため、セレクタでモデルを切り替えても二重常駐で OOM/スワップ枯渇しない。RAM に余裕（16GB+）があれば 2 以上に上げてよい。 |

クラウド / vLLM / Bedrock の API キー・モデル・region は `.env.example` のコメント参照（キーは機密＝既定空）。

### 判定（`POST /api/judge`・`--profile llm`）

> フロー分岐のための判定ルート。問い（選択肢・段階）を渡すと、モデルが返す **1 トークン目の確率分布**から
> 答えと確からしさ（`confidence`）を返す。判定定義（問い・閾値）は呼び出し側が持ち、api は状態を持たない。
> ollama の OpenAI 互換 API は logprobs を返さないため、このルートだけ**ネイティブ `/api/chat`** を叩く。
> **判定結果を「許可」の根拠に使わないこと**（認可は Keycloak／`requireAuth` が担う。判定は確率的な材料）。

| 変数 | 既定 | 説明 |
|---|---|---|
| `JUDGE_OLLAMA_URL` | `http://ollama:11434` | ネイティブ API のベース URL（**`/v1` を付けない**。`OLLAMA_BASE_URL` とは別物）。 |
| `JUDGE_DEFAULT_MODEL` | 空 | 判定モデル。空なら `OLLAMA_DEFAULT_CHAT_MODEL` へ委譲。**既定チャットモデルと同一にする**（`OLLAMA_MAX_LOADED_MODELS=1` だとモデルが入れ替わり、ロード待ちとプロンプトキャッシュ消失が起きる）。両方とも空ならこのルートだけ 503。 |
| `JUDGE_ALLOWED_MODELS` | 空 | 判定に使ってよいモデル（カンマ区切り）。空＝既定モデルのみ許可（素通しにはしない）。許可外の指定は 400。 |
| `JUDGE_CONTEXT_LENGTH` | 空 | 切り詰め検知の基準。空なら `OLLAMA_CONTEXT_LENGTH` に追従する。**実設定より大きくしないこと**（黙って切り詰められた入力で判定してしまう）。 |
| `JUDGE_MAX_STATE_BYTES` | `8192` | 判定対象 `state` の上限バイト数（超過は 400）。 |
| `JUDGE_ATTEMPT_TIMEOUT_MS` | `300000` | 上流呼び出し **1 回**（fetch 1 回）のタイムアウト。既定 300 秒は実測に基づく（2026-09-22 実機・本番経路のコールドスタート 6 回）。**端から端までの最大 166.13 秒は単一試行の所要ではない**＝150 秒で 1 回目が打ち切られ、約 15 秒の再試行が成功した合計値（6 回中 2 回がこの形）。**単一試行の最悪は約 153 秒と推定**＝モデル読み込み 139.34 秒＋プロンプト処理 約 14 秒で、300 秒の安全率は約 2.0。**短くするとコールドスタートが必ず落ちる**。 |
| `JUDGE_REQUEST_BUDGET_MS` | `600000` | リクエスト**全体**（全問・リトライ・待機込み）の予算。超過は 504。問いは逐次に処理するため、これが全体の上限になる。既定 600 秒：180 秒では、コールドスタート 1 問が再試行込みで 166 秒かかった実測に対し 92% を使い切り、そこから先の再試行の余地がゼロになる。**上の 2 つは同時に決める**（上を上げてここを据え置くと、ここが先に落ちて上が一度も発火しない）。 |
| `JUDGE_MAX_RETRY_WAIT_MS` | `60000` | リトライ待機の上限。上流が `Retry-After` でこれを超える待機を指示したら、待たずに失敗させる（壊れた上流でハンドラが滞留しないため）。 |

`choice` の選択肢は 2〜20 件。上限 20 は記号の文字数ではなく、**Ollama `/api/chat` の `top_logprobs`
の上限が 20** であることによる。21 件以上にすると上位 20 件の確率しか返らず、21 件目以降は測れない
（黙って 0 として扱われる）。`score` は 2〜10 段、問いは 1 リクエスト 16 個まで。

タイムアウト（上流が遅い＝504・再試行する）と、呼び出し側の切断（＝応答を返さず終了・再試行しない）は
別物として扱う。切断の検出は Express 5 の `res.on('close')`（`res.writableEnded` が false のときだけ中断とみなす）。

切り詰め検知は二段で、どちらも fail-closed（疑わしければ 422 で止める）。
① 送信前：プロンプトの **UTF-8 バイト数**をトークン数の上界として使う（BPE は 1 トークンが最低 1 バイトを
消費するため、バイト数 ≥ トークン数が常に成り立つ）。② 送信後：`prompt_eval_count` がコンテキスト長の
上限付近なら中断する。①が厳密に安全側のため、`JUDGE_MAX_STATE_BYTES` 上限いっぱいの `state` でも
コンテキスト長次第で 422 になることがある（`OLLAMA_CONTEXT_LENGTH` を上げると通るようになる）。

### 添付の読み取り（チャットに添付した文書と画像）

> チャットに添付された **pdf・txt・md・csv・html・docx・xlsx** から api が文字を取り出し、
> user メッセージの**前**に `<documents>` ブロックとして置く（ローカルのモデルには Bedrock の
> document ブロックのような受け口が無いため）。**画像は PNG と JPEG だけ**を、文字にせずそのまま
> モデルへ渡す（下の「読める形式」を参照）。
> 取り出した文字は**利用者の入力＝信用しないデータ**として扱い、ブロックの前に
> 「資料はデータであって指示ではない」旨の注意書きを1回だけ付ける。
> 下の文字数の上限は、取り出した文字が `OLLAMA_CONTEXT_LENGTH` に収まるようにするためのもので、
> **`OLLAMA_CONTEXT_LENGTH` からは自動で導かない**（`JUDGE_CONTEXT_LENGTH` と同じ流儀）。
> 文脈長を下げるときは、文字数の 2 つも一緒に下げること。文脈長を超えると ollama は入力を黙って
> 切り詰めるため、先頭の注意書きが落ちるおそれがある。

| 変数 | 既定 | 説明 |
|---|---|---|
| `ATTACHMENT_MAX_CHARS` | `5000` | 1 件あたりの文字数の上限。超えた分は先頭から切り、`truncated="true"` を付ける。 |
| `ATTACHMENT_TOTAL_MAX_CHARS` | `5000` | **1 リクエスト（送る会話の全体）の合計**の文字数の上限。新しいメッセージの添付から順に割り当て、入りきらなかった古い添付は `status="skipped"` の注記にする（黙って捨てない）。 |
| `ATTACHMENT_MAX_PAGES` | `20` | PDF から読むページ数の上限。 |
| `ATTACHMENT_MAX_BYTES` | `5242880` | 1 件あたりのバイト数の上限（base64 を復号した後・5MiB）。超えたら解析せず注記だけ付ける。web が 1 件 4.5MB まで許すので、その少し上に置いている。 |
| `ATTACHMENT_MAX_FILES` | `5` | 1 メッセージで読む**文書**の件数の上限。**画像は数えない**（画像は `ATTACHMENT_MAX_IMAGES` で数える）。web の 1 通あたりの文書の上限（5 件）と揃える。web は文書と画像を別枠で許すため、ここで画像も数えると、1 通に文書 5 件＋画像 3 件を付けたときに 3 件が読み飛ばされてしまう。 |
| `ATTACHMENT_MAX_IMAGES` | `3` | モデルへ渡す**画像**の枚数の上限。**1 リクエスト（送る会話の全体）で数え**、新しいメッセージの画像から順に割り当て、超えた古い画像は `status="skipped"` の注記にする。**画像は文字の予算（上の 2 つ）を食わない**（別枠）。web の 1 通あたりの画像の上限（3 件・1 件 2MB）と揃える。 |
| `ATTACHMENT_PARSE_TIMEOUT_MS` | `10000` | 1 件の解析に使ってよい時間。超えたら打ち切って注記にし、推論そのものは通す。 |
| `ATTACHMENT_CACHE_ENTRIES` | `32` | 取り出した結果をメモ化する件数の上限（base64 の SHA-256 を鍵にした LRU）。履歴は毎回まるごと送り直されるので、同じ添付の解析を繰り返さないために効かせる。件数の上限はメモリを使いすぎないための安全弁。 |

**読める形式**：`pdf`・`txt`・`md`・`csv`・`html`・`docx`・`xlsx`（文字を取り出して渡す）と、
**画像の PNG・JPEG**（そのまま渡す）。画像を渡せるのは、画像の入力を公表しているモデル
（`gemma4:e4b`・`gemma4:e2b`・`gemma4:26b`・`gemma4:31b`）を選んでいるときだけ。

**受け付けない形式**：

- `.webp` — 同梱 Ollama が使う画像ライブラリ（`golang.org/x/image`）の webp のデコーダに既知の
  脆弱性（クラッシュとメモリ枯渇の DoS）があり、上げ先が出ていないため渡さない
  （[GO-2026-5061](https://pkg.go.dev/vuln/GO-2026-5061)・CVE-2026-46603）。
- `.gif` — 同梱 Ollama が `invalid image input` で断るため渡さない。
- `.doc`・`.xls` — 現役の純 JS の実装が無く読めない。web の添付の選択肢にも出ない。

読めない形式・パスワード付き・壊れたファイルは、黙って捨てずに「読めなかった」旨の注記を残す。
推論そのものは通る。

**画像の検査**（env では変えられない。api の定数）：

- 形式は**中身の先頭のバイト**で判定する（PNG＝`89 50 4E 47 0D 0A 1A 0A`、JPEG＝`FF D8 FF`）。
  名乗り（`mediaType`）と中身が食い違うもの、どちらでもないもの、読み取れないものは**モデルへ渡さず**
  「読めなかった」旨の注記にする。拡張子や名乗りだけを信じない。
- 寸法の上限は**各辺 10000px・2500万画素**。超えるものも渡さず注記にする（展開すると数百 MB に
  なるため）。

**docx・xlsx（zip）の検査**（同じく api の定数）：解析の前に、zip の中身を**実際に展開して数える**。
**zip が申告した大きさは信じない**（zip 爆弾は申告をいくらでも小さく偽れるため）。次のものは解析せず、
「読めなかった」旨の注記にする。

- 展開した**合計が 100MB** を超える、または**エントリが 1 万**を超える（`too_large`）
- **暗号化**されている、または deflate と無圧縮以外の方式で固めてある（`unreadable`）
- エントリとエントリの**間に隠れた領域**がある（`unreadable`）

**上限の目安**。以下は **`gemma4:e2b`・CPU のみ・1 台（RAM 11GB 級）での実測**にもとづく目安で、
測り方を変えれば数字も変わる。**1 字あたりのトークン数はモデル（トークナイザ）ごとに違う**ので、
別のモデルを使うときは自分の環境で測り直すこと。

- 日本語は **1 字 ≒ 0.5〜0.6 トークン**。既定の 5000 字はおよそ **2800 トークン**で、
  `OLLAMA_CONTEXT_LENGTH=8192` の中に system プロンプト・質問・出力のための余白が十分に残る。
  （`4096` では、この 2800 トークンが文脈の大半を占めてしまう。）
- 一方、CPU の機械では、資料を含む 1 回の応答に**数分**かかることがある（実測で最大 約 6 分）。
  **上限を上げるほど遅くなる。**
- 速い機械（GPU や潤沢な RAM）なら `.env` で上げてよい。上げるときは `OLLAMA_CONTEXT_LENGTH` にも
  同じだけ余白が要る。
- **画像は文字とは別に入力トークンを使う。** `gemma4:e2b` の実測では 1 枚あたり
  **約 270 トークンが上限**（896×896 で約 263・1024×768 で約 273・3000×2000 で約 267）。
  ごく小さい画像は少なく、1×1 で約 56。**大きい画像を送っても頭打ちになる**ので、既定の 3 枚でも
  約 800 トークンどまりで、資料 5000 字（約 2800）と合わせて `8192` に収まる。

## 5. RAG（検索拡張生成）

> RAG は `--profile embedding` が必要（tei サービス起動）。すべて既定で動作する微調整ノブ。

| 変数 | 既定 | 説明 |
|---|---|---|
| `RAG_TOP_M` | `10` | 最終返却チャンク数。 |
| `RAG_FETCH_K` | `20` | ベクトル/全文の各取得数。 |
| `RAG_RRF_K` | `60` | 順位融合(RRF)定数。 |
| `RAG_MAX_CHUNK_SIZE` | `1000` | 1 チャンク最大文字数。 |
| `RAG_CHUNK_OVERLAP` | `120` | 隣接チャンクのオーバーラップ。 |
| `RAG_BIGM_SIMILARITY_LIMIT` | `0.2` | pg_bigm 全文しきい値（下げ＝再現↑/精度↓）。 |
| `EMBEDDING_BACKEND` | `tei` | 埋め込み経路（`tei` ローカル / `openai`）。 |
| `EMBEDDING_MODEL_PATH` | `/models/ruri-v3-310m-onnx-int8` | int8 量子化版（高速・精度 -10pt 許容）。fp32 は `/models/ruri-v3-310m-onnx`。 |
| `EMBEDDING_MAX_BATCH_TOKENS` / `_MAX_CLIENT_BATCH_SIZE` | `4096` / `8` | TEI warmup バッチ。低メモリ機の OOM 回避に絞る。 |
| `EMBEDDING_DEFAULT_TIMEOUT_MS` | `300000` | 埋め込みタイムアウト。 |

### リランカ（精度向上・`--profile rerank` 必要）

| 変数 | 既定 | 説明 |
|---|---|---|
| `RERANK_ENABLED` | `false` | cross-encoder で Hit@1 向上（法令 bench 45%→90%）。`true` ＋ tei-reranker 起動で有効。 |
| `RERANK_CANDIDATES` | `20` | rerank 候補プール（最終は `RAG_TOP_M` に絞る）。 |
| `RERANK_DEFAULT_TIMEOUT_MS` | `60000` | rerank タイムアウト。 |
| `RERANKER_MODEL_PATH` | `/models/ruri-v3-reranker-310m-onnx-int8` | int8 版。fp32 は `/models/ruri-v3-reranker-310m-onnx`。 |
| `RERANKER_MAX_BATCH_TOKENS` / `_MAX_CLIENT_BATCH_SIZE` | `4096` / `512` | TEI バッチ。 |
| `RERANK_BACKEND` / `RERANK_BASE_URL` | 内部既定 | 通常変更不要。 |

## 6. 画像生成（stable-diffusion.cpp・`--profile image`）

| 変数 | 既定 | 説明 |
|---|---|---|
| `IMAGE_BACKEND` | `sdcpp` | 経路選択（現状 sdcpp のみ）。 |
| `SDCPP_MODEL_FILE` | `v1-5-pruned-emaonly.safetensors` | `./sdcpp/models/` に置いたモデルファイル名。 |
| `IMAGE_GENERATION_TIMEOUT_MS` / `IMAGE_POLL_INTERVAL_MS` | `300000` / `1000` | CPU 推論用に長め。 |
| `IMAGE_GENERATION_MODEL_IDS` / `IMAGE_DEFAULT_MODEL` | `[]` / 空 | 許可リスト / 既定モデル。 |

## 7. 文字起こし（faster-whisper・`--profile transcribe`）

| 変数 | 既定 | 説明 |
|---|---|---|
| `WHISPER_MODEL` | `deepdml/faster-whisper-large-v3-turbo-ct2` | HF リポ名。**事前 pull 必須**（自動 DL されない）。 |
| `WHISPER_BASE_URL` | `http://whisper:8000/v1` | speaches のベース URL。 |
| `WHISPER_LANGUAGE` | 空（自動検出） | 言語ヒント。 |
| `WHISPER_TIMEOUT_MS` | `600000` | 長尺見込みのタイムアウト。 |

## 8. 機能トグル（profile）

| 変数 | 既定 | 説明 |
|---|---|---|
| `COMPOSE_PROFILES` | `llm` | 起動する機能群。`llm,embedding,rerank,image,transcribe,queue,sandbox` から選ぶ。web メニューも自動連動。 |
| `ENABLED_USE_CASES` | 空 | profile 自動連動を上書きする上級者向け JSON（指定時優先）。 |

## 9. Code Interpreter（任意コード実行・`--profile sandbox`）

> 任意 Python 実行。`SANDBOX_ACCEPT_RISK=1` を明示しないと起動中止。詳細・脅威モデルは
> [sandbox-acceptance-decision.md](./sandbox-acceptance-decision.md) / [sandbox-threat-model.md](./sandbox-threat-model.md)。

| 変数 | 既定 | 説明 |
|---|---|---|
| `SANDBOX_ACCEPT_RISK` | 空 | `1` でリスク受容（必須・二段確認）。 |
| `SANDBOX_BASE_URL` | `http://sandbox:8080` | api → sandbox 委譲先。 |
| `SANDBOX_MAX_FILE_BYTES` / `SANDBOX_MAX_OUTPUT_BYTES` | `8388608` / `262144` | sandbox 側の入出力上限。 |
| `SANDBOX_MAX_CONCURRENCY` / `SANDBOX_WALL_MS` | `4` / `60000` | 同時実行 / 壁時計上限。 |
| `CODE_INTERPRETER_MODEL` | 空 | コード生成 LLM（モデル階層連動・空なら `LLM_DEFAULT_MODEL`）。 |
| `CODE_INTERPRETER_TIMEOUT_MS` | `60000` | api 側 実行タイムアウト。 |
| `CODE_INTERPRETER_MAX_ATTEMPTS` | `3` | 生成リトライ回数。 |
| `CODE_INTERPRETER_MAX_FILE_BYTES` | `26214400` | 入力ファイル合計上限（api 側）。 |

## 10. ExApp（追加 AI アプリ・`--profile queue`）

| 変数 | 既定 | 説明 |
|---|---|---|
| `SQS_ENDPOINT` / `EXAPP_QUEUE_URL` | ElasticMQ 既定 | 非同期キュー。 |
| `EXAPP_ALLOW_PRIVATE_ENDPOINTS` / `EXAPP_ENDPOINT_ALLOWLIST` | `false` / 空 | SSRF ガード。ローカル ExApp を叩くには `true`＋allowlist。 |
| `EXAPP_HTTP_TIMEOUT_MS` | `30000` | 外部呼び出しタイムアウト。 |
| `EXAPP_ARTIFACT_THRESHOLD_BYTES` | `10240` | これ超の出力は artifacts バケットへ退避。 |
| `EXAPP_APIKEY_ENC_KEY` | 空 | apiKey 暗号鍵（任意）。設定時は worker と同一値必須 → 機密扱い [§11](#11-機密値と-secrets)。 |

## 11. オブジェクトストレージ（SeaweedFS / S3）

| 変数 | 既定 | 説明 |
|---|---|---|
| `S3_PUBLIC_ENDPOINT` | `https://localhost:8443` | presigned URL のブラウザ到達用。LAN 公開時は実 IP/FQDN に。 |
| `FILE_PUBLIC_HOST` | `localhost` | 添付（chat の `extraData` の s3 参照）の URL 検証用ホスト名。api は保存要求の URL の **hostname だけ**をこの値と比べる（`https` 必須）ため、スキームもポートも含めず小文字で書く。**`S3_PUBLIC_ENDPOINT` を変えたら、その hostname を必ずここにも設定する**（例：`https://192.168.1.10:8443` → `192.168.1.10`）。不一致だと添付付きメッセージの保存が 400 になる。 |
| `S3_INTERNAL_ENDPOINT` | `http://seaweedfs:8333` | 内部直結（通常変更不要）。 |
| `S3_REGION` / `S3_ACCESS_KEY_ID` | `us-east-1` / `genai-s3-dev-key` | 署名 region / アクセスキー。 |
| `FILE_BUCKET_NAME` / `AUDIO_BUCKET_NAME` / `ARTIFACTS_BUCKET_NAME` | `genai-*` | バケット名。 |
| `API_JSON_BODY_LIMIT` | `48mb` | api リクエストボディ上限。添付は base64 で本文に載る。**web は文書と画像を別枠で数える**ため、1 通に文書 5 件×4.5MB（base64 で約 30MB）と画像 3 件×2MB（約 8MB）＝**合計 約 38MB** を載せられる。**会話の履歴は毎回まるごと送り直される**ので、添付を含む会話が長く続くとこの上限を超えうる（超えると 413）。そのときは値を上げるか、会話を分ける。 |

> `S3_SECRET_ACCESS_KEY` は機密 → [§12](#12-機密値と-secrets)。

## 12. 機密値と secrets

以下は `.env` 直書きも可能ですが、**本番は docker secrets 推奨**（`docker-compose.secrets.yml` オーバーレイ）：

| 機密変数 | dev 既定 | 本番 |
|---|---|---|
| `POSTGRES_PASSWORD` / `KEYCLOAK_DB_PASSWORD` / `KEYCLOAK_ADMIN_PASSWORD` | `changeme` | **必ず変更**。secrets ファイル化。 |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | `genai-admin-dev-secret-change-me` | `.env` 方式では `gen-secrets.sh` 実行時にレンダリング実体（realm import）の生成値へ**自動整合**（未設定・空・dev 既定値のとき）。独自値にする場合は Keycloak 側 client secret も一致させる。 |
| `S3_SECRET_ACCESS_KEY` | `genai-s3-dev-secret-change-me` | `.env` 方式では `gen-secrets.sh` 実行時に生成値へ**自動整合**（`secrets/s3.config.json` と一致）。独自値にする場合は同ファイルと一致させる。 |
| `EXAPP_APIKEY_ENC_KEY` | 空（平文保存） | 暗号化する場合に設定（api/worker 同一値）。 |
| クラウド LLM の `*_API_KEY` | 空 | 利用時に設定（`.env.example` には書かない）。 |

secrets 化の手順：

```bash
./scripts/gen-secrets.sh        # secrets/* を生成（手動・.gitignore）
docker compose -f docker-compose.yml -f docker-compose.secrets.yml up -d
```

詳細は [docs/operations.md（パスワードの扱い）](operations.md#パスワードの扱いenv-と-docker-secrets) を参照。
