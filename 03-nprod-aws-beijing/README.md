# Build-Box · nprod-aws-beijing（AWS 中国区）

国内 nprod 专用 EC2 构建机，**承载构建 + 自动发版 webhook 入口**（AWS 中国区开不了公网 HTTPS，入口只能自建于 box）。

## 实例 / 网络

| 项 | 值 |
|---|---|
| 实例 | `i-04a04c07cf8a45115`（`c6i.xlarge` 4C8G，Ubuntu 24.04 x86_64，500G gp3；box 须常开，stop 即断自动发版） |
| **构建机 EIP（webhook 入口）** | **`71.132.3.216`**（固定，stop/start 不变；`:9000` 为 webhook，SG 限 GitHub hooks 段 + HMAC） |
| 私网 IP | `10.60.14.132` |
| VPC / 子网 | `vpc-0184393ab31facdd8` · `subnet-04df6a31e846f85f9`（cn-north-1a，公网子网，同 EKS） |
| 安全组 | `sg-0a5df6c094f275a3e`（入站 tcp/22 → `0.0.0.0/0` 仅密钥登录 + tcp/9000 GitHub hooks 段；出站全开） |
| 集群出口 NAT EIP | `52.80.58.223`（外部白名单锚点，如张家口 GitLab） |
| 集群入口 NLB EIP | `43.196.147.233`（业务对外 8081-8086，**非** build box） |
| AMI | `ami-0a09500beb5230fce`（Ubuntu 24.04 amd64 Canonical） |
| Region · 账号 · profile | cn-north-1 · `550022519931`（aws-cn）· `isoftstone-china-self`（脚本默认） |

### 接入 / 启停

```bash
ssh root@71.132.3.216        # 免密（已注入 id_rsa.pub）；ubuntu@71.132.3.216 亦可（NOPASSWD sudo）
aws ssm start-session --profile isoftstone-china-self --region cn-north-1 --target i-04a04c07cf8a45115   # 兜底
# 启停（EIP 固定，start 后 IP 不变）；⚠️ 停机期间 nprod 自动发版静默失效——先停 raytone-webhook 或知会
aws ec2 stop-instances  --profile isoftstone-china-self --region cn-north-1 --instance-ids i-04a04c07cf8a45115
aws ec2 start-instances --profile isoftstone-china-self --region cn-north-1 --instance-ids i-04a04c07cf8a45115
```

## 身份 / 凭据

| 用途 | 身份 |
|---|---|
| 推 cn ECR | 实例 IAM role `raytone-build-box`（建/推 `raytone-*`） |
| push GitOps（GitLab） | `argocd-bot` 写 PAT（credential store），非 IAM |
| webhook HMAC | `/root/.webhook_secret`（600）= SSM SecureString `/raytone/nprod/deploy-webhook-secret`（cn-north-1，64 位；与 box 文件 strip 后逐字节一致） |
| 钉钉 | `/root/.dingtalk_webhook`（三行；当前安全模式=自定义关键词 `Argo`，secret 空） |

## 构建 / 发版

