#!/usr/bin/env bash
# EC2 user-data —— Ubuntu 24.04 (x86_64) 构建机引导。
# 自动:装 docker + git + ECR 凭证助手 + gh,配好 ubuntu 用户的 docker。
# 不在这里 clone 私有仓(需 git 凭证)——开机后人工 gh auth / 配 deploy key。
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
# docker.io 来自 universe;amazon-ecr-credential-helper 提供 docker-credential-ecr-login
# docker-buildx:docker 29 已移除 legacy builder,带 RUN --mount 的 Dockerfile 必须用 BuildKit/buildx
apt-get install -y docker.io docker-buildx git ca-certificates curl gnupg amazon-ecr-credential-helper

systemctl enable --now docker
usermod -aG docker ubuntu

# ubuntu 用户的 docker 自动用 ECR 凭证助手(免手动 docker login)
install -d -o ubuntu -g ubuntu -m 700 /home/ubuntu/.docker
cat > /home/ubuntu/.docker/config.json <<'JSON'
{
  "credHelpers": {
    "654654182678.dkr.ecr.us-east-1.amazonaws.com": "ecr-login"
  }
}
JSON
chown ubuntu:ubuntu /home/ubuntu/.docker/config.json

# gh CLI(给私有仓做 OAuth 登录,最省事)
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update -y
apt-get install -y gh || echo "gh 安装失败,可开机后手动装或用 deploy key"

# SSM agent:Ubuntu 官方 AMI 已预装(snap amazon-ssm-agent),配合实例角色即可用
echo "bootstrap done" > /home/ubuntu/BOOTSTRAP_OK
