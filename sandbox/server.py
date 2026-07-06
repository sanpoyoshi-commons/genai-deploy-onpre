#!/usr/bin/env python3
"""genai サンドボックス HTTP wrapper（標準ライブラリのみ・依存ゼロ）。

api（genai-ai-api-onpre の HttpSandboxClient）からの委譲を受け、LLM 生成 Python を NsJail で隔離実行する。
真の隔離境界は NsJail（network off / rootfs read-only / tmpfs / 資源上限 / 子は nobody）。本 wrapper は
リクエストごとに作業 tmpdir を作り、コードと入力ファイルを展開 → nsjail 実行 → stdout/stderr と生成ファイル
（既定 *.png）を回収して JSON で返す。

HTTP 契約:
  GET  /healthz -> 200 {"status":"ok"}
  POST /eval    -> 200 {"status":"ok|error|timeout","exit_code":int,"stdout":str,"stderr":str,
                        "files":[{"name":str,"content_b64":str,"bytes":int}]}
    request: {"code":str,"files":[{"name":str,"content_b64":str}],"timeout_ms":int,"output_globs":[str]}
  実行失敗（非0終了/timeout）も 200（status で表す）。リクエスト不正は 400、過負荷は 429、容量超過は 413。
"""
import base64
import glob
import json
import os
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("SANDBOX_PORT", "8080"))
NSJAIL_BIN = os.environ.get("NSJAIL_BIN", "/usr/local/bin/nsjail")
NSJAIL_CFG = os.environ.get("NSJAIL_CFG", "/opt/sandbox/nsjail.cfg")
PYTHON_BIN = os.environ.get("SANDBOX_PYTHON", "/usr/local/bin/python3")
# jail 内で被実行コードを落とす uid/gid（nobody）。userns 不使用のため setuid で適用する。
SANDBOX_UID = os.environ.get("SANDBOX_UID", "65534")
SANDBOX_GID = os.environ.get("SANDBOX_GID", "65534")
WALL_MS = int(os.environ.get("SANDBOX_WALL_MS", "8000"))
MAX_OUTPUT_CHARS = int(os.environ.get("SANDBOX_MAX_OUTPUT_BYTES", str(256 * 1024)))
MAX_FILE_BYTES = int(os.environ.get("SANDBOX_MAX_FILE_BYTES", str(8 * 1024 * 1024)))
MAX_FILES = int(os.environ.get("SANDBOX_MAX_FILES", "8"))
MAX_BODY_BYTES = int(os.environ.get("SANDBOX_MAX_BODY_BYTES", str(32 * 1024 * 1024)))
MAX_CONCURRENCY = int(os.environ.get("SANDBOX_MAX_CONCURRENCY", "4"))
WORK_ROOT = os.environ.get("SANDBOX_WORK_ROOT", "/tmp/work")

_sema = threading.BoundedSemaphore(MAX_CONCURRENCY)


def _safe_name(name):
    """basename のみ許可（パストラバーサル防御）。NsJail も隔離境界だが、入口でも弾く（多層防御）。"""
    base = os.path.basename(str(name or ""))
    if not base or base in (".", "..") or "/" in base or "\\" in base:
        raise ValueError(f"unsafe filename: {name!r}")
    return base


def _safe_globs(globs):
    """output_globs を「workdir 直下の相対 glob」だけに制限する（多層防御）。

    glob 展開は jail の外側（supervisor=root）で走るため、絶対パス・パス区切り・`..` を含む
    パターンは workdir 外のファイル探索に繋がりうる。実運用では api が常に既定 ['*.png'] を渡す
    ため通常は無害だが、境界サービスとして内部からの直接呼び出しにも耐えるよう入口で弾く。
    残った安全なパターンが無ければ既定 ['*.png'] に戻す。
    """
    safe = []
    for p in globs:
        s = str(p)
        if not s or "/" in s or "\\" in s or ".." in s:
            continue
        safe.append(s)
    return safe or ["*.png"]


def _truncate(text):
    if text is None:
        return ""
    if len(text) > MAX_OUTPUT_CHARS:
        return text[:MAX_OUTPUT_CHARS] + "\n...[truncated]"
    return text