- 镜像仓库：`550022519931.dkr.ecr.cn-north-1.amazonaws.com.cn/raytone-<svc>`
- tag：`nprod-<sha7>-<ts>` + `latest-nprod`（脚本 env 前缀）
- 脚本(同目录)：`build-push-nprod-aws-beijing.sh`（旧名 build-push-china.sh）；自动发版 wrapper `deploy-on-push-nprod-aws-beijing.sh`
- **Dockerfile.china**：国内源 mirror（GOPROXY=goproxy.cn / APT_MIRROR / ALPINE_MIRROR），部分服务用专用 China Dockerfile
- 发布分支：`test`
- **tag 时间戳**：`RUN_TS`（北京时间）整个 run 统一，且**可由环境变量覆盖**。`deploy-on-push` 会为一个仓的所有 target 统一 `export RUN_TS` —— 因为它是**每个 target 调一次** `build-push`，不统一传的话同一源码仓出的多个镜像会因跨分钟拿到不同 tag
- **`GIT_SHA`**：与 `BUILD_SHA` 并列传给所有 target（同一个 40 位全 SHA，两种命名）。gateway 认 `BUILD_SHA`，rdwork-backend 认 `GIT_SHA`（写进 `dist/.buildstamp`）
- target 共 17 个（`--help` 打印全量）。**RDWORK** 两个：
  - `rdwork-backend` ← 仓 `rdwork-backend`，runtime 镜像，**主面与转发面共用**（k8s 里换 command），所以它同时回写 `rdwork-api` 与 `rdwork-gateway` 两个 chart 的 values.yaml
  - `rdwork-backend-migrate` ← 同 Dockerfile 加 `--target migrate`，drizzle 迁移专用。**必须单独出镜像**：runtime 只装生产依赖而 `drizzle-kit` 是 devDependency
  - ★ 两者**必须成对且 tag 一致**：chart 里 Job 的镜像是用同一个 `image.tag` 拼 `<repo>-migrate:<tag>`，tag 一漂就 ImagePullBackOff。走 webhook 时由 `deploy-on-push` 的 `RUN_TS` 保证；手工分两次跑会对不上
  - ★★ **rdwork 每次自动发版都会先报一条假的钉钉红告警，别据此回滚。** `deploy-on-push` 逐 target **串行**：runtime 先推 ECR、回写 `rdwork-api`+`rdwork-gateway` 两个 values.yaml、push，然后进**最长 300s 健康闸门**；migrate 那个 target 排在闸门之后才开始构建。于是必然有一段时间「清单已指向新 tag，而 `-migrate:` 同名镜像还不存在」→ Job `ImagePullBackOff` → app Progressing → **runtime 这一 target 的闸门必然超时报红**。migrate 镜像推上去后 Job 自己重试成功（ImagePullBackOff 带 backoff），两个 app 最终 Synced+Healthy
    - 判据：等 migrate 那条日志出现 `✓ raytone-rdwork-backend-migrate: <tag>`，再复查 `kubectl -n argocd get app rdwork-api rdwork-gateway`。全绿即无事
    - 根治（未做）：让两个 target **先都推完镜像再回写清单**，或把 migrate Job 的 tag 与 runtime 解耦
  - 该 Dockerfile **强依赖 BuildKit**（`# syntax=` / `--mount=type=cache` / heredoc），box 已具备（buildx 0.30.1 / docker 29.1.3）
  - 两个 app（`rdwork-api` / `rdwork-gateway`）已 `enabled: true` 上线；前置见 GitOps 仓 `docs/2026-08-28-rdwork-backend-nprod-integration.md`
- **Raytone Studio** 两个较特殊：
  - `raytone-studio-api` ← 仓 `raytone-studio-backend`（FastAPI + alembic），`raytone-studio-web` ← 仓 `raytone-studio-frontend`（Vite + nginx）
  - 前端**必须**带 `--build-arg BUILD_MODE=public-saas-test`（已写进 spec）；漏掉会构出 `private-test` 产物、接口地址全错
  - 两个 Dockerfile 自带国内源（daocloud / npmmirror / 清华），不用 `Dockerfile.china`
  - 两个 ArgoCD app 已 `enabled: true` 上线（`raytone-studio-api-secret` 已由 `codesphere-public-saas-secret` 复制到位，见 GitOps 仓 `docs/2026-08-12-raytone-studio-integration.md`）
- **已下线的**：`codesphere-saas`、`codesphere-frontend-saas`。两个 target 已从 `build-push-nprod-aws-beijing.sh` 的 spec 与 `ALL_TARGETS` 移除（`--help` 不再列出，显式指名会报 `✗ unknown target`），两个仓也已从 `webhook-listener.py` 白名单与 `deploy-on-push` 映射移除 ⇒ 推 test 不再触发任何构建。集群里本来也没有对应 Application（app-of-apps `enabled: false`）
- **智能体广场** `skill-plaza` ← 仓 `skill-plaza-standalone`（单进程全包：一个 Node 进程同时提供前端页面 + `/api` + skill zip，故一镜像一 target）
  - **必须**带 `--build-arg PUBLIC_BASE_PATH=`（**空串**，已写进 spec）；传 `/` 会拼成 `//`，vite base 变协议相对 URL，页面资源全 404
  - 基础镜像 alpine，走 box 的 `dl-cdn→mirrors.aliyun.com` 自动改写
  - 已上线：ArgoCD app `skill-plaza`（app-of-apps 用 helm parameter 传 `enabled=true` 覆盖 chart values 里的 `false`），对外 `43.196.147.233:8091`；前置见 GitOps 仓 `docs/2026-08-31-skill-plaza-nprod-integration.md`
- 目录：`/root/repo`、`/root/iac/aws-eks-raytone-k8s`（remote 仅 `gitlab`；`github` 已移除，`origin`=退役 CodeCommit 未用）

命令：

```bash
./build-push-nprod-aws-beijing.sh                 # 全量，无 git 变更则跳过
./build-push-nprod-aws-beijing.sh --deploy nprod gateway   # 单服务发版
```

## 自动发版（✅ 常开）

