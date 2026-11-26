#!/usr/bin/env python3
"""build-box 上的 GitHub webhook 监听器(nprod 自动发版入口)。

GitHub org/repo webhook(push)→ http://<EIP>:9000/ → 本服务:
  1. HMAC 校验(X-Hub-Signature-256, /root/.webhook_secret)
  2. 过滤:event==push 且 ref==refs/heads/test 且 repo 在白名单
  3. 异步起 /root/deploy-on-push-nprod-aws-beijing.sh <repo>,立即回 202(不占住连接等构建)

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
DEPLOY_SCRIPT = os.environ.get("DEPLOY_SCRIPT", "/root/repo/deploy-on-push-nprod-aws-beijing.sh")

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
    # Raytone Studio 前后端。旧仓名 raytone-studio-bankend(拼写错误)已改为 -backend,
    # 两个都留着:GitHub 改名后旧名不会再出现在 payload 里,但留着比漏掉便宜。
    "raytone-studio-backend",
    "raytone-studio-bankend",
    "raytone-studio-frontend",
    # RDWORK 后端(一仓出 runtime + migrate 两个镜像,映射见 deploy-on-push)
    "rdwork-backend",
    # 智能体广场(SkillPlaza)
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
        # ★ 两个 ignore 分支都要留日志。没日志时排查会走死路:GitHub 侧是绿色投递、
        #   journald 里一片空白,"没记录"既可能是没送到也可能是被这里静默丢掉,分不出来
        #   (2026-09-03 查 skill-plaza 漏发版时就卡在这一步,只能回 GitHub 查 hooks 才定论)。
        if ref != "refs/heads/test":
            print(f"ignore ref={ref} (repo={repo})", flush=True)
            return self._send(200, f"ignore ref={ref}")
        if repo not in ALLOWED_REPOS:
            print(f"ignore repo={repo} (不在白名单;新接仓要同时改本文件与 deploy-on-push 映射)", flush=True)
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


class Server(ThreadingHTTPServer):
    # accept 队列。Python 默认 request_queue_size=5(ss -ltnp 的 Send-Q),突发并发投递
    # 超过它,内核直接拒连,GitHub 侧记 502 connection_error —— 而 **push 投递失败
    # GitHub 不会自动重试**,丢一次就是静默漏一次发版。
    request_queue_size = 128


if __name__ == "__main__":
    print(f"raytone webhook listener on :{PORT} (backlog={Server.request_queue_size})", flush=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
