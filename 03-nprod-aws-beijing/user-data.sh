#!/usr/bin/env bash
# EC2 user-data —— Ubuntu 24.04 (x86_64) 中国区(cn-north-1)构建机引导。
# 自动:换阿里云 apt 源 → 装 docker + buildx + git + ECR 凭证助手 + gh → 配 docker registry-mirror
#        → 配 ubuntu/root 的 docker ECR 凭证助手 → 注入本机公钥免密登录。
#
# 与美东版差异(中国区国际线路慢/抖,必须本地化):
#   - apt 换 mirrors.aliyun.com(Ubuntu 24.04 是 DEB822 格式 /etc/apt/sources.list.d/ubuntu.sources)。
#   - docker daemon 配 registry-mirror,加速 docker.io 官方 base 镜像拉取(gateway 用的 public.ecr.aws 本就快)。
#   - ECR 凭证助手 host 改中国区 .com.cn 域名。
#   注意:前端 npm ci / pnpm install / pip install 跑在 docker build 容器内,registry-mirror 管不到;
#         如构建慢/超时,需给对应 Dockerfile 加 ARG 切国内 index(单独处理,不在本脚本范围)。
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── apt 换阿里云源(Ubuntu 24.04 noble, DEB822)──
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i -E 's#https?://[a-z0-9.-]*archive\.ubuntu\.com/ubuntu#http://mirrors.aliyun.com/ubuntu#g; s#https?://security\.ubuntu\.com/ubuntu#http://mirrors.aliyun.com/ubuntu#g' \
    /etc/apt/sources.list.d/ubuntu.sources
fi

apt-get update -y
# docker.io 来自 universe;amazon-ecr-credential-helper 提供 docker-credential-ecr-login
# docker-buildx:docker 29 已移除 legacy builder,带 RUN --mount 的 Dockerfile 必须用 BuildKit/buildx
apt-get install -y docker.io docker-buildx git ca-certificates curl gnupg amazon-ecr-credential-helper

# ── docker daemon registry-mirror(加速 docker.io base 镜像)──
# 社区镜像会变动,失效时换下面任意可用项即可。
install -d -m 755 /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://dockerproxy.net"
  ],
  "max-concurrent-downloads": 6
}
JSON

systemctl enable --now docker
systemctl restart docker
usermod -aG docker ubuntu

# ── ubuntu 用户的 docker 自动用 ECR 凭证助手(免手动 docker login)──
ECR_HOST="550022519931.dkr.ecr.cn-north-1.amazonaws.com.cn"
install -d -o ubuntu -g ubuntu -m 700 /home/ubuntu/.docker
cat > /home/ubuntu/.docker/config.json <<JSON
{
  "credHelpers": {
    "${ECR_HOST}": "ecr-login"
  }
}
JSON
chown ubuntu:ubuntu /home/ubuntu/.docker/config.json
# root 同样配(脚本里若以 root 跑 docker)
install -d -m 700 /root/.docker
cp /home/ubuntu/.docker/config.json /root/.docker/config.json

# ── 注入本机公钥,免密登录 root + ubuntu(开 22,仅密钥)──
PUBKEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDQJYgiBFJ+YVbYvV33PcURfagrgPaV9lymD9FXsRh+OEycIB+xgefKoQB5IeO/viTeZKjhTJzhLjTSPxMMDr40O7fKRK3lD8A3pfuT11AnxLKV6yLgDDeF4iJmiOdJYFmGUYLPMRpzJscYaZn4a4xbGIzesmH0wLUnUshwKpbgVAaSMVkdHZdS6eAS/x3cavEyS6Jr9iyRhEY5InvD00DGrjaohJFN55HcX6G+iHvBK8qRk3JiRFrkQi/H36DUi7n1PIEwqC0O4EceOW8Uu72OA1ftzWrgE/Wnop9XaSXIHWc1VRy5P4uJpbrEWP5OpT4vFxzAM7YL34Qqdxn+C8c9 sarming@126.com'
install -d -m 700 /root/.ssh
grep -qxF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$PUBKEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
install -d -o ubuntu -g ubuntu -m 700 /home/ubuntu/.ssh
grep -qxF "$PUBKEY" /home/ubuntu/.ssh/authorized_keys 2>/dev/null || echo "$PUBKEY" >> /home/ubuntu/.ssh/authorized_keys
chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
chmod 600 /home/ubuntu/.ssh/authorized_keys
# 允许 root 密钥登录(默认 prohibit-password 即允许密钥;显式声明以防 AMI 改过)
sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config || true
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

# ── gh CLI(私有仓 OAuth/克隆;cn 线路慢,失败不致命,可开机后用 deploy key / token 兜底)──
mkdir -p -m 755 /etc/apt/keyrings
if curl -fsSL --connect-timeout 10 --max-time 60 https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; then
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -y && apt-get install -y gh || echo "gh 安装失败,开机后手动装或用 deploy key"
else
  echo "拉 gh keyring 失败(cn 线路),跳过;开机后用 deploy key / PAT 走 https 克隆"
fi

echo "bootstrap done" > /home/ubuntu/BOOTSTRAP_OK
