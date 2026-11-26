# Raytone 各环境 Build-Box 速查

各环境「源码 → 镜像 → 仓库 → GitOps → ArgoCD」构建/发版机的集中索引，便于查询。
每个环境一份明细见本目录下 `<env>.md`；本文件是汇总表 + 公共约定。

> 权威来源仍是各环境 deploy 文档（本文件末「源文档」链接）；此处为聚合速查，若冲突以源文档为准。

## 🌐 各 build-box 公网 IP 速查

| 环境 | build-box 公网 IP | 用途 |
|---|---|---|
| **uat-aws-hongkong** | 18.166.45.62 | SSH/SSM 接入；已白名单进阿里云 GitLab |
| **nprod-aws-beijing** | 71.132.3.216 | 构建机 + webhook 入口 `:9000`（出口 NAT 另为 `52.80.58.223`） |
| **prod-aliyun-beijing** | 39.96.58.108 | SSH 接入；已白名单进张家口 GitLab `:80` |
| **uat-aliyun-shanghai** | 47.116.200.222 | SSH 接入（已装 docker/node，本机免密别名 `raytone-uat-sh-buildbox`）；⏳ 张家口 GitLab 待放行 `:80` |
| **prod-aws-use1** | 98.94.222.6 | 美东 EC2 `i-0bb45e5486f88d268`（走实例角色）；私网 `172.31.35.46` |

---

## 汇总表

| 环境 | 构建机实例 | 公网 IP / EIP | Region · 账号 | 镜像仓库 | 构建脚本 | 发布分支 | 自动发版 |
|---|---|---|---|---|---|---|---|
| **prod-aws-use1** | `i-0bb45e5486f88d268`（c7i.xlarge，走实例角色）· 笔记本 `bedrock-us` 备用 | **`98.94.222.6`**（私网 `172.31.35.46`） | us-east-1 · `654654182678` | `654654182678.dkr.ecr.us-east-1.amazonaws.com`（CRR→ap-southeast-1） | `build-push-prod-aws-use1.sh` | `test`（cutover 临时；回切后 `prod`） | 无（手动） |
| **uat-aws-hongkong** | `i-076d9021499ff52de`（c7i.2xlarge） | **`18.166.45.62`** | ap-east-1 · `654654182678` | `654654182678.dkr.ecr.ap-east-1.amazonaws.com` | `build-push-uat-aws-hongkong.sh` | `test` | webhook 已停用（2026-06-25） |
| **nprod-aws-beijing** | `i-04a04c07cf8a45115` | 入口 **`71.132.3.216:9000`** · 出口 NAT `52.80.58.223` | cn-north-1 · `550022519931` | `550022519931.dkr.ecr.cn-north-1.amazonaws.com.cn` | `build-push-nprod-aws-beijing.sh` | `test` | ✅ webhook 常开 |
| **prod-aliyun-beijing** | `i-2ze3l8di8b5asw78fnel`（ecs.c9i.2xlarge） | **`39.96.58.108`**（50Mbps） | cn-beijing · 阿里云 | ACR `cri-bcaf32kdltboox4l` → `raytone-prod-aliyun-bj-acr-registry-vpc.cn-beijing.cr.aliyuncs.com` | `build-push-prod-aliyun-bj.sh` | `prod` | 无（手动 `--deploy`） |
| **uat-aliyun-shanghai** | `i-uf60fp3r4e6nzy27aspw`（ecs.c9i.xlarge 4C8G，Ubuntu 24.04，100G） | **`47.116.200.222`**（50Mbps） | cn-shanghai · 软通云 `1704097830365398` | ACR `cri-c0b31s577emx6su9` → `raytone-uat-aliyun-sh-acr-registry-vpc.cn-shanghai.cr.aliyuncs.com` | `build-push-uat-aliyun-sh.sh` | `SRC_BRANCH`（默认 `prod`） | 无（手动） |

明细（每个环境一个子文件夹，内含 `README.md` + 该环境的 build/deploy 脚本）：
[01-prod-aws-use1/](./01-prod-aws-use1/README.md) ·
[02-uat-aws-hongkong/](./02-uat-aws-hongkong/README.md) ·
[03-nprod-aws-beijing/](./03-nprod-aws-beijing/README.md) ·
[04-prod-aliyun-beijing/](./04-prod-aliyun-beijing/README.md) ·
[05-uat-aliyun-shanghai/](./05-uat-aliyun-shanghai/README.md)

各子文件夹里的构建脚本原在 `agentsphere/repo/raytone/`（松散未跟踪文件），已移入。

> ⚠️ 脚本按自身所在目录解析业务源码相对路径（`ROOT=$(dirname $0)`），**在此处直接跑会找不到源码**；
> 真实构建在各 build-box 的 `/root/repo` 执行，此处副本供查询/留档。

---

## 公共约定（所有 build-box 通用）

### repo → 构建 target 映射（一仓一/两镜像）

