# Build-Box · uat-aliyun-shanghai（阿里云上海 UAT）

上海 UAT 独立镜像构建机（ECS），从 GitHub 拉码、用 `Dockerfile.china` 构建推上海 ACR、回写 GitOps 推张家口 GitLab（权威）。**软通云 services 账号 `1704097830365398`**，profile `ruantong-services`。

## 实例 / 网络

| 项 | 值 |
|---|---|
| ECS 名 | `raytone-uat-aliyun-sh-build-box` |
| 实例 | `i-uf60fp3r4e6nzy27aspw`（**ecs.c9i.xlarge，4C8G**，Ubuntu 24.04，100G ESSD，按量；UAT 降配，prod 是 c9i.2xlarge 8C16G） |
| VPC / vSwitch | `vpc-uf68bshp2tgxw620c2apj` / `vsw-uf6bmhsxjutr6t90tkrdg`（中间件 vSwitch b） |
| 公网 IP | **`47.116.200.222`**（RunInstances 分配，50Mbps PayByTraffic）|
| 安全组 | `sg-uf6f0f7bcsx40lwmzh1n`（入站 22 临时 `0.0.0.0/0`，收敛时改密钥来源） |
| KeyPair | `raytone-uat-aliyun-sh-ack-key`（私钥 `deploy/raytone-uat-aliyun-shanghai/secrets/raytone-uat-aliyun-sh-ack-key.pem`，600） |
| Region | cn-shanghai |

> ⚠️ **张家口 GitLab 需放行本机公网 IP**：`47.116.200.222/32 → 39.103.223.155:80`（GitLab 在张家口，属另一侧，需该侧管理员加安全组规则；否则 build box 回写 GitOps 推不上去）。SSH：`ssh -i .../raytone-uat-aliyun-sh-ack-key.pem root@47.116.200.222`。

## 镜像仓库（ACR）

| 项 | 值 |
|---|---|
| ACR 实例 | `cri-c0b31s577emx6su9`（企业版基础版 `raytone-uat-aliyun-sh-acr`） |
| VPC endpoint（ACK 拉取 / 构建机推送） | `raytone-uat-aliyun-sh-acr-registry-vpc.cn-shanghai.cr.aliyuncs.com` |
| 公网 endpoint（仅排障） | `raytone-uat-aliyun-sh-acr-registry.cn-shanghai.cr.aliyuncs.com` |
| Namespace | `raytone-uat`（业务）、`raytone-system`（外部/系统镜像重打 tag） |
| Tag 策略 | 不可变，push `uat-<sha7>-<ts>`，不推 latest |

## 凭据（需在 box 上放置）

- **ACR**：环境变量 `ACR_USER`/`ACR_PASS` 或 `~/.acr_uat_aliyun_sh.json`。ACR 企业版凭据在控制台「访问凭证」设置固定密码；或用 RAM 用户 + `cr GetAuthorizationToken`。
- **GitLab 回写**：`~/.git-credentials`（张家口 GitLab `39.103.223.155`，用 `argocd-uat-bot` 或既有 bot）。
- **GitHub PAT**：`~/.github_token`（拉 `RaytoneLAB` 私有仓 + `@raytone-lab/*` npm 包 read:packages）。
- **npm**：私有包 token（同 GitHub PAT）。

## 构建 / 发版

- 脚本：`build-push-uat-aliyun-sh.sh`（从 `04-prod-aliyun-beijing/build-push-prod-aliyun-bj.sh` 改：registry→上海 ACR、namespace→`raytone-uat`、GitOps env 目录→`uat-aliyun-shanghai`、tag 前缀→`uat`、发布分支→ UAT 对应分支）。
- Dockerfile：`Dockerfile.china`（base 走 public.ecr.aws，Go 走 goproxy.cn）。
- 无 webhook，手动 `--deploy`（对齐 prod-aliyun-beijing）。
- 分支/tag：默认 `SRC_BRANCH=uat`、tag 前缀 `uat-`；9 个业务仓均有 uat 分支。
- **代理**：cn 直连官方源慢，saas 尤重。用 `BUILD_PROXY=http://172.17.0.1:7890 ./build-push-uat-aliyun-sh.sh ...` 让构建走 box 上的 mihomo。详见 [`mihomo-proxy.md`](./mihomo-proxy.md)（含节点选择/校验）。

## 当前状态（2026-07-03）

- ✅ ECS 已建并 running，`provision.sh` 已跑：**docker/buildx、node20、git、jq 已装**。
- ✅ 本机 SSH 免密：`~/.ssh/config` 别名 **`raytone-uat-sh-buildbox`**（`ssh raytone-uat-sh-buildbox` 直连），本机 `id_rsa` 公钥已入 box `authorized_keys`。
- ⏳ 待办：
  - 放 ACR 凭据 `~/.acr_uat_aliyun_sh.json` 后重跑 provision.sh 的 ACR 登录段；
  - 放 `~/.git-credentials`（张家口 GitLab）、`~/.github_token`（RaytoneLAB PAT）；
  - **张家口 GitLab 放行 `47.116.200.222/32 → 39.103.223.155:80`**；
  - 补 `build-push-uat-aliyun-sh.sh`（照 `04-prod-aliyun-beijing` 改 registry→上海 ACR、namespace→`raytone-uat`、env 目录→`uat-aliyun-shanghai`、tag 前缀→`uat`）。

## 开机初始化

见同目录 `provision.sh`（装 docker/buildx、git、node、登录 ACR）。**已执行过**；仅在放好 ACR 凭据后需重跑其 ACR 登录段。
