# syntax=docker/dockerfile:1
# ============================================================================
# genai-deploy-onpre: Python サンドボックス（NsJail 隔離・snekbox 設計参考）
#   隔離     : google/nsjail（Apache-2.0）。namespace/seccomp/cgroup/rlimit で任意コードを隔離。
#   参考設計 : python-discord/snekbox（MIT）の NsJail 運用（コードは流用せず設計のみ参照）。
#   用途     : CSV/Excel→pandas→matplotlib チャート(PNG)。api（code-interpreter）が HTTP で委譲する。
#   方針     : 公式 prebuilt が無い NsJail を自前ビルド（sdcpp/postgres と同パターン）。CPU 専用・GPU 不問。
#
#   ⚠ 特権について（PoC 要確認・docs/sandbox-threat-model.md / sandbox-poc-runbook.md）:
#     NsJail は namespace 構築に CAP_SYS_ADMIN を要することが多い。本イメージは supervisor（server.py）を
#     root で動かし CAP_SYS_ADMIN を行使、子（被実行コード）は jail 内 uid=nobody(65534) に落とす設計。
#     compose 側で cap_drop:ALL + cap_add:SYS_ADMIN + no-new-privileges + read_only + network=内部のみ で
#     多層に絞る。user-namespace 化による CAP ゼロ化・rootless 化は PoC で試行し、可能なら移行する。
# ============================================================================

# digest 固定済（2026-06-02 解決）。タグ floating を避け再現性を担保する。更新時は pull→`docker inspect
# --format '{{index .RepoDigests 0}}'` で新 digest を取得して差し替える。
# --- セキュリティスキャン抑制（根拠付き・監査可能）---
# CKV_DOCKER_3 / trivy DS-0002: supervisor(server.py) は CAP_SYS_ADMIN を行使して NsJail の namespace を
#   構築するため root 起動が必須（被実行コードは jail 内で nobody(65534) に確実に降格＝多層防御）。詳細は
#   本 Dockerfile 冒頭コメント・compose の sandbox サービス・docs/sandbox-threat-model.md。USER 固定は不可。
# CKV_DOCKER_7: base image は下の ARG default で digest 固定済（checkov が ARG を解決できず誤検知）。
#checkov:skip=CKV_DOCKER_3:NsJail の namespace 構築に CAP_SYS_ADMIN が要り root 起動必須。子は jail 内 nobody へ降格
#checkov:skip=CKV_DOCKER_7:base image は ARG default で digest 固定済（checkov が ARG を解決できず誤検知）
ARG PY_IMAGE=python:3.13-slim@sha256:c33f0bc4364a6881bed1ec0cc2665e6c53c87a43e774aaeab88e6f17af105e4f
# NsJail ref＝タグ 3.4 の commit SHA に固定（`git ls-remote https://github.com/google/nsjail.git 3.4` で解決）。
# master 追従＝floating は不可。submodule kafel も浅取得（git checkout --detach の下流で固定される）。
ARG NSJAIL_REF=079d70dda4aa1edd9512cfd25ff1e47e316dc355
ARG NSJAIL_REPO=https://github.com/google/nsjail.git

# ---- build stage: NsJail を runtime と同一ベースで compile（共有ライブラリ整合のため） ----
FROM ${PY_IMAGE} AS nsjail-build
ARG NSJAIL_REF
ARG NSJAIL_REPO
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential git ca-certificates pkg-config \
      protobuf-compiler libprotobuf-dev libnl-route-3-dev libnl-3-dev bison flex; \
    rm -rf /var/lib/apt/lists/*
# 生の commit SHA / タグへ固定（sdcpp と同じ init→fetch→detach checkout。submodule=kafel も浅取得）。
RUN set -eux; \
    git init /nsjail; \
    cd /nsjail; \
    git remote add origin "${NSJAIL_REPO}"; \
    git fetch --depth 1 origin "${NSJAIL_REF}"; \
    git checkout --detach FETCH_HEAD; \
    git submodule update --init --recursive --depth 1; \
    make

# ---- runtime stage ----
FROM ${PY_IMAGE} AS runtime
# NsJail の実行時依存（libprotobuf-dev は runtime 共有ライブラリを確実に供給＝ビルド stage と同版で整合）と
# 日本語フォント（IPAex Gothic = IPA Font License）。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      libprotobuf-dev libnl-route-3-200 libnl-3-200 \
      fonts-ipaexfont-gothic ca-certificates; \
    rm -rf /var/lib/apt/lists/*

# 分析ランタイム（pandas/matplotlib/openpyxl）。wrapper は stdlib のみ＝requirements には入れない。
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# NsJail バイナリと wrapper/設定を配置。
COPY --from=nsjail-build /nsjail/nsjail /usr/local/bin/nsjail
COPY server.py nsjail.cfg seccomp.policy matplotlibrc entrypoint.sh /opt/sandbox/
RUN chmod +x /opt/sandbox/entrypoint.sh /usr/local/bin/nsjail

# /sandbox マウントポイントを焼き込む。userns 不使用＝nsjail は rootfs を read-only で bind するため、
# 実行時に mkdir できない（ro）。空ディレクトリを image に持たせ、--bindmount の宛先を確実に存在させる。
RUN mkdir -p /sandbox && chmod 755 /sandbox

# matplotlib のフォントキャッシュをビルド時に焼き込む（read-only・per-run 再構築を避ける）。
# jail 内では /opt/sandbox/mpl を read-only で参照する（rootfs ro bind 経由で可視・絶対パス整合）。
ENV MPLCONFIGDIR=/opt/sandbox/mpl
ENV MATPLOTLIBRC=/opt/sandbox/matplotlibrc
ENV MPLBACKEND=Agg
RUN set -eux; \
    mkdir -p /opt/sandbox/mpl; \
    python3 -c "import matplotlib; matplotlib.set_loglevel('error'); import matplotlib.pyplot as plt; plt.figure(); print('mpl font cache built')"; \
    chmod -R a+rX /opt/sandbox

EXPOSE 8080

# HEALTHCHECK（CKV_DOCKER_2 / trivy DS-0026）。server.py の GET /healthz を stdlib のみで叩く
# （runtime は read_only だが本プローブは書込なし。SANDBOX_ACCEPT_RISK 未設定時は entrypoint が exit 78 で
# 起動せずプローブも発火しない）。
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status==200 else 1)" || exit 1

# supervisor は root で動く（CAP_SYS_ADMIN 行使）。被実行コードは nsjail 内で nobody。compose 側で多層に隔離。
ENTRYPOINT ["/opt/sandbox/entrypoint.sh"]
