# Build-Box · prod-aliyun-beijing（阿里云北京生产）

北京独立镜像构建机（ECS），从 GitHub 拉码、用 `Dockerfile.china` 构建推北京 ACR、回写 GitOps 推 GitLab（权威）。**不复用** AWS build box，也不从 AWS ECR 同步。


## 实例 / 网络

| 项 | 值 |
|---|---|
| ECS 名 | `raytone-prod-aliyun-bj-build-box` |
| 实例 | `i-2ze3l8di8b5asw78fnel`（ecs.c9i.2xlarge，8C16G，Ubuntu 24.04，200G ESSD） |
| VPC / vSwitch | `vpc-2zecy0pucp7420xi1ktas` / `vsw-2zeam0oguj8tdtgxun2oh`（ACK vSwitch） |
| 固定 EIP | **`39.96.58.108`**（`eip-2zeomi1uvphvx9p7w12w2`，50Mbps PayByTraffic）——已在张家口 GitLab 放行 `39.96.58.108/32 → :80` |
| 安全组 | `sg-2zehahdzz5upkpcdyzsu`（入站 22 仅密钥；临时放行 `0.0.0.0/0`） |
| Region | cn-beijing |

## 镜像仓库（ACR）

| 项 | 值 |
|---|---|
| ACR 实例 | `cri-bcaf32kdltboox4l` |
| VPC endpoint（ACK 拉取 / 推送） | `raytone-prod-aliyun-bj-acr-registry-vpc.cn-beijing.cr.aliyuncs.com` |
| 公网 endpoint（仅排障） | `raytone-prod-aliyun-bj-acr-registry.cn-beijing.cr.aliyuncs.com` |
| Namespace | `raytone-prod`（业务）、`raytone-system`（外部/系统镜像重打 tag） |
| Tag 策略 | 不可变，只 push `prod-<sha7>-<ts>`，**不推 latest** |

## 凭据

- ACR：环境变量 `ACR_USER`/`ACR_PASS`，或 `~/.acr_prod_aliyun_bj.json`（`{"username","password"}`）
- GitOps GitLab、GitHub PAT、npm token 同其它 box（`~/.git-credentials`、`~/.github_token`）

## 构建 / 发版

- 脚本(同目录)：`build-push-prod-aliyun-bj.sh`
- **发布分支：`prod`**（默认 `git fetch origin prod → checkout → pull --ff-only`；镜像 tag 前缀恒为 `prod`，与 source branch 解耦）
- Dockerfile：`Dockerfile.china`（base 走 public.ecr.aws，Go 走 goproxy.cn）
- GitOps env 目录：`prod-aliyun-beijing`

命令：

```bash
./build-push-prod-aliyun-bj.sh                    # 全量，先 pull 最新 prod
./build-push-prod-aliyun-bj.sh --deploy gateway   # build+push ACR+回写 GitOps+push GitLab
ACR_ENSURE_REPO=1 ./build-push-prod-aliyun-bj.sh gateway   # 需自动建 ACR repo 时
```

## Raytone Studio 三件套（`raytone-studio-api` / `raytone-studio-web` / `skill-plaza`）

target 已加进脚本，但**刻意不在 `ALL_TARGETS` 里**，只能显式指名 —— 否则不带参数的全量
发版会因为「仓目录不存在」`exit 1`，把既有 prod 发版链路一起搞挂。

首次构建前置（**当前都还没做**）：

| # | 前置 | 现状 |
|---|---|---|
| 1 | box 上 clone 三个仓到脚本同级目录（`/root/repo/`）：`raytone-studio-backend`、`raytone-studio-frontend`、`skill-plaza-standalone` | ✅ 已 clone（SSH，key `~/.ssh/id_ed25519_github_raytone_buildbox`） |
| 2 | 三个仓都要有 `prod` 分支（脚本第 6 字段硬编码 `prod`，无覆盖口子） | ⏸ studio 前后端 `origin/prod` 停在初始化 commit（落后 uat 94 / 90 个 commit、**领先 0**，可直接快进）；`skill-plaza-standalone` 待从 uat 建（uat 与 test 同在 `54dcb49`，零分叉） |
| 3 | 前端仓 `.env.public-saas-prod` | ⏸ 已备好待 PR 进 `test`（plaza 与后端**不需要**对应文件，见下） |
| 4 | ACR `raytone-prod` 下三个 repo | ⏸ 首轮带 `ACR_ENSURE_REPO=1` 自动建，或本机 `aliyun cr create-repository` 预建 |
| 5 | GitOps 侧 chart | ✅ `prod-aliyun-beijing/{raytone-studio-api,raytone-studio-web,skill-plaza}/` 已就位（默认 `enabled: false`） |

三个镜像对环境的依赖程度**不一样**，别一概而论：

| target | 镜像是否与环境绑定 | 说明 |
|---|---|---|
| `skill-plaza` | ❌ 无关 | 仓里没有任何 `.env` 文件；环境差异全在 k8s ConfigMap。**但** `PUBLIC_BASE_PATH` 必须显式传空串 —— Dockerfile 里的默认值是 `ARG PUBLIC_BASE_PATH=/plaza`，漏传会构出 `/plaza` 子路径产物，而本环境是 L4 根路径透传，页面资源全 404 |
| `raytone-studio-api` | ❌ 无关 | 后端按运行时 `ENVIRONMENT` 选配置；仓里缺 `.env.public-saas-prod` 会被**静默跳过**，ConfigMap 即唯一真源 |
| `raytone-studio-web` | ✅ **强绑定** | `VITE_SAAS_PORTAL_URL` / `VITE_SAAS_PURCHASE_URL` 构建期编进产物，必须有 `.env.public-saas-prod` + `BUILD_MODE=public-saas-prod` |

首轮命令（顺序即依赖顺序）：

```bash
ACR_ENSURE_REPO=1 ./build-push-prod-aliyun-bj.sh skill-plaza raytone-studio-api raytone-studio-web
# 验镜像 OK 后再带 --deploy 回写 GitOps（会把三个 values.yaml 的 tag 占位替换掉）
./build-push-prod-aliyun-bj.sh --deploy skill-plaza raytone-studio-api raytone-studio-web
```

⚠️ `raytone-studio-web` 必须带 `BUILD_MODE`（脚本默认已给 `public-saas-prod`）。抄成
`public-saas-uat` / `-test` 会把 `VITE_SAAS_PORTAL_URL` / `VITE_SAAS_PURCHASE_URL`
编成上海 UAT / nprod 的地址 —— 页面完全正常、控制台无报错，只是用户点「平台门户 / 购买」
跳到别的环境去登录买套餐。

前置 1、2 补齐并且首轮镜像验过之后，再把三个 target 名字并入 `ALL_TARGETS`。

## 自动发版

- 无 webhook；发版靠手动 `--deploy`。

## 品牌链接（与前端 site-url override 相关）

- 该环境 platform host = `platform.raytone.ai`，但品牌显示为 **`iruidong.com`**（origin 推不出）。
- user-web nginx configmap 需注入 `window.__RAYTONE_SITE_URL__="https://iruidong.com"`（前端 origin 推导上线后替换旧 sub_filter；见 GitOps 仓对应 configmap）。