| GitHub 仓 | 构建 target |
|---|---|
| `tokenplatform-gateway` | `gateway` |
| `tokenplatform-publisher` | `publisher` |
| `tokenplatform-rawbody-consumer` | `tokenplatform-rawbody-consumer` |
| `codesphere-user` | `codesphere-ops-user-api` + `codesphere-ops-user-web` |
| `codesphere-admin` | `codesphere-ops-admin-api` + `codesphere-ops-admin-web` |
| `codesphere-billing` | `codesphere-ops-billing-api` + `codesphere-ops-billing-openapi` |
| `raytone-landing` | `raytone-landing` |
| `raytone-studio-backend` | `raytone-studio-api` |
| `raytone-studio-frontend` | `raytone-studio-web`（必须带 `--build-arg BUILD_MODE=public-saas-<env>`，产物编译期写死） |
| `skill-plaza-standalone` | `skill-plaza`（必须带 `--build-arg PUBLIC_BASE_PATH=` 空串） |
| `rdwork-backend` | `rdwork-backend` + `rdwork-backend-migrate`（仅 05） |

> Studio 三件套目前只在 **05-uat-aliyun-shanghai**（在 `ALL_TARGETS` 内）和
> **04-prod-aliyun-beijing**（已加 target 但**不在** `ALL_TARGETS`，需显式指名；
> 三个源码仓尚未 clone 到该 box、`prod` 分支也未就绪）两台上有。

### 镜像 tag 格式

- AWS 环境：`<env>-<gitsha7>-<YYYYMMDD-HHMM>` + `latest-<env>`
  - 例：`uat-aws-hongkong-abc1234-20260701-2317`、prod `prod-<sha>-<ts>` + `latest-prod`
- 阿里云 ACR：`prod-<gitsha7>-<YYYYMMDD-HHMM>`（tag 不可变，**不推 latest**）

### GitOps 推送 + ArgoCD

- **manifest 仓在 GitLab**（`aws-eks-raytone-k8s`、`aws-eks-workload-apps`，张家口阿里云 `http://39.103.223.155`）：改 `<env>/<svc>/values.yaml` 的 `image.tag` → `push gitlab`
- **ArgoCD 只读 GitLab**（四集群两仓实测），改完不 push GitLab 就看不到；三台 box 的 GitOps clone 均 gitlab-only
- `--rebase` 串行、失败重试、**不 force**；ArgoCD 拉 GitLab 后自动 sync，`--deploy` 会戳对应 app 刷新
- ⚠️ **业务源码仓在 GitHub**（自动发布 webhook 触发源 + build box clone 源）——这是另一回事,勿与 manifest 混

### 凭据（各 box 本地，不进 git）

- `~/.git-credentials`：GitLab `argocd-bot` 写 PAT + RaytoneLab GitHub PAT（HTTPS）
- `~/.github_token`：RaytoneLab PAT（`@raytone-lab/*` 私有 npm，BuildKit `--secret`）
- `~/.ssh/*`：私有 git 依赖 deploy key（如 `ruidong-agent-core`，`docker build --ssh default`）
- 钉钉告警 `/root/.dingtalk_webhook`（三行：URL / 加签 secret / 关键词；缺则静默跳过）

---

## 源文档（权威）

- HK 构建机：`deploy/raytone-uat-aws-hongkong/30-build-box-design.md`
- nprod 自动发版：`deploy/raytone-nprod-aws-beijing/23-自动发版-design.md`
- aliyun 构建机：`deploy/raytone-prod-aliyun-beijing/14-构建机-design.md`
- aliyun ACR：`deploy/raytone-prod-aliyun-beijing/13-ACR-design.md`
- prod-use1 ECR 分发：`deploy/raytone-prod-aws-use1/14-ECR-Image-Distribution-design.md`
- 构建脚本：各环境子文件夹内 `build-push-*.sh`、`deploy-on-push-*.sh`（原 `agentsphere/repo/raytone/`）

## 待补 / Day-2

- uat-aliyun-shanghai build-box **已建**（`i-uf60fp3r4e6nzy27aspw` / `47.116.200.222`，docker/node 已装）；构建脚本 `build-push-uat-aliyun-sh.sh` **已生成**（照 04 改 registry/namespace/env；tag 前缀保持 `prod-` 对齐现网、源分支变量 `SRC_BRANCH` 默认 `prod`；比北京多一个 target `codesphere-ops-billing-openapi` → `Dockerfile.openapi.china`）。⏳ 待办：放 ACR 凭据 `~/.acr_uat_aliyun_sh.json` / GitHub `~/.github_token` / GitLab `~/.git-credentials`、张家口 GitLab 放行 `47.116.200.222/32→:80`（回写 GitOps 前必需）。billing-openapi 首次构建带 `ACR_ENSURE_REPO=1` 自动建仓。
- 各 box SSH 22 多为 `0.0.0.0/0`，Day-2 收敛到运维 IP；凭据迁 SSM/Secrets Manager。
