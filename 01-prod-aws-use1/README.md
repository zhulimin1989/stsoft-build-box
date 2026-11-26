# Build-Box · prod-aws-use1（AWS 美东生产）

美东生产镜像构建，推 us-east-1 ECR。

## 构建机（当前在用）

> 机器仍在用；仅围绕它的「双 region 架构」已废弃。私网 `172.31.35.46` 即各 prod-use1 发版输出里的 `root@ip-172-31-35-46` 提示符。

| 项 | 值 |
|---|---|
| 实例 ID | `i-0bb45e5486f88d268`（c7i.xlarge 4C8G，Ubuntu 24.04 x86_64，100G gp3） |
| **公网 IP / EIP** | **`98.94.222.6`**（`raytone-build-box-eip`，固定，stop/start 不变） |
| 私网 IP | `172.31.35.46` |
| VPC / 子网 | default `vpc-052f6c11591e63ab6` · `subnet-059cc622ffec9dee1`（us-east-1a） |
| 安全组 | `sg-0737f5fc3836aa2a2`（入站 tcp/22 → `0.0.0.0/0`，仅密钥登录） |
| IAM 角色 | `raytone-build-box`（ECR 推送 `raytone-*` + SSM） |
| Region · 账号 · profile | us-east-1 · `654654182678` · `bedrock-us` |
| 主用 / 备用 | box 走**实例角色**（ecr-login 助手自动取 token）；笔记本备用前置 `AWS_PROFILE=bedrock-us` |

### 接入 / 启停

```bash
ssh root@98.94.222.6        # 免密；ubuntu@98.94.222.6 亦可（NOPASSWD sudo）
aws ssm start-session --profile bedrock-us --region us-east-1 --target i-0bb45e5486f88d268   # 兜底
# 省钱启停（EIP 固定，start 后 IP 不变）
aws ec2 stop-instances  --profile bedrock-us --region us-east-1 --instance-ids i-0bb45e5486f88d268
aws ec2 start-instances --profile bedrock-us --region us-east-1 --instance-ids i-0bb45e5486f88d268
```

### 重建（本目录脚本）

`setup-iam.sh`（建 IAM 角色 + instance profile）· `user-data.sh`（Ubuntu 24.04 开机引导 docker/git/ecr-helper/gh）· `ecr-push-policy.json`（最小 ECR 推送权限，限 `raytone-*`）。（原双 region 废弃目录已删除，本目录为这些脚本的唯一存放处。）

## 镜像仓库

- `654654182678.dkr.ecr.us-east-1.amazonaws.com/raytone-<svc>`
- tag：`prod-<sha7>-<ts>` + `latest-prod`
- push 后 **CRR 自动复制到 ap-southeast-1**
- NAT 出口 EIP（vendor 白名单）：`54.227.131.77` / `3.215.240.207` / `18.214.217.211`

## 构建 / 发版

- 脚本(同目录)：`build-push-prod-aws-use1.sh`（12 个 target；`all` 或显式列全）
- **发布分支：`prod`**（脚本 spec 里各 target 发布分支硬编码为 prod，构建前强制 checkout + ff 拉最新）
- 前端 build-arg：user-web 带 `VITE_AUTH0_*`（dev-by01ng3didk64hkd）
- 时间戳用北京时区（box 时钟 UTC）

命令：

```bash
./build-push-prod-aws-use1.sh all                            # 全部 12 个
./build-push-prod-aws-use1.sh codesphere-ops-billing-openapi # 单个
AWS_PROFILE=bedrock-us ./build-push-prod-aws-use1.sh gateway  # 笔记本备用
```

## 发版链路

- 只 build+push ECR；GitOps `image.tag` 回写 + `git push gitlab main` 另行操作（无 GHA、无 webhook 自动发版，Day-2）。
- ArgoCD（prod-use1 集群内）拉张家口 GitLab 后 sync。

## 备注

- 品牌链接：host `platform.raytone.ai` → origin 推导得 `raytone.ai`，**无需 override**。
