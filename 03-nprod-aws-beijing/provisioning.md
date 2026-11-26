# 中国区镜像构建机 (raytone-build-box-cn)

cn-north-1(北京)的 x86_64 构建机,build + push 业务镜像到中国区 ECR(nprod),供用户测试环境 EKS `raytonelab-nprod-cn-north-1` 使用。替代「笔记本跨境 build + push」。

与美东构建机的根本差异:**中国区国际线路慢/抖**(docker.io / github / npmjs / pypi 都在墙外),所以必须本地化——apt 走阿里云、docker 配 registry-mirror。**不像美东那样可以裸连不设代理**。

## 现状(实际部署)

| 项 | 值 |
|---|---|
| Instance ID | `i-04a04c07cf8a45115` |
| 机型 / OS | `c6i.xlarge`(4 vCPU / 8 GB,北京无 c7i)· Ubuntu 24.04 x86_64 |
| 磁盘 | 500 GB gp3 |
| 公网 IP | EIP `71.132.3.216`(已绑,stop/start 不变;自动发版 webhook 入口)· 私网 `10.60.14.132` |
| VPC / 子网 | `vpc-0184393ab31facdd8` · `subnet-04df6a31e846f85f9`(cn-north-1a,公网子网,同 EKS)|
| 安全组 | `sg-0a5df6c094f275a3e`(入站 tcp/22 对 `0.0.0.0/0`,仅密钥登录)|
| IAM 角色 | `raytone-build-box`(ECR 推送+自动建 `raytone-*` + SSM)|
| AMI | `ami-0a09500beb5230fce`(Ubuntu 24.04 amd64, Canonical SSM 公共参数)|
| AWS | account `550022519931`(aws-cn)· region `cn-north-1` · profile `isoftstone-china-self` |

已装:docker 29 + docker-buildx + git + gh + `amazon-ecr-credential-helper` + **aws CLI v2**(apt 无 awscli 包,用官方 installer 装);apt 已换阿里云;docker 已配 registry-mirror;`ubuntu`/`root` 的 docker 已配中国区 ECR 凭证助手(push 自动取 token,无需 `docker login`);已注入笔记本 `id_rsa.pub` 免密;已生成 `~/.ssh/id_ed25519` 并加入 GitHub 账号(拉私有仓用,见下)。

## 中国区网络实测结论(决定怎么用)

从本 box(cn-north-1)实测,这些是**通的/不通的**,操作必须照此:

| 资源 | 实测 | 怎么办 |
|---|---|---|
| GitHub 网页/API | ✅ 通 | — |
| **GitHub git 传输(https)** | ❌ **TLS reset**(`GnuTLS recv error -110`),大流量被掐 | **必须走 SSH**:`git@github.com`(22/443 握手稳,clone 实测通)|
| `docker.io` base 镜像 | ❌ registry 超时 | daemon `registry-mirrors`(daocloud 等)已配,`node/python/nginx` 实测可拉 |
| `public.ecr.aws` | ✅ 快 | gateway 直接用,无需处理 |
| `gcr.io` / distroless | ❌ 超时 | Go 服务不要直接 `FROM gcr.io/distroless/...`;改用可访问 runtime base(如 `public.ecr.aws/docker/library/alpine`)或先镜像到 cn ECR |
| `registry.npmjs.org` | ⚠️ 通但 ~2.6MB/s | 够用(landing 前端整体构建 ~3min);嫌慢可后续切 npmmirror |
| `pypi.org` | ❌ ~33KB/s,基本不可用 | Python 服务必须切国内 pypi(见 saas 状态)|
| Debian `deb.debian.org`(容器内 apt) | ❌ 慢到超时 | Python 服务容器内 apt 要切阿里云 |
| cn ECR 推送 | ✅ 秒级(区内) | credHelper + 实例角色,免 docker login |

**各服务构建就绪度:**
- ✅ **node 前端(landing/user-web/admin-web/user-api/admin-api)+ go gateway**:开箱即构建,**Dockerfile 零改动**。`raytone-landing` 已端到端验证(clone→build→push cn ECR 全通)。
- ✅ **publisher**:生产 `Dockerfile` 保持原样继续用 `gcr.io/distroless/base-debian12`;中国区 `build-push-nprod-aws-beijing.sh` 仅对 nprod 使用 `Dockerfile.china`,默认 `RUNTIME_IMAGE=public.ecr.aws/docker/library/alpine:3.20` 以绕开 `gcr.io` 超时。若需和生产 runtime 完全一致,先把 distroless mirror 到 China ECR,再用 `PUBLISHER_RUNTIME_IMAGE=<cn-ecr-distroless>` 覆盖。

## 连接

```bash
ssh root@<公网IP>               # 免密(已装 id_rsa.pub 公钥)
ssh ubuntu@<公网IP>             # ubuntu 有 NOPASSWD sudo
# 兜底(SSH 不通):
aws ssm start-session --profile isoftstone-china-self --region cn-north-1 --target <instance-id>
```

## 构建流程(在 box 上)

构建脚本用仓库里的 **`build-push-nprod-aws-beijing.sh`**(不是美东版 `build-push.sh`),build + push 到中国区 ECR、自动建仓,默认 ENV=nprod。

```bash
cd ~/repo
./build-push-nprod-aws-beijing.sh                              # 全部 target
./build-push-nprod-aws-beijing.sh nprod gateway                # 单个
./build-push-nprod-aws-beijing.sh --no-pull nprod gateway        # 跳过 git pull
```

