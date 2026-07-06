# syntax=docker/dockerfile:1
# ============================================================================
# genai-deploy-onpre: 画像生成サーバ（stable-diffusion.cpp / sd-server）カスタムイメージ
#   上流    : leejet/stable-diffusion.cpp（MIT、純 C/C++・CPU 推論）
#   用途    : 画像生成の OSS バックエンド（Bedrock 画像モデルの代替）。
#             api は画像生成クライアント（src/image/）から /sdcpp/v1/img_gen を叩く。
#   方針    : 公式 prebuilt サーバイメージが無いため自前ビルド（postgres カスタムイメージと同パターン）。
#             CPU 専用（GPU 不問で docker compose up）。GPU 対応は今後。
# ============================================================================

# 上流 ref：leejet/stable-diffusion.cpp は semver リリースが無く
#   master-<hash> 運用。再現性のため、画像生成の live e2e（SD1.5 生成を確認）で
#   ビルド・動作確認した master HEAD commit へ固定する（postgres Dockerfile の digest pin と同方針）。
#   この SHA は当時の master HEAD（"feat: add microsoft lens support (#1560)"・2026-05-26）。更新時は
#   新しい SHA でビルド＋画像 e2e を通してから差し替えること（master 追従＝floating は不可）。
ARG SDCPP_REF=92dc7268fc4ffb0c0cc0bd52dfcefea91326e797
ARG SDCPP_REPO=https://github.com/leejet/stable-diffusion.cpp.git
ARG UBUNTU_VERSION=24.04

# ---- build stage（上流 Dockerfile に倣う：build-essential git cmake で sd-server をビルド） ----
FROM ubuntu:${UBUNTU_VERSION} AS build
ARG SDCPP_REF
ARG SDCPP_REPO
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential git cmake ca-certificates; \
    rm -rf /var/lib/apt/lists/*
# 生の commit SHA へ固定するため clone --branch は使わない（--branch はブランチ/タグ名のみ受理し SHA 不可）。
# init → fetch <SHA>（GitHub は reachable SHA の fetch を許可）→ detach checkout で特定 commit を浅く取得。
# SDCPP_REF にブランチ名やタグを与えても同経路で動く（より汎用）。submodule も浅く取得する。
RUN set -eux; \
    git init /sd.cpp; \
    cd /sd.cpp; \
    git remote add origin "${SDCPP_REPO}"; \
    git fetch --depth 1 origin "${SDCPP_REF}"; \
    git checkout --detach FETCH_HEAD; \
    git submodule update --init --recursive --depth 1
WORKDIR /sd.cpp
# CPU 既定ビルド（GPU バックエンドフラグは付けない）。examples（sd-cli/sd-server）は既定で有効。
RUN set -eux; \
    cmake . -B ./build; \
    cmake --build ./build --config Release --parallel

# ---- runtime stage（実行に必要な libgomp1 のみ） ----
FROM ubuntu:${UBUNTU_VERSION} AS runtime
# --- セキュリティスキャン抑制（根拠付き・監査可能）---
# CKV_DOCKER_3 / trivy DS-0002: sd-server は生成時に /proc/<pid>/map_files を open し、これに
#   CAP_CHECKPOINT_RESTORE が要る（compose で cap_add）。非root プロセスでは cap_add が effective set に
#   入らず（ambient cap 不使用）画像生成が EPERM で 500 になるため root 実行を維持する。
#checkov:skip=CKV_DOCKER_3:sd-server は CAP_CHECKPOINT_RESTORE を要し非root では cap が effective にならず画像生成不能
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libgomp1; \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /sd.cpp/build/bin/sd-server /usr/local/bin/sd-server
# モデルは ./sdcpp/models/ をバインドマウント（運用者が SD1.5 等を配置＝任意手動 DL）。
# 起動引数は compose の command で与える（-m <model> --listen-ip --listen-port）。

# HEALTHCHECK（CKV_DOCKER_2 / trivy DS-0026）。runtime は libgomp1 のみ＝curl/python 不在のため
# bash の /dev/tcp で 8080 の listen を確認する（liveness）。モデルのコールドロードを見込み start-period は長め。
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080' || exit 1
ENTRYPOINT ["/usr/local/bin/sd-server"]
