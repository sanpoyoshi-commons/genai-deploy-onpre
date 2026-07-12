# syntax=docker/dockerfile:1
# ============================================================================
# genai-deploy-onpre: 業務 DB 用 PostgreSQL 16 カスタムイメージ
#   ベース  : pgvector/pgvector:0.8.5-pg16（PostgreSQL 16.x + pgvector 0.8.5 同梱）
#   追加    : pg_bigm（2-gram 全文検索）をソースからビルドして導入
# 用途      : ハイブリッド検索基盤（pgvector + pg_bigm + RRF）。
#             本イメージは「拡張が使える状態」までを担う（インフラ層）。
#             RRF クエリ実装・チューニング（similarity_limit 等）は api/アプリ層が担う。
# ============================================================================

# ベースイメージは digest 固定（pgvector 0.8.5 / PostgreSQL 16）。
ARG PGVECTOR_IMAGE=pgvector/pgvector:0.8.5-pg16@sha256:1d533553fefe4f12e5d80c7b80622ba0c382abb5758856f52983d8789179f0fb
FROM ${PGVECTOR_IMAGE}

# --- セキュリティスキャン抑制（根拠付き・監査可能）---
# CKV_DOCKER_3: 公式 postgres entrypoint は root で起動→initdb/PGDATA を chown 後に `gosu postgres` で
#   実行時に非root（uid 999）へ降格する。USER postgres を固定すると named volume（root 所有）初期化が
#   失敗し起動不能になるため、公式設計どおり root entry を維持する（実プロセスは非root）。
# CKV_DOCKER_7: base image は上の ARG default で digest 固定済。checkov は `FROM ${ARG}` の ARG default を
#   解決できず未固定と誤検知するため抑制する。
#checkov:skip=CKV_DOCKER_3:postgres 公式 entrypoint が gosu で実行時に非root(uid 999)へ降格。USER 固定は volume 初期化を壊す
#checkov:skip=CKV_DOCKER_7:base image は ARG default で digest 固定済（checkov が ARG を解決できず誤検知）

# pg_bigm バージョン（v1.2-20250903、PostgreSQL License、PostgreSQL 18 対応）。
# GitHub Releases のタグで固定。
#   ※ 上流タグ／URL は推定値。初回ビルドで解決を確認すること。
#   ※ ハードニング：将来 commit-SHA 固定へ移行可能（PG_BIGM_REPO の clone を SHA checkout に）。
ARG PG_BIGM_VERSION=v1.2-20250903
ARG PG_BIGM_REPO=https://github.com/pgbigm/pg_bigm.git

# pg_bigm を PGXS でビルド・インストールし、ビルド依存は同一レイヤで除去（イメージ肥大化回避）。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        postgresql-server-dev-16 \
        git \
        ca-certificates; \
    git clone --depth 1 --branch "${PG_BIGM_VERSION}" "${PG_BIGM_REPO}" /tmp/pg_bigm; \
    cd /tmp/pg_bigm; \
    make USE_PGXS=1; \
    make USE_PGXS=1 install; \
    cd /; \
    rm -rf /tmp/pg_bigm; \
    apt-get purge -y --auto-remove build-essential postgresql-server-dev-16 git; \
    rm -rf /var/lib/apt/lists/*

# 拡張の有効化は initdb スクリプト（postgres/initdb/）で実施（compose でマウント）。
# pg_bigm は shared_preload_libraries 不要（CREATE EXTENSION のみで利用可能）。

# HEALTHCHECK（CKV_DOCKER_2 / trivy DS-0026）。compose 側 healthcheck と同一判定（pg_isready）を
# イメージにも内蔵し、単体 `docker run` でも liveness を持たせる。env は実行時に compose が注入する。
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=5 \
    CMD pg_isready -U "${POSTGRES_USER:-genai}" -d "${POSTGRES_DB:-genai}" || exit 1
