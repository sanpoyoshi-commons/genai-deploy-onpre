# LLM 抽象化レイヤー

api は LLM 呼び出しを単一の抽象レイヤー（`src/lib/llm/`）に集約し、環境変数 `LLM_BACKEND` 1 つで経路を切り替える。内部インターフェースは OpenAI Chat Completions 互換とし、ローカル経路・クラウド経路を同一の呼び出し側コードで扱える。

## 1. 経路（LLM_BACKEND）

| 値 | 種別 | 接続先 | 備考 |
|---|---|---|---|
| `ollama`（既定） | ローカル | 同梱 Ollama（OpenAI 互換 `/v1`） | CPU 推論可・個人開発者向け既定 |
| `vllm` | ローカル（GPU） | 外部 GPU ホストの vLLM | GPU 環境向けオプション。並列性能が高い。本スタックは vLLM コンテナを含めず、別途起動した vLLM を `VLLM_BASE_URL` で指す |
| `openai` | クラウド | OpenAI API | OpenAI 互換 |
| `anthropic` | クラウド | Anthropic API | OpenAI 互換エンドポイントを流用 |
| `gemini` | クラウド | Google Gemini API | 専用 SDK + 内部変換 |
| `bedrock` | クラウド | AWS Bedrock（Converse API・SigV4） | 専用アダプタ + 内部変換 |

ローカル経路（ollama/vllm）は認証不要、クラウド経路は API キー等が必要（既定空＝利用時に設定）。

## 2. インターフェース

呼び出し側は `chat` / `chatStream`（SSE ストリーミング）/ `embeddings` の3関数を使う。

- `ollama` / `vllm` / `openai` は OpenAI 公式 SDK の `baseURL` 切替で共通実装に吸収
- `anthropic` は OpenAI 互換エンドポイント経由
- `gemini` / `bedrock` は専用 SDK で OpenAI 形式と双方向変換するアダプタを持つ
- 各経路のエラーは統一エラー型に正規化（認証／レート制限／タイムアウト／未実装 等）

経路切替はプロセス再起動で反映（`.env` の `LLM_BACKEND` を変更）。ランタイム動的切替は対象外。

## 3. 環境変数

`LLM_BACKEND` のほか、経路別の `*_BASE_URL` / `*_API_KEY` / `*_DEFAULT_CHAT_MODEL`、共通の `LLM_DEFAULT_MODEL` / `LLM_DEFAULT_TIMEOUT_MS`、許可リスト `MODEL_IDS` 等で制御する。各変数の既定値・意味は [../env-reference.md](../env-reference.md) §4 を参照。

## 4. embedding / RAG

chat とは独立に `EMBEDDING_BACKEND`（既定 `tei` ＝ローカルの ruri-v3）で embedding 経路を選ぶ。RAG 本体は embedding + pgvector + pg_bigm + RRF で構成し、必要に応じて cross-encoder リランカで精度を上げる。テーブル定義は [database-schema.md](./database-schema.md)、env は [../env-reference.md](../env-reference.md) §5〜7 を参照。
