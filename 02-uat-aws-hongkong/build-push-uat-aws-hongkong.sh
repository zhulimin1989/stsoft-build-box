#!/bin/bash
# Build + push raytone images to AWS Hong Kong (ap-east-1) ECR for uat-aws-hongkong.
#
# 从 build-push-nprod-aws-beijing.sh 改写。HK 与 cn 的关键区别:
#   - 账号 654654182678 / 区 ap-east-1 / 标准分区后缀 amazonaws.com(非 .com.cn)
#   - HK 公网直连 docker.io/ghcr.io/pypi/goproxy → 用标准 Dockerfile,不需要国内源 mirror、
#     不需要 Dockerfile.china、不需要 GOPROXY=goproxy.cn / APT_MIRROR / ALPINE_MIRROR。
#   - tag 前缀 = ENV(默认 uat-aws-hongkong);GitOps 目录 = uat-aws-hongkong(2026-06 改名);
#     ArgoCD app/ns 名 = uat-aws-hongkong-<svc>(未随目录改名)。三者来源不同,勿混。
#   - GitOps 仓 ArgoCD 只读张家口阿里云 GitLab → --deploy 推 GitLab(ArgoCD 源,必达)。
#     构建机出口 EIP 需加入阿里云 GitLab 安全组白名单(见 deploy 文档 30-build-box-design)。
#
# Usage:
#   ./build-push-uat-aws-hongkong.sh                                   # env=uat-aws-hongkong, 全部 target, git pull
#   ./build-push-uat-aws-hongkong.sh --no-pull                         # 跳过 git pull
#   ./build-push-uat-aws-hongkong.sh --no-pull uat-aws-hongkong gateway
#   ./build-push-uat-aws-hongkong.sh --deploy uat-aws-hongkong gateway     # 构建+推+回写清单+push GitLab
#
# Targets(精确 CLI 名,15 个,与 ALL_TARGETS 一致):
#   gateway publisher tokenplatform-rawbody-consumer
#   codesphere-ops-user-api codesphere-ops-user-web
#   codesphere-ops-admin-api codesphere-ops-admin-web
#   codesphere-ops-billing-api codesphere-ops-billing-openapi raytone-landing
#   raytone-studio-api raytone-studio-web rdwork-backend rdwork-backend-migrate skill-plaza
#
#   省略所有 target = 构建全部并对「无 git 变更」跳过(源码缺失会自动 clone)。
#
#   ── 完整命令(复制粘贴)──
#   ① 全量构建+推 ECR(自动 clone 缺失源码 + git pull,无 git 变更则跳过,不发版):
#   ./build-push-uat-aws-hongkong.sh uat-aws-hongkong
#
#   ② 全量构建+推 ECR + 回写清单 + push GitLab(自动发版上线):
#   ./build-push-uat-aws-hongkong.sh --deploy uat-aws-hongkong gateway publisher tokenplatform-rawbody-consumer codesphere-ops-user-api codesphere-ops-user-web codesphere-ops-admin-api codesphere-ops-admin-web codesphere-ops-billing-api codesphere-ops-billing-openapi raytone-landing
#
#   ③ 强制重建全部(列出 target 即不跳过,只推 ECR 不发版):
#   ./build-push-uat-aws-hongkong.sh uat-aws-hongkong gateway publisher tokenplatform-rawbody-consumer codesphere-ops-user-api codesphere-ops-user-web codesphere-ops-admin-api codesphere-ops-admin-web codesphere-ops-billing-api codesphere-ops-billing-openapi raytone-landing
#
#   ④ 单服务发版:
#   ./build-push-uat-aws-hongkong.sh --deploy uat-aws-hongkong gateway
#
# 注:第一个位置参数是 ENV(默认 uat-aws-hongkong),其后才是 target —— 指定单服务时需先写 env,
#     例:`... uat-aws-hongkong gateway`(沿用 beijing 脚本的参数约定)。
#
# Defaults:
#   AWS account: 654654182678
#   Region:      ap-east-1
#   Profile:     (空 → 默认凭证链 / EC2 实例角色;笔记本可 PROFILE=<名> 覆盖)
#   Registry:    654654182678.dkr.ecr.ap-east-1.amazonaws.com
#   Branch:      uat(DO_PULL 时各仓 checkout + pull 此分支;GIT_BRANCH= 覆盖)
#
# Tag format:
#   <env>-<gitsha7>-<YYYYMMDD-HHMM>   (env=uat-aws-hongkong → uat-aws-hongkong-abc1234-20260618-1530)
#
# Notes:
#   - 目标平台 linux/amd64(对齐 EKS worker)。
#   - ECR repo 不存在则创建。
#   - 不带 --deploy 时只 build+push;清单需人工 review 后改(或用 --deploy 自动回写)。

