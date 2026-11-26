# Build-Box · uat-aws-hongkong（HK）

香港 UAT 专用 EC2 构建机，一台承载「构建 + 发版」。

## 实例 / 网络

| 项 | 值 |
|---|---|
| 实例 | `i-076d9021499ff52de`（c7i.2xlarge，AL2023 `ami-0dfe3c8e9595e41a0`，200G gp3） |
| 子网 / VPC | public-1a `subnet-07ce78a62672ac7cd` / `vpc-0d83ca9dc1bd4a9b2` |
| 固定 EIP | **`18.166.45.62`**（`eipalloc-05ea1110fe7fbc5de`）——已加入阿里云 GitLab 安全组白名单 |
| 安全组 | `sg-0f31bba9b999f0833`（入站 22:`0.0.0.0/0` + 9000:GitHub hooks；出站全开） |
| Region · 账号 | ap-east-1 · `654654182678` |

## 接入

- SSM：`aws ssm start-session --target i-076d9021499ff52de --region ap-east-1`
- SSH：`ssh root@18.166.45.62`（ed25519，免密；22 当前 `0.0.0.0/0`，Day-2 收敛）

## 身份 / 凭据

| 用途 | 身份 |
|---|---|
| 推 HK ECR | 实例 IAM role `raytonelab-nprod-aws-hk-buildbox-role`（内联 `ecr-raytone-push` 限 `raytone-*` + SSM）；脚本 `PROFILE=` 留空即走实例角色 |
| push GitOps（GitLab） | `~/.git-credentials` 里 GitLab `argocd-bot` 写 PAT |
| 拉源码 / push GitHub | RaytoneLab PAT（`repo`+`read:packages`）走 HTTPS |
| `@raytone-lab/*` 私有 npm | 同一 PAT 写入 `~/.github_token` |
| `ruidong-agent-core` 私有 git 依赖 | SSH deploy key `~/.ssh/raytone_gitops_deploy`（仅 saas 构建期用） |

## 构建 / 发版

- 镜像仓库：`654654182678.dkr.ecr.ap-east-1.amazonaws.com/raytone-<svc>`
- tag：`uat-aws-hongkong-<sha7>-<ts>` + `latest-uat-aws-hongkong`
- 脚本(同目录)：`build-push-uat-aws-hongkong.sh`（**标准 Dockerfile，无国内源 mirror**）；自动发版 wrapper `deploy-on-push-uat-aws-hongkong.sh`
- 发布分支：`test`
- 目录布局：`/root/repo`（脚本 + 业务源码 + `iac/aws-eks-raytone-k8s`）；缺失源码自动 clone
- ArgoCD 刷新：`https://argocd.codesphere.run`

命令：

```bash
# 全量构建+推 ECR（不发版）
./build-push-uat-aws-hongkong.sh uat-aws-hongkong
# 单服务构建+推+回写清单+push GitLab（发版）
./build-push-uat-aws-hongkong.sh --deploy uat-aws-hongkong gateway
```

> ⚠️ 三个名字来源不同勿混：tag 前缀 `uat-aws-hongkong` · GitOps 目录 `uat-aws-hongkong` · ArgoCD app/ns 名 `*-uat-aws-hongkong`。

## 自动发版

- **已停用（2026-06-25）**：`raytone-webhook.service` stop+disable，`:9000` 不再监听（SG 规则未删）。
- 恢复：`deploy-on-push-uat-aws-hongkong.sh` + webhook listener（同 nprod 结构）。当前发版靠手动跑脚本。