**私有 npm 包鉴权(`@raytone-lab/*`):** `publisher`、`codesphere-ops-billing-api` 等服务的 `pnpm install` 要拉 GitHub Packages 私有包 `@raytone-lab/publisher-contracts`,需 RaytoneLAB 账号的 classic PAT(scope `read:packages`)。token 存在 box 的 `~/.github_token`(600,root),`build-push-nprod-aws-beijing.sh` 会自动读取并作为 BuildKit secret(`--secret id=github_token`)传入,**无需手动 `export`**。token 原文与生成方式见 `github-resources/RaytoneLAB.md`;文件丢失或 token 失效(`pnpm install` 报 `ERR_PNPM_FETCH_401`)时,按该文档重新生成、`umask 077` 写回 `~/.github_token` 即可。

**已知限制(出网):**
- base 镜像(`docker.io` 的 node/python/nginx)走 daemon registry-mirror,首拉慢但有缓存;gateway 用 `public.ecr.aws` 本就快。
- `gcr.io/distroless/*` 不走 docker.io mirror,在 cn-north-1 常见 `i/o timeout`;不要改生产 Dockerfile,中国区 nprod 通过专用 Dockerfile/build arg 覆盖到可访问 runtime。若必须用 distroless,先在可访问机器 pull/tag/push 到 `550022519931.dkr.ecr.cn-north-1.amazonaws.com.cn/raytone-*`,再以 `PUBLISHER_RUNTIME_IMAGE=<cn-ecr-distroless>` 构建。
- **前端 `npm ci`/`pnpm install`、`pip install` 跑在 docker build 容器内,registry-mirror 管不到**——cn 线路下可能慢/超时。彻底解决需给对应 Dockerfile 加 `ARG`(如 `NPM_CONFIG_REGISTRY=https://registry.npmmirror.com`)切国内 index;暂未做。
- registry-mirror 社区源会失效,改 `/etc/docker/daemon.json` 后 `systemctl restart docker`。

## 自动发版(nprod)

本机同时是 nprod 事件驱动自动发版的入口与执行机:GitHub `test` 分支 push → 各业务仓 webhook → `http://<EIP>:9000/`(systemd `raytone-webhook` → `/root/webhook-listener.py`)→ `/root/repo/deploy-on-push-nprod-aws-beijing.sh <repo>` → `build-push-nprod-aws-beijing.sh --deploy` 构建推 ECR + 改 GitOps 清单 push GitLab → ArgoCD nprod auto-sync。完整设计见 `../23-自动发版-design.md`。

- 入口:EIP `71.132.3.216` + SG tcp/9000(仅放行 GitHub 回调段)。
- GitHub 身份统一用 **raytoneLAB**(webhook=PAT,git=`~/.ssh/raytone_gitops_deploy` 经 `~/.ssh/config`);GitLab 推送用 argocd-bot 写 PAT。
- 停用自动发版:`systemctl stop raytone-webhook`(手动 `build-push-nprod-aws-beijing.sh` 不受影响)。
- 排查:`journalctl -u raytone-webhook` → `/var/log/raytone-deploy/<repo>-<target>-<ts>.log`。

## 启停

```bash
aws ec2 stop-instances  --profile isoftstone-china-self --region cn-north-1 --instance-ids <id>
aws ec2 start-instances --profile isoftstone-china-self --region cn-north-1 --instance-ids <id>
```
⚠️ 本机已绑 EIP `71.132.3.216`(stop/start 不变 IP)。但**作为自动发版 webhook 入口,停机期间所有 nprod 自动发版会静默失效**(GitHub 投递失败);需要停机维护时先知会,或临时停 `raytone-webhook` 并改回手动发版。

## 重建(本目录脚本)

| 文件 | 作用 |
|---|---|
| `ecr-push-policy.json` | 最小权限:ECR 推送+建仓(`raytone-*`),aws-cn 分区(GitOps 推张家口 GitLab 用 argocd-bot 写 PAT,非 IAM;CodeCommit 已退役)|
| `setup-iam.sh` | 建 IAM 角色 + instance profile(含 aws-cn 分区 SSM 托管策略)|
| `user-data.sh` | Ubuntu 24.04 开机引导:阿里云 apt + docker + registry-mirror + ecr-helper + gh + 注入公钥 |
| `webhook-listener.py` | 自动发版 webhook 监听器(装到 `/root/`,systemd `raytone-webhook`)|
| `raytone-webhook.service` | 上述监听器的 systemd unit |

```bash
cd /Users/atom/work/isoftstone/AgentSphere/deploy/raytone-nprod-aws/build-box
AWS_PROFILE=isoftstone-china-self ./setup-iam.sh    # 建 IAM(幂等)

AMI=ami-0a09500beb5230fce   # 或 aws ssm get-parameter ...canonical/ubuntu/server/24.04/.../amd64/.../ami-id

aws ec2 run-instances --profile isoftstone-china-self --region cn-north-1 \
  --image-id "$AMI" --instance-type c6i.xlarge \
  --iam-instance-profile Name=raytone-build-box \
  --subnet-id subnet-04df6a31e846f85f9 --security-group-ids <sg-id> \
  --associate-public-ip-address --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
  --user-data file://user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=raytone-build-box-cn}]'
```
`run-instances` 不带 keypair;公钥已烤进 user-data,开机即免密。

## 安全说明
- 22 对 `0.0.0.0/0` 开放,但**仅密钥登录、无密码**;实例角色只能推/建 `raytone-*` ECR,不能动其它 AWS 资源。
- 想收紧:绑 EIP 后把 22 限到固定来源 IP;或关 22、只用 SSM。