set -euo pipefail

DO_PULL=1
UPDATE_K8S=0
DEPLOY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pull)
      DO_PULL=0
      shift
      ;;
    --deploy)
      # 自动发版:构建+推 ECR 后,回写 GitOps 清单 image.tag 并 push GitLab(必达),
      # 交由 ArgoCD uat-aws-hongkong auto-sync 上线。
      DEPLOY=1
      shift
      ;;
    --update-k8s)
      echo "✗ --update-k8s is disabled. 自动发版用 --deploy;手动场景请手改清单。"
      exit 1
      ;;
    --help|-h)
      # 两行简式用法(对齐 01-prod-aws-use1 的 --help);targets 从下方 ALL_TARGETS 行提取,改列表无需同步这里
      echo "用法: $0 [--deploy] [--no-pull] [ENV] <target...>   # 省略 target = 全部;ENV 默认 uat-aws-hongkong"
      echo "targets: $(sed -n 's/^ALL_TARGETS="\(.*\)"$/\1/p' "$0")"
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

ACCOUNT_ID="${ACCOUNT_ID:-654654182678}"
REGION="${REGION:-ap-east-1}"
PROFILE="${PROFILE-}"                          # 空 → 默认凭证链 / EC2 实例角色;笔记本可 PROFILE=<名> 覆盖
ECR_DNS_SUFFIX="${ECR_DNS_SUFFIX:-amazonaws.com}"
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.${ECR_DNS_SUFFIX}"
PLATFORM="${PLATFORM:-linux/amd64}"
GIT_BRANCH="${GIT_BRANCH:-uat}"                # UAT 环境拉 uat 分支;DO_PULL 时各仓 checkout + pull 此分支(GIT_BRANCH= 覆盖)

ENV_DIR="uat-aws-hongkong"                    # GitOps 目录(2026-06 改名;tag/app 名仍用 uat-aws-hongkong)
# ArgoCD child app 名 = servicename(对齐 aliyun-beijing,2026-06 去掉 uat-aws-hongkong- 前缀);ns 名仍是 raytone-uat-aws-hongkong

# ENV 位置参数**可选**(与 --help 里的 `[ENV]` 一致):只有 $1 恰好是环境名时才消费它,
# 其余情况 "$@" 全部当 target。旧写法是 ENV="${1:-uat-aws-hongkong}" + 无条件 shift,于是
# 「只列 target 不写 ENV」会把第一个 target 当 ENV,报 `✗ HK script only supports ENV=...`。
ENV="uat-aws-hongkong"
case "${1:-}" in
  uat-aws-hongkong) ENV="$1"; shift ;;
esac

# GITHUB_TOKEN 兜底:env 里没有就读 box 上的 ~/.github_token(RaytoneLAB read:packages PAT)。
# 拉 @raytone-lab/* 私有 npm 包的服务(publisher / codesphere-ops-billing-api 等)必须有它,否则 pnpm install 401。
if [ -z "${GITHUB_TOKEN:-}" ] && [ -r "$HOME/.github_token" ]; then
  GITHUB_TOKEN="$(cat "$HOME/.github_token")"
  export GITHUB_TOKEN
  echo "ⓘ GITHUB_TOKEN 未在环境中,已从 ~/.github_token 读取(供 @raytone-lab/* 私有包鉴权)"
fi

