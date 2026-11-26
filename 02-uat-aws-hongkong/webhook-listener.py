#!/usr/bin/env python3
"""build-box 上的 GitHub webhook 监听器(HK uat-aws-hongkong 自动发版入口)。

GitHub org/repo webhook(push)→ http://<EIP>:9000/ → 本服务:
  1. HMAC 校验(X-Hub-Signature-256, /root/.webhook_secret)
  2. 过滤:event==push 且 ref==refs/heads/test 且 repo 在白名单
  3. 异步起 /root/repo/deploy-on-push-uat-aws-hongkong.sh <repo>,立即回 202(不占住连接等构建)

裸 IP 无有效 TLS 证书,走 HTTP + HMAC:真实性靠签名,payload 为 commit 元数据。
SG 仅放行 GitHub 回调 IP 段,纵深防御。
"""
import hashlib
import hmac
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "9000"))
SECRET_FILE = os.environ.get("SECRET_FILE", "/root/.webhook_secret")
DEPLOY_SCRIPT = os.environ.get("DEPLOY_SCRIPT", "/root/repo/deploy-on-push-uat-aws-hongkong.sh")

with open(SECRET_FILE, "rb") as f:
    SECRET = f.read().strip()

ALLOWED_REPOS = {
    "tokenplatform-gateway",
    "tokenplatform-publisher",
    "tokenplatform-rawbody-consumer",
    "codesphere-user",
    "codesphere-admin",
    "codesphere-billing",
    "raytone-landing",
    # ── 香港 UAT 首次接入(2026-09-01) ──
    "raytone-studio-backend",
    "raytone-studio-frontend",
    "rdwork-backend",
    "skill-plaza-standalone",
}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, msg):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(msg.encode())

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(n)
        sig = self.headers.get("X-Hub-Signature-256", "")
        expected = "sha256=" + hmac.new(SECRET, raw, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            print("reject: bad signature", flush=True)
            return self._send(401, "bad signature")

        event = self.headers.get("X-GitHub-Event", "")
        if event == "ping":
            return self._send(200, "pong")
        if event != "push":
            return self._send(200, f"ignore event={event}")

        try:
            p = json.loads(raw)
        except Exception:
            return self._send(400, "bad json")

        ref = p.get("ref", "")
        repo = (p.get("repository") or {}).get("name", "")
        # 触发人:优先 GitHub 账号(sender.login),退回 git pusher.name
        trigger = (p.get("sender") or {}).get("login") or (p.get("pusher") or {}).get("name") or "unknown"
        if ref != "refs/heads/test":
            return self._send(200, f"ignore ref={ref}")
        if repo not in ALLOWED_REPOS:
            return self._send(200, f"ignore repo={repo}")

        if os.path.exists(DEPLOY_SCRIPT):
            # 用 bash 显式调用,不依赖可执行位(rsync -a 可能把 +x 覆盖掉,曾导致发版静默跳过)
            subprocess.Popen(["/bin/bash", DEPLOY_SCRIPT, repo, trigger])
            print(f"dispatched {DEPLOY_SCRIPT} {repo} (trigger={trigger})", flush=True)
            return self._send(202, f"accepted repo={repo}")
        print(f"deploy script missing: {DEPLOY_SCRIPT} (repo={repo})", flush=True)
        return self._send(202, f"accepted repo={repo} (deploy script not found)")

    def log_message(self, *a):
        pass  # 静默 access log;业务日志用 print 走 journald


if __name__ == "__main__":
    print(f"raytone webhook listener on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