def run_eval(payload):
    code = payload.get("code")
    if not isinstance(code, str) or not code:
        return 400, {"error": "code is required"}
    files = payload.get("files") or []
    if not isinstance(files, list):
        return 400, {"error": "files must be a list"}
    timeout_ms = payload.get("timeout_ms") or WALL_MS
    try:
        timeout_ms = int(timeout_ms)
    except (TypeError, ValueError):
        timeout_ms = WALL_MS
    output_globs = payload.get("output_globs") or ["*.png"]
    if not isinstance(output_globs, list):
        output_globs = ["*.png"]
    output_globs = _safe_globs(output_globs)
    wall_sec = max(1, (int(timeout_ms) + 999) // 1000)

    workdir = tempfile.mkdtemp(prefix="job-", dir=WORK_ROOT)
    try:
        with open(os.path.join(workdir, "main.py"), "w", encoding="utf-8") as f:
            f.write(code)
        for item in files:
            name = _safe_name(item.get("name"))
            content = base64.b64decode(item.get("content_b64") or "", validate=False)
            with open(os.path.join(workdir, name), "wb") as f:
                f.write(content)

        # mkdtemp は 0700/root 所有のため、nobody(65534) に降格した jail が cwd(/sandbox=workdir bind) へ chdir
        # できず生成物も書けない。所有者 root による chmod（CAP_CHOWN 不要）で当該 per-job dir のみ開放する。
        # この dir は単一ジョブにだけ bind され、network off・他ジョブと非共有のため許容（出力は root=server が読み戻す）。
        os.chmod(workdir, 0o777)

        log_path = os.path.join(workdir, ".nsjail.log")
        cmd = [
            NSJAIL_BIN,
            "--config", NSJAIL_CFG,
            "--log", log_path,  # nsjail 自身のログは分離し、子の stdout/stderr を汚さない
            # userns 不使用のため setuid で nobody に落とす（uidmap ではなく --user/--group）。
            "--user", SANDBOX_UID,
            "--group", SANDBOX_GID,
            "--bindmount", f"{workdir}:/sandbox",
            "--time_limit", str(wall_sec),
            "--",
            PYTHON_BIN, "/sandbox/main.py",
        ]

        status = "ok"
        try:
            # subprocess timeout は nsjail の time_limit が効かない場合の保険（wall_sec + 余裕）。
            proc = subprocess.run(
                cmd, capture_output=True, text=True, errors="replace", timeout=wall_sec + 5
            )
            exit_code = proc.returncode
            stdout = proc.stdout or ""
            stderr = proc.stderr or ""
            if exit_code != 0:
                status = "error"
        except subprocess.TimeoutExpired as e:
            status = "timeout"
            exit_code = -1
            stdout = e.stdout if isinstance(e.stdout, str) else ""
            stderr = "実行が制限時間を超過しました（wall-time backstop）。"

        out_files = []
        real_workdir = os.path.realpath(workdir)
        for pattern in output_globs:
            for path in sorted(glob.glob(os.path.join(workdir, str(pattern)))):
                if len(out_files) >= MAX_FILES:
                    break
                # symlink で workdir 外を指していないか realpath で封じ込め（被実行コードが
                # `chart.png -> /etc/passwd` 等を仕込んでも supervisor=root が読み戻さない）。
                real = os.path.realpath(path)
                if real != real_workdir and not real.startswith(real_workdir + os.sep):
                    continue
                base = os.path.basename(path)
                if base in ("main.py", ".nsjail.log") or not os.path.isfile(path):
                    continue
                size = os.path.getsize(path)
                if size > MAX_FILE_BYTES:
                    continue
                with open(path, "rb") as fp:
                    out_files.append({
                        "name": base,
                        "content_b64": base64.b64encode(fp.read()).decode("ascii"),
                        "bytes": size,
                    })

        return 200, {
            "status": status,
            "exit_code": exit_code,
            "stdout": _truncate(stdout),
            "stderr": _truncate(stderr),
            "files": out_files,
        }
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/eval":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("content-length") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            self._send(413, {"error": "request too large"})
            return
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except (ValueError, TypeError):
            self._send(400, {"error": "invalid json"})
            return
        if not isinstance(payload, dict):
            self._send(400, {"error": "invalid payload"})
            return
        if not _sema.acquire(blocking=False):
            self._send(429, {"error": "sandbox busy"})
            return
        try:
            status, obj = run_eval(payload)
            self._send(status, obj)
        except ValueError as e:
            self._send(400, {"error": str(e)})
        except Exception:  # noqa: BLE001 - wrapper は落とさず 500 を返す
            self._send(500, {"error": "sandbox internal error"})
        finally:
            _sema.release()

    def log_message(self, *_args):  # アクセスログは抑制（Dozzle/json-file はアプリログ前提）
        pass


def main():
    os.makedirs(WORK_ROOT, exist_ok=True)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