# 各 target → "源码目录|Dockerfile|build-args|ECR repo|GitOps values 路径"
# 相比 beijing:去掉 cn 国内源 mirror(APT/PIP/UV/GOPROXY=goproxy.cn/ALPINE_MIRROR),用标准 Dockerfile。
spec_of_target() {
  case "$1" in
    codesphere-ops-user-api)      echo "codesphere-user|Dockerfile.api||raytone-codesphere-ops-user-api|${ENV_DIR}/codesphere-ops-user-api/values.yaml" ;;
    # VITE_AUTH0_*:HK 内测期复用同一 dev tenant(见 deploy 文档 21-auth0);前端 SPA client_id 沿用 dev 租户值,正式上线前与独立 app 一起确认。
    codesphere-ops-user-web)      echo "codesphere-user|Dockerfile.web|--build-arg VITE_AUTH0_DOMAIN=dev-by01ng3didk64hkd.us.auth0.com --build-arg VITE_AUTH0_CLIENT_ID=s329xdVxBe8qnJmy42VvN0FqZXDJGyIS --build-arg VITE_AUTH0_DB_CONNECTION=Username-Password-Authentication --build-arg VITE_GTM_ID=GTM-TMRWS96V|raytone-codesphere-ops-user-web|${ENV_DIR}/codesphere-ops-user-web/values.yaml" ;;
    codesphere-ops-admin-api)     echo "codesphere-admin|Dockerfile.api||raytone-codesphere-ops-admin-api|${ENV_DIR}/codesphere-ops-admin-api/values.yaml" ;;
    codesphere-ops-admin-web)     echo "codesphere-admin|Dockerfile.web|--build-arg VITE_USER_APP_URL=https://platform.codesphere.run|raytone-codesphere-ops-admin-web|${ENV_DIR}/codesphere-ops-admin-web/values.yaml" ;;
    codesphere-ops-billing-api)   echo "codesphere-billing|Dockerfile||raytone-codesphere-ops-billing-api|${ENV_DIR}/codesphere-ops-billing-api/values.yaml" ;;
    # openapi 与 billing 同源码(codesphere-billing),换 Dockerfile.openapi(CMD=node dist/openapi-main.js,:3030)+ 独立 ECR 仓。
    codesphere-ops-billing-openapi)           echo "codesphere-billing|Dockerfile.openapi||raytone-codesphere-ops-billing-openapi|${ENV_DIR}/codesphere-ops-billing-openapi/values.yaml" ;;
    raytone-landing)              echo "raytone-landing|Dockerfile||raytone-landing|${ENV_DIR}/raytone-landing/values.yaml" ;;
    gateway)                      echo "tokenplatform-gateway|Dockerfile||raytone-gateway|${ENV_DIR}/gateway/values.yaml" ;;
    publisher)                    echo "tokenplatform-publisher|Dockerfile||raytone-publisher|${ENV_DIR}/publisher/values.yaml" ;;
    tokenplatform-rawbody-consumer) echo "tokenplatform-rawbody-consumer|Dockerfile||raytone-tokenplatform-rawbody-consumer|${ENV_DIR}/tokenplatform-rawbody-consumer/values.yaml" ;;
    # ── 以下 5 个为香港 UAT 首次接入(2026-09-01) ──
    # ★ raytone-studio-web 必须用 BUILD_MODE=public-saas-hk:上海的 public-saas-uat 与
    #   nprod 的 public-saas-test 把 VITE_SAAS_PORTAL_URL / VITE_SAAS_PURCHASE_URL 写死成
    #   各自环境的 IP:8082,是构建期编进产物的 —— 照抄会把香港用户导到另一个环境去登录/购买,
    #   而页面本身完全正常不报错。该 mode 文件已随本次上线加进 raytone-studio-frontend 的 uat 分支。
    raytone-studio-api)           echo "raytone-studio-backend|Dockerfile||raytone-studio-api|${ENV_DIR}/raytone-studio-api/values.yaml" ;;
    raytone-studio-web)           echo "raytone-studio-frontend|Dockerfile|--build-arg BUILD_MODE=public-saas-hk|raytone-studio-web|${ENV_DIR}/raytone-studio-web/values.yaml" ;;
    # ★★ rdwork 的两个 target 必须在**同一次 run** 内构建:k8s 侧 migrate Job 的镜像地址由
    #    rdwork-api/values.yaml 的同一个 image.tag 拼 <repo>-migrate:<tag>,两者 tag 一漂即
    #    ImagePullBackOff。同一次 run 内由 RUN_TS(提到循环外)保证时间戳一致。
    #    两个 target 都回写 rdwork-api + rdwork-gateway 两份 values(转发面复用主面的 tag)。
    rdwork-backend)               echo "rdwork-backend|Dockerfile||raytone-rdwork-backend|${ENV_DIR}/rdwork-api/values.yaml ${ENV_DIR}/rdwork-gateway/values.yaml" ;;
    rdwork-backend-migrate)       echo "rdwork-backend|Dockerfile|--target migrate|raytone-rdwork-backend-migrate|${ENV_DIR}/rdwork-api/values.yaml ${ENV_DIR}/rdwork-gateway/values.yaml" ;;
    # ★ PUBLIC_BASE_PATH 必须是**空串**(不是 "/"):Dockerfile 里是 VITE_BASE_PATH=${PUBLIC_BASE_PATH}/,
    #   填 "/" 会拼成 "//",浏览器按协议相对 URL 去请求主机名 "assets",页面资源全 404。
    skill-plaza)                  echo "skill-plaza-standalone|Dockerfile|--build-arg PUBLIC_BASE_PATH=|raytone-skill-plaza|${ENV_DIR}/skill-plaza/values.yaml" ;;
    codesphere-alerting)          echo "codesphere-alerting|Dockerfile.china|--build-arg ALPINE_MIRROR=dl-cdn.alpinelinux.org --build-arg GOPROXY=https://proxy.golang.org,direct|raytone-codesphere-alerting|${ENV_DIR}/codesphere-alerting/values.yaml" ;;
    *) echo ""; return 1 ;;
  esac
}

