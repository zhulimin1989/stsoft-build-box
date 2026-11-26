#!/usr/bin/env bash
# raytone-uat-aliyun-sh-build-box 首次开机初始化（Ubuntu 24.04）。
# SSH 上去 root 执行一次：ssh -i .../raytone-uat-aliyun-sh-ack-key.pem root@47.116.200.222
set -euo pipefail

echo "== 1. 系统 + docker + buildx =="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg git jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
systemctl enable --now docker

echo "== 2. Node (构建前端/node 服务用) =="
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

echo "== 3. 登录上海 ACR（VPC endpoint） =="
# 需先放好 ~/.acr_uat_aliyun_sh.json {"username":"...","password":"..."}
if [ -f ~/.acr_uat_aliyun_sh.json ]; then
  ACR_USER=$(jq -r .username ~/.acr_uat_aliyun_sh.json)
  ACR_PASS=$(jq -r .password ~/.acr_uat_aliyun_sh.json)
  echo "$ACR_PASS" | docker login --username "$ACR_USER" --password-stdin \
    raytone-uat-aliyun-sh-acr-registry-vpc.cn-shanghai.cr.aliyuncs.com
else
  echo "!! 缺 ~/.acr_uat_aliyun_sh.json，跳过 ACR 登录（放好后重跑本段）"
fi

echo "== 4. 提醒 =="
echo " - 放 ~/.git-credentials（张家口 GitLab 39.103.223.155）"
echo " - 放 ~/.github_token（RaytoneLAB PAT，拉私有仓 + npm 包）"
echo " - 张家口 GitLab 需放行本机公网 47.116.200.222/32 -> :80"
echo "provision done."
