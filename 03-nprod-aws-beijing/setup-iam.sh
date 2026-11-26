#!/usr/bin/env bash
# 创建中国区构建机用的 IAM 角色 + 实例配置(instance profile)。
# 只授予「推送 + 自动建 raytone-* ECR 仓」最小权限,外加 SSM(兜底连机)。
# 用法:./setup-iam.sh        (依赖同目录 ecr-push-policy.json)
#
# 与美东版差异(aws-cn 分区):
#   - SSM 托管策略 ARN 用 arn:aws-cn:...,照搬 arn:aws:... 会报「策略不存在」。
#   - profile/region 默认指向中国区。
set -euo pipefail

PROFILE="${AWS_PROFILE:-isoftstone-china-self}"
REGION="${REGION:-cn-north-1}"
ROLE="raytone-build-box"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== 1) 建角色(EC2 可担任)=="
aws iam create-role --role-name "$ROLE" --profile "$PROFILE" \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' >/dev/null 2>&1 && echo "  角色已建" || echo "  角色已存在,跳过"

echo "== 2) 挂 ECR 推送内联策略 =="
aws iam put-role-policy --role-name "$ROLE" --policy-name ecr-push \
  --policy-document "file://${HERE}/ecr-push-policy.json" --profile "$PROFILE"

echo "== 3) 挂 SSM 托管策略(aws-cn 分区 ARN)=="
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws-cn:iam::aws:policy/AmazonSSMManagedInstanceCore --profile "$PROFILE"

echo "== 4) 建 instance profile 并把角色塞进去 =="
aws iam create-instance-profile --instance-profile-name "$ROLE" --profile "$PROFILE" >/dev/null 2>&1 \
  && echo "  instance profile 已建" || echo "  已存在,跳过"
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" \
  --profile "$PROFILE" >/dev/null 2>&1 && echo "  角色已加入" || echo "  已在其中,跳过"

echo ""
echo "完成。启动 EC2 时用:  --iam-instance-profile Name=${ROLE}"