# ★★ RUN_TS 必须在循环**外**取一次:同一次 run 里所有镜像共用一个时间戳。
#    rdwork 的 runtime 与 -migrate 是两个 target,k8s 侧却共用同一个 image.tag
#    (Job 的地址由该 tag 拼 <repo>-migrate:<tag>) —— 若各自 date 一次,跨分钟边界就会
#    差 1 分钟,表现为 migrate Job ImagePullBackOff 而 runtime 正常。
#    可用 RUN_TS=<YYYYmmdd-HHMM> 覆盖(重跑撞 tag 时用)。
RUN_TS="${RUN_TS:-$(TZ=Asia/Hong_Kong date +%Y%m%d-%H%M)}"

ALL_TARGETS="gateway publisher tokenplatform-rawbody-consumer codesphere-ops-user-api codesphere-ops-user-web codesphere-ops-admin-api codesphere-ops-admin-web codesphere-ops-billing-api codesphere-ops-billing-openapi raytone-landing raytone-studio-api raytone-studio-web rdwork-backend rdwork-backend-migrate skill-plaza codesphere-alerting"

if [ $# -eq 0 ]; then
  TARGETS="$ALL_TARGETS"
  EXPLICIT_TARGETS=0
else
  TARGETS="$*"
  EXPLICIT_TARGETS=1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
# GitOps 仓:优先 repo 内的 iac/(build box 布局 /root/repo/iac),回退上级 ../iac(本机 agentsphere/repo 布局);K8S_REPO= 可覆盖
if [ -n "${K8S_REPO:-}" ]; then :
elif [ -d "${ROOT}/iac/aws-eks-raytone-k8s" ]; then K8S_REPO="${ROOT}/iac/aws-eks-raytone-k8s"
else K8S_REPO="${ROOT}/../iac/aws-eks-raytone-k8s"; fi

# 鉴权:有 PROFILE → 静态 profile(笔记本);PROFILE 留空 → 默认凭证链 / EC2 实例角色(构建机)。
# 构建机自动降级:指定的 profile 在本机不存在,但默认凭证链(实例角色)可用时,自动改用实例角色。
if [ -n "$PROFILE" ] && ! aws configure list-profiles 2>/dev/null | grep -qx "$PROFILE"; then
  echo "ⓘ profile '$PROFILE' 在本机不存在,改用默认凭证链(EC2 实例角色)"
  PROFILE=""
fi

AWS_AUTH=(--region "$REGION")
[ -n "$PROFILE" ] && { export AWS_PROFILE="$PROFILE"; AWS_AUTH+=(--profile "$PROFILE"); }

# HK 直接 docker login(profile 或实例角色都适用);不依赖 ecr-login 凭证助手。
echo "═══ HK ECR login (${PROFILE:-instance-role} @ $REGION) ═══"
aws ecr get-login-password "${AWS_AUTH[@]}" \
  | docker login --username AWS --password-stdin "$ECR_BASE"
echo ""

# ── BuildKit SSH 自举:带私有 git 依赖的服务走 SSH 拉取,
#    需把 ssh-agent 转发给 BuildKit(--ssh default)。有 agent → 原样用;box 裸跑无 agent → 自动起临时 agent。
SSH_AGENT_STARTED=0
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  SSH_KEY=""
  for k in "$HOME/.ssh/raytone_gitops_deploy" "$HOME/.ssh/id_ed25519_github_raytone_buildbox" "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
    [ -f "$k" ] && { SSH_KEY="$k"; break; }
  done
  if [ -n "$SSH_KEY" ]; then
    echo "ⓘ 无 ssh-agent,自动起临时 agent 并加载 $SSH_KEY(供 BuildKit --ssh)"
    eval "$(ssh-agent -s)" >/dev/null
    SSH_AGENT_STARTED=1
    trap '[ "$SSH_AGENT_STARTED" = 1 ] && ssh-agent -k >/dev/null 2>&1 || true' EXIT
    if ! ssh-add "$SSH_KEY" >/dev/null 2>&1; then
      echo "⚠ ssh-add 失败(key 可能带 passphrase),放弃 SSH 转发;带 git 依赖的服务会构建失败"
      ssh-agent -k >/dev/null 2>&1 || true
      unset SSH_AUTH_SOCK SSH_AGENT_PID
      SSH_AGENT_STARTED=0
    fi
  else
    echo "ⓘ 无 ssh-agent 且未找到 ~/.ssh/id_ed25519|id_rsa;带私有 git 依赖的服务会构建失败"
  fi
fi

ensure_repo() {
  local image="$1"
  if aws ecr describe-repositories "${AWS_AUTH[@]}" --repository-names "$image" >/dev/null 2>&1; then
    return 0
  fi
  echo "＋ create ECR repo: $image"
  aws ecr create-repository \
    "${AWS_AUTH[@]}" \
    --repository-name "$image" \
    --image-scanning-configuration scanOnPush=true \
    --tags Key=Project,Value=raytonelab Key=Environment,Value=nprod Key=Region,Value=ap-east-1 Key=ManagedBy,Value=build-push-hongkong \
    >/dev/null
}

patch_k8s_refs() {
  local image="$1"
  local ref="$2"
  local paths="$3"

  [ "$UPDATE_K8S" -eq 1 ] || return 0
  [ -d "$K8S_REPO" ] || { echo "✗ K8S_REPO not found: $K8S_REPO"; exit 1; }

  for rel in $paths; do
    local file="$K8S_REPO/$rel"
    if [ ! -f "$file" ]; then
      echo "! skip missing k8s manifest: $rel"
      continue
    fi
    echo "→ patch $rel image -> $ref"
    python3 - "$file" "$image" "$ref" <<'PYINNERSCRIPT'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
image = sys.argv[2]
ref = sys.argv[3]
tag = ref.rsplit(':', 1)[1]
repo = ref.rsplit('/', 1)[1].rsplit(':', 1)[0]
s = path.read_text()

# Helm values(gateway/publisher/rawbody 等)是 image.repository + image.tag,不是 k8s `image:` 标量,只改 tag。
if path.name == 'values.yaml' and re.search(r'^image:\s*$', s, re.M):
    ns, n = re.subn(r'(^\s*tag:\s*).+$', rf'\g<1>{tag}', s, count=1, flags=re.M)
    if n == 0:
        raise SystemExit(f'no image.tag line in values.yaml: {path}')
    path.write_text(ns)
    sys.exit(0)

patterns = [
    rf'(image:\s*)[^\s#]*(?:{re.escape(image)}|raytone-{re.escape(image)}|{re.escape(image.replace("raytone-", ""))})[^\s#]*',
]

for pat in patterns:
    ns = re.sub(pat, rf'\g<1>{ref}', s)
    if ns != s:
        path.write_text(ns)
        sys.exit(0)

ns = re.sub(r'(image:\s*)\S+', rf'\g<1>{ref}', s, count=1)
if ns == s:
    raise SystemExit(f'no image line found in {path}')
path.write_text(ns)
PYINNERSCRIPT
  done
}

ARGOCD_FILE="${ARGOCD_FILE:-$HOME/.argocd_nudge}"
# 推送后即时让 ArgoCD 刷新对应 app,消除 ~3min 轮询延迟。$@ = app 名;best-effort,绝不阻断发版。
# /root/.argocd_nudge:第1行 server URL(如 https://argocd.codesphere.run),第2行 admin 密码;缺则跳过。
argocd_refresh() {
  [ "$#" -gt 0 ] || return 0
  [ -r "$ARGOCD_FILE" ] || return 0
  local srv pw tok app
  srv="$(sed -n 1p "$ARGOCD_FILE")"; pw="$(sed -n 2p "$ARGOCD_FILE")"
  [ -n "$srv" ] && [ -n "$pw" ] || return 0
  tok="$(curl -s -m 10 -X POST "$srv/api/v1/session" -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys;print(json.dumps({"username":"admin","password":sys.argv[1]}))' "$pw")" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
  [ -n "$tok" ] || { echo "  ⚠ ArgoCD 登录失败,跳过即时刷新(等自动轮询)"; return 0; }
  for app in "$@"; do
    if curl -s -m 15 -H "Authorization: Bearer $tok" "$srv/api/v1/applications/${app}?refresh=hard" >/dev/null 2>&1; then
      echo "  ⟳ 已触发 ArgoCD 刷新 $app"
    else
      echo "  ⚠ ArgoCD 刷新 $app 失败(等自动轮询)"
    fi
  done
}

# 自动发版收尾:flock 串行下,拉最新 GitOps → 逐 spec patch image.tag → commit → push GitLab(必达)。
deploy_manifests() {
  [ "$DEPLOY" -eq 1 ] || return 0
  [ "${#DEPLOY_SPECS[@]}" -gt 0 ] || { echo "⊘ deploy: 无成功构建,跳过清单回写"; return 0; }
  [ -d "$K8S_REPO/.git" ] || { echo "✗ deploy: GitOps 仓不是 git clone: $K8S_REPO"; return 1; }
  echo ""
  echo "═══ deploy: 回写 GitOps 清单 + push GitLab═══"
  (
    flock 9
    cd "$K8S_REPO"
    git checkout --quiet main 2>/dev/null || git checkout -t gitlab/main
    git pull --rebase --quiet gitlab main || { echo "✗ git pull --rebase 失败"; exit 1; }
    local addpaths=() spec image rest ref paths
    UPDATE_K8S=1
    for spec in "${DEPLOY_SPECS[@]}"; do
      image="${spec%%|*}"; rest="${spec#*|}"
      ref="${rest%%|*}"; paths="${rest#*|}"
      patch_k8s_refs "$image" "$ref" "$paths"
      addpaths+=($paths)
    done
    git add "${addpaths[@]}"
    if git diff --cached --quiet; then
      echo "  (清单无变化,跳过 commit/push)"; exit 0
    fi
    git commit --quiet -m "${ENV_DIR} auto-deploy: ${DEPLOY_SPECS[*]%%|*}"
    # GitLab 是 ArgoCD 的源,push 必达。push 被拒(并发:别的 bot 在我 pull 后又推了)→ 再 pull --rebase
    # 把本次提交叠到最新 → 重推,最多 5 次;**只走 fast-forward,绝不 force,不覆盖别人的提交**;rebase 冲突则放弃交人工。
    _n=0
    until git push --quiet gitlab HEAD:main; do
      _n=$((_n+1)); [ "$_n" -ge 5 ] && { echo "✗ GitLab push 重试 5 次仍失败"; exit 1; }
      echo "  ⟳ push 被拒(远端有新提交),pull --rebase 后重试($_n/5)"
      git pull --rebase --quiet gitlab main || { echo "✗ rebase 冲突,放弃(需人工解决,未 force)"; exit 1; }
    done
    echo "  ✓ commit + push GitLab 完成"
  ) 9>/tmp/raytone-gitops.lock
  # 推完即时戳 ArgoCD 刷新对应 app(app 名 = servicename,= K8S_PATHS 里的 chart 目录名)
  local nudge=() spec p svc
  for spec in "${DEPLOY_SPECS[@]}"; do
    for p in ${spec##*|}; do
      svc="${p#*/}"; svc="${svc%%/*}"        # 去掉 env 目录前缀 + 取首段 = 服务名
      nudge+=("${svc}")
    done
  done
  argocd_refresh "${nudge[@]}"
}

PUSHED_REFS=()
DEPLOY_SPECS=()
SKIPPED_TARGETS=()

# 本地清理:push 成功后删掉刚推的本地 tag(registry 已有,本地留着只占盘)。
# best-effort,绝不因清理失败中断发版(脚本 set -e)。
prune_local_image() {
  local ref
  for ref in "$@"; do
    [ -n "${ref:-}" ] && docker image rm "$ref" >/dev/null 2>&1 || true
  done
  return 0
}

for TARGET in $TARGETS; do
  SPEC="$(spec_of_target "$TARGET")" || { echo "✗ unknown target: $TARGET"; echo "  (ENV 只能是 uat-aws-hongkong,且必须放在所有 target 之前;--help 看可用 target)"; exit 1; }

  DIR="${SPEC%%|*}"; REST="${SPEC#*|}"
  DOCKERFILE="${REST%%|*}"; REST="${REST#*|}"
  BUILD_ARGS="${REST%%|*}"; REST="${REST#*|}"
  IMAGE="${REST%%|*}"; K8S_PATHS="${REST#*|}"

  CTX="${ROOT}/${DIR}"
  # 源码缺失则自动 clone(github raytone-lab/<dir>,走 box 的 PAT credential);已存在则下面 DO_PULL 负责更新
  if [ ! -d "$CTX/.git" ]; then
    echo "─── [$IMAGE] 源码缺失,clone https://github.com/raytone-lab/${DIR}.git ───"
    rm -rf "$CTX"
    git clone -q "${SRC_REPO_BASE:-https://github.com/raytone-lab}/${DIR}.git" "$CTX"
  fi
  [ -f "${CTX}/${DOCKERFILE}" ] || { echo "✗ Dockerfile not found: ${CTX}/${DOCKERFILE}"; exit 1; }

  ensure_repo "$IMAGE"

  cd "$CTX"

  SHA_BEFORE=""
  if [ "$DO_PULL" -eq 1 ]; then
    SHA_BEFORE="$(git rev-parse HEAD 2>/dev/null || echo "")"
    echo "─── [$IMAGE] checkout + pull origin/$GIT_BRANCH ───"
    git fetch origin "$GIT_BRANCH" --quiet
    git checkout "$GIT_BRANCH" 2>/dev/null || git checkout -t "origin/$GIT_BRANCH"
    git pull --ff-only
    echo ""

    if [ "$EXPLICIT_TARGETS" -eq 0 ]; then
      SHA_AFTER="$(git rev-parse HEAD 2>/dev/null || echo "")"
      if [ -n "$SHA_BEFORE" ] && [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then
        echo "⊘ [$IMAGE] no git update (HEAD: ${SHA_AFTER:0:7}), skip build/push"
        SKIPPED_TARGETS+=("$IMAGE @ ${SHA_AFTER:0:7}")
        cd "$ROOT"
        echo ""
        continue
      fi
    fi
  fi

  SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || echo nogit)"
  # 构建身份(BUILD_SHA):gateway 自 a3ad7fb 起在 Dockerfile 里 fail-closed 校验 40 位小写全 SHA,
  # 并 -ldflags 注入 buildinfo.CommitSHA(用量事件 producer_build_sha 的来源)。统一对所有 target 传;
  # 未声明 ARG BUILD_SHA 的 Dockerfile 只会打一条 unused build-arg 警告。
  FULL_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"
  if grep -qE '^[[:space:]]*ARG[[:space:]]+BUILD_SHA' "$DOCKERFILE" \
     && ! printf '%s\n' "$FULL_SHA" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "✗ [$IMAGE] $DOCKERFILE 要求 BUILD_SHA(40 位小写全 SHA),当前工作副本取到的是:'${FULL_SHA}'"
    exit 1
  fi
  TS="$RUN_TS"   # 全 run 统一(见文件上方 RUN_TS 的说明)。原先在此处 date 一次:rdwork 的
                 # runtime 与 -migrate 是两个 target,跨分钟边界就会差 1 分钟,而 k8s 侧两者
                 # 共用同一个 image.tag ⟹ migrate Job ImagePullBackOff 而 runtime 正常。
  TAG_SHA="${ENV}-${SHA}-${TS}"
  REF_SHA="${ECR_BASE}/${IMAGE}:${TAG_SHA}"

  SSH_FLAG=()
  [ -n "${SSH_AUTH_SOCK:-}" ] && SSH_FLAG=(--ssh default)

  SECRET_FLAG=()
  [ -n "${GITHUB_TOKEN:-}" ] && SECRET_FLAG=(--secret id=github_token,env=GITHUB_TOKEN)

  echo "═══ [$IMAGE] build -> HK ECR (platform: $PLATFORM, tag: $TAG_SHA) ═══"
  # shellcheck disable=SC2086
  docker build \
    --platform "$PLATFORM" \
    "${SSH_FLAG[@]}" \
    "${SECRET_FLAG[@]}" \
    -f "$DOCKERFILE" \
    --build-arg BUILD_SHA="$FULL_SHA" \
    --build-arg GIT_SHA="$FULL_SHA" \
    $BUILD_ARGS \
    -t "$REF_SHA" \
    .

  echo ""
  echo "═══ [$IMAGE] push $TAG_SHA ═══"
  docker push "$REF_SHA"

  PUSHED_REFS+=("$REF_SHA")
  if [ "$DEPLOY" -eq 1 ]; then
    DEPLOY_SPECS+=("${IMAGE}|${REF_SHA}|${K8S_PATHS}")
  else
    patch_k8s_refs "$IMAGE" "$REF_SHA" "$K8S_PATHS"
  fi

  prune_local_image "$REF_SHA"

  cd "$ROOT"
  echo "✓ $IMAGE: $TAG_SHA done"
  echo ""
done

deploy_manifests

echo "═══════════════════════════════════════════════════════════════"
if [ "${#PUSHED_REFS[@]}" -eq 0 ]; then
  echo "⊘ no images pushed"
else
  echo "✓ HK ECR push complete (${#PUSHED_REFS[@]} images)"
  for ref in "${PUSHED_REFS[@]}"; do
    echo "  - $ref"
  done
fi

if [ "${#SKIPPED_TARGETS[@]}" -gt 0 ]; then
  echo ""
  echo "⊘ skipped (${#SKIPPED_TARGETS[@]}):"
  for item in "${SKIPPED_TARGETS[@]}"; do
    echo "  - $item"
  done
fi

echo ""
if [ "$DEPLOY" -eq 1 ]; then
  echo "Deploy: 清单已回写并 push GitLab,ArgoCD uat-aws-hongkong 将自动同步。"
else
  echo "Next: review the pushed refs above, then update uat-aws-hongkong manifests manually (或用 --deploy 自动回写)。"
fi

# 收尾:清 7 天前的 build cache + 悬空镜像,防缓存无上限膨胀。best-effort。
echo "═══ 本地清理:build cache(>7d) + dangling ═══"
docker image prune -f >/dev/null 2>&1 || true
docker builder prune -f --filter until=168h >/dev/null 2>&1 || true
echo "  ✓ 本地清理完成($(df -h / | awk 'NR==2{print $4" free, "$5}'))"
