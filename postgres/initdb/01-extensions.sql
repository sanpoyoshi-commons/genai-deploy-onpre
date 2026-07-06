-- ============================================================================
-- genai-deploy-onpre: 業務 DB 拡張の有効化
--   pgvector : ベクトル類似検索（embedding）
--   pg_bigm  : 2-gram 全文検索（日本語対応）
-- ハイブリッド検索（pgvector + pg_bigm + RRF）の基盤。
--
-- 注意:
--   * このスクリプトは初回 initdb 時（postgres_data ボリュームが空の時）のみ実行される。
--     既存ボリュームに後から拡張を足す場合は、手動で下記 CREATE EXTENSION を実行すること。
--   * RRF クエリ・全文検索インデックス設計・similarity_limit 等のチューニングは
--     api/アプリ層が担う。本スクリプトは拡張の有効化までに留める。
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_bigm;