```
GitHub 逐仓 webhook（仅 Push，HMAC 加签）
  → http://71.132.3.216:9000/  (systemd raytone-webhook → /root/webhook-listener.py)
  → deploy-on-push-nprod-aws-beijing.sh <repo> <sender>
  → 逐 target: build-push-nprod-aws-beijing.sh --deploy → 推 ECR + 回写 GitOps + push GitLab → ArgoCD sync
```

- ★★ **webhook 是逐仓配置的，不是 org 级** —— 新接一个源码仓，除了改本目录两个脚本 + listener 白名单，**必须再去 GitHub 该仓 Settings→Webhooks 手工加一条**，否则脚本全接线也永远收不到 push、不构建、不发钉钉（`skill-plaza-standalone` / `rdwork-backend` / `raytone-studio-*` 四仓曾因此空转，2026-09-03 补齐）：

  ```bash
  # secret 必须与 box 的 /root/.webhook_secret 一致
  SEC=$(aws ssm get-parameter --profile isoftstone-china-self --region cn-north-1 \
        --name /raytone/nprod/deploy-webhook-secret --with-decryption --query Parameter.Value --output text)
  gh api -X POST /repos/raytone-lab/<repo>/hooks -f name=web -F active=true -f 'events[]=push' \
    -f config[url]=http://71.132.3.216:9000/ -f config[content_type]=json -f config[secret]="$SEC"
  # 自检：ping 一次，last_response 应为 200/OK（401=secret 不符）
  gh api -X POST /repos/raytone-lab/<repo>/hooks/<id>/pings
  gh api /repos/raytone-lab/<repo>/hooks/<id> --jq .last_response
  ```

- 已注册该 box 的仓 = repo→target 白名单全集（11 个）：`tokenplatform-gateway` / `tokenplatform-publisher` / `tokenplatform-rawbody-consumer` / `codesphere-user` / `codesphere-admin` / `codesphere-billing` / `raytone-landing` / `raytone-studio-backend` / `raytone-studio-frontend` / `rdwork-backend` / `skill-plaza-standalone`。`codesphere-saas` / `codesphere-frontend-saas` 已下线出白名单（GitHub 侧若仍留着 hook，投递会被 listener 按「repo 不在白名单」静默忽略，可另行摘掉）。核对：`for r in …; do gh api /repos/raytone-lab/$r/hooks --jq '[.[].config.url]'; done`
- 只构建变更仓对应镜像（repo→target 白名单硬编码在 `webhook-listener.py` 与 deploy-on-push 脚本，两处校验）
- **静默丢弃的两种情况**：ref 不是 `refs/heads/test`、repo 不在 listener 白名单 —— 都回 200 且 **journald 里不留任何记录**，GitHub 侧看到的也是绿色投递。排查时"日志里没记录"不能区分"没送到"和"被忽略"，要拿 GitHub 该仓 hooks 列表定论
- **发版健康闸门**：清单 push 后轮询 ArgoCD，app 须 `Synced+Healthy` 才算成功；超时（默认 300s，`ARGOCD_HEALTH_TIMEOUT` 可调，`0` 关闭）则打印不健康资源明细并 `exit 1`，由 deploy-on-push 发钉钉红告警。没有它时「镜像推成功」会被报成「发版成功」，新 RS 起不来而旧 pod 继续服务的半滚状态无人可见
  - ArgoCD 查该 app 返回 **404** 时按「没这个 app」处理：打印原因后跳过闸门，不判失败。工作负载在 app-of-apps 里 `enabled: false` 时 Application 压根不存在，否则每次 push 都会空转到超时再发一条红告警
- **accept 队列 = 128**（`webhook-listener.py` 的 `Server.request_queue_size`；Python 默认只有 5）。GitHub 的 push 投递失败**不会自动重试**，连不上就是静默漏一次发版，所以别把这个值调回默认。核对：`ss -ltnp | grep 9000` 的 Send-Q 列、或启动日志 `listener on :9000 (backlog=128)`
- **本机自检**（不触发任何构建，用真 HMAC 打 `127.0.0.1:9000`）：`ref` 非 test 的载荷 → `200 ignore ref=…`；虚构仓名 → `200 ignore repo=…`；坏签名 → `401`。三条都会进 journald
- 临时停用：`systemctl stop raytone-webhook`（手动脚本不受影响）
- 排查链：GitHub webhook Recent Deliveries（2xx）→ `journalctl -u raytone-webhook` → `/var/log/raytone-deploy/<repo>-<target>-<ts>.log`
- box 重建：`build-box/setup-iam.sh` + `user-data.sh`，重绑 EIP、重装 listener/service/scripts/GitOps clone/两个 secret 文件
