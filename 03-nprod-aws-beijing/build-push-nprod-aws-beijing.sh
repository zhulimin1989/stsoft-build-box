#!/bin/bash
# Build + push raytone images to AWS China Beijing ECR for nprod.
#
# This script is intentionally separate from build-push.sh so China nprod
# publishing cannot accidentally affect the existing commercial AWS/prod flow.
#
# Usage:
#   ./build-push-china.sh                              # env=nprod, all targets, git pull enabled
#   ./build-push-china.sh --no-pull                    # skip git pull
#
# Targets (exact CLI names, all 15):
#   gateway
#   publisher
#   tokenplatform-rawbody-consumer
#   codesphere-ops-user-api
#   codesphere-ops-user-web
#   codesphere-ops-admin-api
#   codesphere-ops-admin-web
#   codesphere-ops-billing-api
#   codesphere-ops-billing-openapi
#   raytone-landing
#   raytone-studio-api
#   raytone-studio-web
#   rdwork-backend                  # 主面+转发面共用的 runtime 镜像
#   rdwork-backend-migrate          # 同 Dockerfile --target migrate;drizzle 迁移专用
#   skill-plaza                     # 智能体广场;PUBLIC_BASE_PATH 必须传空串(见 spec 注释)
#
# ★ rdwork 的两个 target 必须成对构建(deploy-on-push 已按仓名映射成对)：
#   chart 里 Job 的镜像是用 image.tag 拼 <repo>-migrate:<tag>,两者 tag 必须一致。
#   同一次 run 内由 RUN_TS 保证;分两次单独跑会产出不同时间戳而对不上。
#
# Repo shortcuts are not accepted as targets:
#   codesphere-user    -> codesphere-ops-user-api codesphere-ops-user-web
#   codesphere-admin   -> codesphere-ops-admin-api codesphere-ops-admin-web
#   codesphere-billing -> codesphere-ops-billing-api codesphere-ops-billing-openapi
#
#   Omit all targets to build every service with skip-on-no-git-change.
#   Copy-paste to force-rebuild all 15 (no skip):
#   ./build-push-nprod-aws-beijing.sh nprod gateway publisher tokenplatform-rawbody-consumer codesphere-ops-user-api codesphere-ops-user-web codesphere-ops-admin-api codesphere-ops-admin-web codesphere-ops-billing-api codesphere-ops-billing-openapi raytone-landing raytone-studio-api raytone-studio-web rdwork-backend rdwork-backend-migrate skill-plaza
#
# Defaults:
#   AWS account: 550022519931
#   Region:      cn-north-1
#   Profile:     isoftstone-china-self
#   Registry:    550022519931.dkr.ecr.cn-north-1.amazonaws.com.cn
#   Branch:      test (DO_PULL 时各仓 checkout + pull 此分支;GIT_BRANCH= 覆盖)
#
# Tag format:
#   <env>-<gitsha7>-<YYYYMMDD-HHMM>
#
# Notes:
#   - Target platform is linux/amd64 for current EKS worker nodes.
#   - Repositories are created if missing.
#   - This script only builds and pushes images; update manifests manually after review.

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
      # 自动发版:构建+推 ECR 后,回写 GitOps 清单 image.tag 并 push GitLab,
      # 交由 ArgoCD nprod auto-sync 上线。供 deploy-on-push.sh / webhook 链路使用。
      DEPLOY=1
      shift
      ;;
    --update-k8s)
      echo "✗ --update-k8s is disabled. 自动发版用 --deploy;手动场景请手改清单。"
      exit 1
      ;;
    --help|-h)
      # 两行简式用法(对齐 01-prod-aws-use1 的 --help);targets 从下方 ALL_TARGETS 行提取,改列表无需同步这里
      echo "用法: $0 [--deploy] [--no-pull] [ENV] <target...>   # 省略 target = 全部;ENV 默认 nprod"
      echo "targets: $(sed -n 's/^ALL_TARGETS="\(.*\)"$/\1/p' "$0")"
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

ACCOUNT_ID="${ACCOUNT_ID:-550022519931}"
REGION="${REGION:-cn-north-1}"
PROFILE="${PROFILE-isoftstone-china-self}"   # 置空(PROFILE= ...)则改用 EC2 实例角色(构建机),不传 --profile
ECR_DNS_SUFFIX="${ECR_DNS_SUFFIX:-amazonaws.com.cn}"
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.${ECR_DNS_SUFFIX}"
PLATFORM="${PLATFORM:-linux/amd64}"
GIT_BRANCH="${GIT_BRANCH:-test}"   # 测试环境分支;DO_PULL 时各仓 checkout + pull 此分支(GIT_BRANCH= 覆盖)
BUILD_TIMEOUT="${BUILD_TIMEOUT:-30m}"   # 单个 docker build 上限:上游镜像源抖动(如 apk 拉 chromium)重试挂死时快速失败,置空/覆盖见下

# ENV 位置参数**可选**(与 --help 里的 `[ENV]` 一致):只有 $1 恰好是环境名时才消费它,
# 其余情况 "$@" 全部当 target。旧写法是 ENV="${1:-nprod}" + 无条件 shift,于是
# 「只列 target 不写 ENV」会把第一个 target 当 ENV,报 `✗ China script only supports ENV=...`。
ENV="nprod"
case "${1:-}" in
  nprod) ENV="$1"; shift ;;
esac

# GITHUB_TOKEN 兜底:env 里没有就读 box 上的 token 文件(~/.github_token,RaytoneLAB read:packages PAT)。
# 这样无论交互 shell / 老 shell / 非交互(cron、ssh 带命令)都能拿到,不依赖 .bashrc 是否被 source。
# 拉 @raytone-lab/* 私有 npm 包的服务(publisher / codesphere-ops-billing-api 等)必须有它,否则 pnpm install 401。
if [ -z "${GITHUB_TOKEN:-}" ] && [ -r "$HOME/.github_token" ]; then
  GITHUB_TOKEN="$(cat "$HOME/.github_token")"
  export GITHUB_TOKEN
  echo "ⓘ GITHUB_TOKEN 未在环境中,已从 ~/.github_token 读取(供 @raytone-lab/* 私有包鉴权)"
fi

spec_of_target() {
  case "$1" in
    codesphere-ops-user-api)      echo "codesphere-user|Dockerfile.api||raytone-codesphere-ops-user-api|nprod-aws-beijing/codesphere-ops-user-api/values.yaml" ;;
    codesphere-ops-user-web)      echo "codesphere-user|Dockerfile.web|--build-arg VITE_AUTH0_DOMAIN=dev-by01ng3didk64hkd.us.auth0.com --build-arg VITE_AUTH0_CLIENT_ID=s329xdVxBe8qnJmy42VvN0FqZXDJGyIS --build-arg VITE_AUTH0_DB_CONNECTION=Username-Password-Authentication --build-arg VITE_GTM_ID=GTM-TMRWS96V|raytone-codesphere-ops-user-web|nprod-aws-beijing/codesphere-ops-user-web/values.yaml" ;;
    codesphere-ops-admin-api)     echo "codesphere-admin|Dockerfile.api||raytone-codesphere-ops-admin-api|nprod-aws-beijing/codesphere-ops-admin-api/values.yaml" ;;
    codesphere-ops-admin-web)     echo "codesphere-admin|Dockerfile.web|--build-arg VITE_USER_APP_URL=http://43.196.147.233:8082|raytone-codesphere-ops-admin-web|nprod-aws-beijing/codesphere-ops-admin-web/values.yaml" ;;
    codesphere-ops-billing-api)   echo "codesphere-billing|Dockerfile||raytone-codesphere-ops-billing-api|nprod-aws-beijing/codesphere-ops-billing-api/values.yaml" ;;
    # openapi 与 billing 同源码(codesphere-billing),换 Dockerfile.openapi.china(CMD=node dist/openapi-main.js,:3030)+ 独立 ECR 仓。
    codesphere-ops-billing-openapi)           echo "codesphere-billing|Dockerfile.openapi.china||raytone-codesphere-ops-billing-openapi|nprod-aws-beijing/codesphere-ops-billing-openapi/values.yaml" ;;
    raytone-landing)              echo "raytone-landing|Dockerfile||raytone-landing|nprod-aws-beijing/raytone-landing/values.yaml" ;;
    # Raytone Studio(产品 slug raytone-studio)前后端。两个 Dockerfile 自带国内镜像源
    # (daocloud / npmmirror / 清华),不需要 China 专用 Dockerfile。
    raytone-studio-api)           echo "raytone-studio-backend|Dockerfile||raytone-studio-api|nprod-aws-beijing/raytone-studio-api/values.yaml" ;;
    # 前端产物按环境编译进镜像:nprod 走 test 分支 → BUILD_MODE=public-saas-test(对应 .env.public-saas-test)。
    # 漏掉这个 build-arg 会默认构出 private-test 产物,接口地址全错。
    raytone-studio-web)           echo "raytone-studio-frontend|Dockerfile|--build-arg BUILD_MODE=public-saas-test|raytone-studio-web|nprod-aws-beijing/raytone-studio-web/values.yaml" ;;
    # RDWORK:一个源码仓、两个进程入口(主面 dist/server.js + 转发面 dist/gateway-server.js),
    # 两面共用同一个 runtime 镜像,只在 k8s 里换 command。所以 runtime 这个 target 要同时
    # 回写两个 chart 的 values.yaml(K8S_PATHS 支持空格分隔多路径)。
    # Dockerfile 需要 BuildKit(# syntax= / --mount=type=cache / heredoc),box 已具备。
    rdwork-backend)               echo "rdwork-backend|Dockerfile||raytone-rdwork-backend|nprod-aws-beijing/rdwork-api/values.yaml nprod-aws-beijing/rdwork-gateway/values.yaml" ;;
    # 迁移镜像:同 Dockerfile 换 stage(--target migrate)。必须单独出镜像,因为 runtime 段只装
    # 生产依赖而 drizzle-kit 是 devDependency,用 runtime 跑迁移会找不到命令。
    # ★ 回写的两个路径与上面一致:chart 里 Job 的镜像地址是用 image.tag 拼 <repo>-migrate:<tag>,
    #   不另设字段。因此两个 target 必须产出相同 tag —— 这靠 TS 在循环外统一计算来保证(见下)。
    rdwork-backend-migrate)       echo "rdwork-backend|Dockerfile|--target migrate|raytone-rdwork-backend-migrate|nprod-aws-beijing/rdwork-api/values.yaml nprod-aws-beijing/rdwork-gateway/values.yaml" ;;
    # 智能体广场(SkillPlaza):单进程全包 —— 一个 Node 进程同时提供前端页面 + /api + skill zip。
    # ★ PUBLIC_BASE_PATH 必须传**空串**,不能传 "/"。Dockerfile 里是
    #   VITE_BASE_PATH=${PUBLIC_BASE_PATH}/ —— 传 "/" 会拼成 "//",vite 的 base 变 "//",
    #   浏览器按协议相对 URL 解析,去请求主机名 "assets",页面资源全 404。
    #   传空 → VITE_BASE_PATH=/(根路径)、VITE_API_BASE_URL=''(同源)、服务端 BASE=''(API 在 /api)。
    #   nprod 是裸 IP + 高端口的 L4 透传,没有 /plaza 这层路径,所以要根路径。
    # 基础镜像是 alpine,build-box 会自动注入 dl-cdn→mirrors.aliyun.com 的改写。
    skill-plaza)                  echo "skill-plaza-standalone|Dockerfile|--build-arg PUBLIC_BASE_PATH=|raytone-skill-plaza|nprod-aws-beijing/skill-plaza/values.yaml" ;;
    gateway)                      echo "tokenplatform-gateway|Dockerfile.china|--build-arg ALPINE_MIRROR=mirrors.aliyun.com --build-arg GOPROXY=https://goproxy.cn,direct|raytone-gateway|nprod-aws-beijing/gateway/values.yaml" ;;
    publisher)                    echo "tokenplatform-publisher|Dockerfile.china|--build-arg PUBLISHER_BUILDER_IMAGE=${PUBLISHER_BUILDER_IMAGE:-public.ecr.aws/docker/library/golang:1.25} --build-arg RUNTIME_IMAGE=${PUBLISHER_RUNTIME_IMAGE:-public.ecr.aws/docker/library/alpine:3.20} --build-arg GOPROXY=https://goproxy.cn,direct|raytone-publisher|nprod-aws-beijing/publisher/values.yaml" ;;
    tokenplatform-rawbody-consumer) echo "tokenplatform-rawbody-consumer|Dockerfile.china|--build-arg GOPROXY=https://goproxy.cn,direct|raytone-tokenplatform-rawbody-consumer|nprod-aws-beijing/tokenplatform-rawbody-consumer/values.yaml" ;;
    codesphere-alerting)          echo "codesphere-alerting|Dockerfile.china|--build-arg ALPINE_MIRROR=mirrors.aliyun.com --build-arg GOPROXY=https://goproxy.cn,direct|raytone-codesphere-alerting|nprod-aws-beijing/codesphere-alerting/values.yaml" ;;
    *) echo ""; return 1 ;;
  esac
}

ALL_TARGETS="gateway publisher tokenplatform-rawbody-consumer codesphere-ops-user-api codesphere-ops-user-web codesphere-ops-admin-api codesphere-ops-admin-web codesphere-ops-billing-api codesphere-ops-billing-openapi raytone-landing raytone-studio-api raytone-studio-web rdwork-backend rdwork-backend-migrate skill-plaza codesphere-alerting"
# Default target set mirrors prod business services. Apps still remain gated by
# nprod app-of-apps enabled=false until images/dependencies are ready.

if [ $# -eq 0 ]; then
  TARGETS="$ALL_TARGETS"
  EXPLICIT_TARGETS=0
else
  TARGETS="$*"
  EXPLICIT_TARGETS=1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
K8S_REPO="${K8S_REPO:-${ROOT}/../iac/aws-eks-raytone-k8s}"

# 鉴权:有 PROFILE → 静态 profile(笔记本备用);PROFILE 留空 → EC2 实例角色(构建机)。
# 构建机自动降级:指定的 profile 在本机不存在,但默认凭证链(实例角色)可用时,自动改用实例角色,
# 这样在 box 上裸跑 ./build-push-china.sh 即可,无需记得前置 PROFILE=。
if [ -n "$PROFILE" ] && ! aws configure list-profiles 2>/dev/null | grep -qx "$PROFILE"; then
  echo "ⓘ profile '$PROFILE' 在本机不存在,改用默认凭证链(EC2 实例角色)"
  PROFILE=""
fi

AWS_AUTH=(--region "$REGION")
if [ -n "$PROFILE" ]; then
  export AWS_PROFILE="$PROFILE"
  AWS_AUTH+=(--profile "$PROFILE")
  echo "═══ China ECR login ($PROFILE @ $REGION) ═══"
  aws ecr get-login-password "${AWS_AUTH[@]}" \
    | docker login --username AWS --password-stdin "$ECR_BASE"
  echo ""
else
  # 构建机:ecr-login 凭证助手已配 $ECR_BASE → 自动取 token,无需显式 docker login。
  echo "═══ China ECR @ $REGION:走实例角色 + ecr-login 凭证助手(免 docker login)═══"
  echo ""
fi

# ── BuildKit SSH 自举:带私有 git 依赖的服务在 cn 走 SSH 拉取,
#    需要把 ssh-agent 转发给 BuildKit(下面 docker build 的 --ssh default)。
#    已有 agent(笔记本)→ 原样用;box 上裸跑没 agent → 自动起临时 agent 并加载本机 key,
#    退出时回收。这样在 box 上无需手动 eval ssh-agent 即可构建带 git 依赖的服务。
SSH_AGENT_STARTED=0
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  SSH_KEY=""
  # 优先 raytoneLAB 专用 key(github 身份统一为 raytoneLAB,不用个人号),再回退本机默认 key
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
    --tags Key=Project,Value=raytonelab Key=Environment,Value=nprod Key=Region,Value=cn-north-1 Key=ManagedBy,Value=build-push-china \
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

# Helm values files for gateway/publisher/rawbody keep image.repository + image.tag,
# not a Kubernetes `image:` scalar. Patch only the tag there.
if path.name == 'values.yaml' and re.search(r'^image:\s*$', s, re.M):
    # block 风格(image:\n  repository: <静态>\n  tag: <变>)。只改 tag,改完立即退出,
    # 绝不穿透到下面的 fallback 正则(那段 `(image:\s*)` 会贪婪吞掉换行+缩进、改坏 image 块)。
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

# Fallback: replace the first Kubernetes image line in this manifest file.
ns = re.sub(r'(image:\s*)\S+', rf'\g<1>{ref}', s, count=1)
if ns == s:
    raise SystemExit(f'no image line found in {path}')
path.write_text(ns)
PYINNERSCRIPT
  done
}

ARGOCD_FILE="${ARGOCD_FILE:-$HOME/.argocd_nudge}"
# 推送后即时让 ArgoCD 刷新对应 app,消除其 ~3min 轮询延迟。$@ = app 名;best-effort,绝不阻断发版。
# 配置 /root/.argocd_nudge:第1行 server URL,第2行 admin 密码;缺则跳过(退回 ArgoCD 自动轮询)。
argocd_server() { sed -n 1p "$ARGOCD_FILE" 2>/dev/null; }
# 登录取 token。失败返回空串,调用方自行降级。
argocd_token() {
  local srv pw
  srv="$(argocd_server)"; pw="$(sed -n 2p "$ARGOCD_FILE" 2>/dev/null)"
  [ -n "$srv" ] && [ -n "$pw" ] || return 0
  curl -s -m 10 -X POST "$srv/api/v1/session" -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"username":"admin","password":sys.argv[1]}))' "$pw")" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null
}

argocd_refresh() {
  [ "$#" -gt 0 ] || return 0
  [ -r "$ARGOCD_FILE" ] || return 0
  local srv tok app
  srv="$(argocd_server)"
  tok="$(argocd_token)"
  [ -n "$tok" ] || { echo "  ⚠ ArgoCD 登录失败,跳过即时刷新(等自动轮询)"; return 0; }
  for app in "$@"; do
    if curl -fsS -m 15 -H "Authorization: Bearer $tok" "$srv/api/v1/applications/${app}?refresh=hard" >/dev/null 2>&1; then
      echo "  ⟳ 已触发 ArgoCD 刷新 $app"
    else
      echo "  ⚠ ArgoCD 刷新 $app 失败(等自动轮询)"
    fi
  done
}

# 发版健康闸门:推完清单后轮询 ArgoCD,直到 app 变成 Synced+Healthy。
# 超时仍不健康 → 记入 HEALTH_FAILED_APPS,脚本最终 exit 1,由 deploy-on-push 发钉钉红告警。
# 存在意义:镜像推成功 ≠ pod 起得来。启动预检失败、迁移未 apply、OOM、探针不过
# 都会让新 RS 卡死而旧 pod 继续服务(半滚),此前这种情况一律被报成"发版成功"。
ARGOCD_HEALTH_TIMEOUT="${ARGOCD_HEALTH_TIMEOUT:-300}"   # 秒;0=关闭闸门
ARGOCD_HEALTH_INTERVAL="${ARGOCD_HEALTH_INTERVAL:-10}"
argocd_wait_healthy() {
  [ "$#" -gt 0 ] || return 0
  [ "$ARGOCD_HEALTH_TIMEOUT" -gt 0 ] || { echo "  ⊘ 健康闸门已关闭(ARGOCD_HEALTH_TIMEOUT=0)"; return 0; }
  [ -r "$ARGOCD_FILE" ] || { echo "  ⚠ 无 ArgoCD 凭据,跳过健康闸门"; return 0; }
  local srv tok app deadline health sync detail
  srv="$(argocd_server)"
  tok="$(argocd_token)"
  [ -n "$tok" ] || { echo "  ⚠ ArgoCD 登录失败,跳过健康闸门"; return 0; }
  echo ""
  echo "═══ deploy: 健康闸门(最长 ${ARGOCD_HEALTH_TIMEOUT}s)═══"
  local code
  for app in "$@"; do
    # 先分清"ArgoCD 里没这个 app"和"app 没起来"。工作负载在 app-of-apps 里 enabled=false 时
    # 压根不存在对应 Application(如未开启的 raytone-studio-api/web),下面的轮询会空转到超时
    # 再判失败 → 每次 push 都发一条钉钉红告警。404 直接跳过并打印原因;其它状态照常走闸门。
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 15 -H "Authorization: Bearer $tok" \
      "$srv/api/v1/applications/${app}" 2>/dev/null)"
    if [ "$code" = "404" ]; then
      echo "  ⊘ $app 在 ArgoCD 中不存在(app-of-apps enabled=false?),跳过健康闸门"
      echo "    镜像已推、清单 tag 已回写;开 enabled=true 后即按此 tag 上线"
      continue
    fi
    deadline=$(( $(date +%s) + ARGOCD_HEALTH_TIMEOUT ))
    while :; do
      # 单次 curl 取 health/sync,python 解析;网络抖动按 unknown 处理并继续重试。
      read -r health sync <<<"$(curl -fsS -m 15 -H "Authorization: Bearer $tok" \
        "$srv/api/v1/applications/${app}" 2>/dev/null \
        | python3 -c 'import sys,json
try:
    s = json.load(sys.stdin).get("status", {})
    print(s.get("health", {}).get("status", "Unknown"), s.get("sync", {}).get("status", "Unknown"))
except Exception:
    print("Unknown Unknown")' 2>/dev/null)"
      health="${health:-Unknown}"; sync="${sync:-Unknown}"
      if [ "$health" = "Healthy" ] && [ "$sync" = "Synced" ]; then
        echo "  ✓ $app 已 Synced+Healthy"
        break
      fi
      if [ "$(date +%s)" -ge "$deadline" ]; then
        # 超时:把不健康的资源列出来,直接进钉钉正文,省一轮人工排查。
        detail="$(curl -fsS -m 15 -H "Authorization: Bearer $tok" \
          "$srv/api/v1/applications/${app}" 2>/dev/null \
          | python3 -c 'import sys,json
try:
    rs = json.load(sys.stdin).get("status", {}).get("resources", []) or []
except Exception:
    rs = []
bad = ["%s/%s=%s" % (r.get("kind"), r.get("name"), (r.get("health") or {}).get("status", "?"))
       for r in rs if (r.get("health") or {}).get("status") not in (None, "Healthy")]
print("; ".join(bad[:6]) or "(无资源级明细)")' 2>/dev/null)"
        echo "  ✗ $app 超时未健康: sync=$sync health=$health"
        echo "    不健康资源: ${detail:-(取不到)}"
        HEALTH_FAILED_APPS+=("${app}(sync=$sync,health=$health;${detail:-?})")
        break
      fi
      sleep "$ARGOCD_HEALTH_INTERVAL"
    done
  done
}

# 自动发版收尾:在 flock 串行下,拉最新 GitOps → 逐 spec patch image.tag → commit → push GitLab。
# 只在 --deploy 且有成功构建时执行。patch 全部在锁内+pull --rebase 后做,避免并发非快进冲突。
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
    UPDATE_K8S=1   # 子shell 内开启 patch_k8s_refs
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
    git commit --quiet -m "nprod-aws-beijing auto-deploy: ${DEPLOY_SPECS[*]%%|*}"
    # GitLab 是 ArgoCD 的源,push 必达。
    git push --quiet gitlab HEAD:main || { echo "✗ GitLab push 失败"; exit 1; }
    echo "  ✓ commit + push GitLab 完成"
  ) 9>/tmp/raytone-gitops.lock
  # 推完即时戳 ArgoCD 刷新对应 app(app 名 = <svc>,由 K8S_PATHS 推导),省掉轮询延迟
  local nudge=() spec p svc
  for spec in "${DEPLOY_SPECS[@]}"; do
    for p in ${spec##*|}; do
      svc="${p#*/}"; svc="${svc%%/*}"
      nudge+=("${svc}")
    done
  done
  argocd_refresh "${nudge[@]}"
  argocd_wait_healthy "${nudge[@]}"
}

# 用 =() 初始化(非仅 declare),否则 set -u 下指定单 target 时末尾 ${#数组[@]} 会报 unbound
PUSHED_REFS=()
DEPLOY_SPECS=()
HEALTH_FAILED_APPS=()   # 健康闸门未通过的 app;非空则脚本 exit 1

SKIPPED_TARGETS=()
TMP_DOCKERFILES=()

# tag 时间戳:整个 run 统一算一次(北京时间;box 系统时区为 UTC)。
# ★ 必须在循环外:同一个源码仓出多个镜像时(如 rdwork-backend 的 runtime 与 -migrate),
#   两者 sha7 相同,只有 TS 会因跨分钟而不同。而 rdwork 的 chart 里 Job 镜像是用同一个
#   image.tag 拼 <repo>-migrate:<tag> 的,tag 一漂就 ImagePullBackOff。
# ★★ 可由环境变量覆盖:deploy-on-push 是**每个 target 调一次本脚本**的,单靠"循环外"
#    不足以让同仓多镜像对齐,必须由调用方为整个仓传同一个 RUN_TS(见 deploy-on-push)。
RUN_TS="${RUN_TS:-$(TZ=Asia/Shanghai date +%Y%m%d-%H%M)}"

cleanup_tmp_dockerfiles() {
  local f
  for f in "${TMP_DOCKERFILES[@]:-}"; do
    [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
  done
  return 0   # 空数组时上面短路成非零;EXIT trap 末状态非零会让整脚本 exit 1(被 deploy-on-push 误判失败)
}
trap cleanup_tmp_dockerfiles EXIT

# 本地清理:push 成功后删掉刚推的本地 tag(registry 已有,本地留着只占盘)。
# best-effort,绝不因清理失败中断发版(脚本 set -e)。
prune_local_image() {
  local ref
  for ref in "$@"; do
    [ -n "${ref:-}" ] && docker image rm "$ref" >/dev/null 2>&1 || true
  done
  return 0
}

prepare_dockerfile() {
  # 对以 alpine 为基础镜像的 target,在每个 `FROM *alpine*` 之后注入一行 apk 源改写
  # (dl-cdn.alpinelinux.org → mirrors.aliyun.com):国内直连 dl-cdn 传大包(如 chromium,
  # 依赖 ~376MB)会涓流/中途卡死,换阿里云镜像即可。生成临时 Dockerfile,路径经 stdout 返回,
  # 由调用方登记进 TMP_DOCKERFILES 于 EXIT 清理(本函数在 $() 子 shell 内,回写数组不可达父作用域)。
  # 非 alpine 的 Dockerfile 原样返回。诊断信息一律走 stderr,stdout 只输出最终 Dockerfile 路径。
  local target="$1"
  local ctx="$2"
  local dockerfile="$3"

  if ! grep -qiE '^FROM[[:space:]]+[^[:space:]]*alpine' "$dockerfile"; then
    printf '%s\n' "$dockerfile"
    return 0
  fi

  local tmp=".Dockerfile.aliapk.$$.${target}"
  awk '
    { print }
    $1 == "FROM" && $2 ~ /alpine/ {
      print "RUN sed -i \047s#dl-cdn.alpinelinux.org#mirrors.aliyun.com#g\047 /etc/apk/repositories 2>/dev/null || true"
    }
  ' "$dockerfile" > "$tmp"
  echo "ⓘ [$target] 注入 alpine 源改写 dl-cdn→mirrors.aliyun.com(临时 Dockerfile: $tmp)" >&2
  printf '%s\n' "$tmp"
  return 0
}
for TARGET in $TARGETS; do
  SPEC="$(spec_of_target "$TARGET")" || { echo "✗ unknown target: $TARGET"; echo "  (ENV 只能是 nprod,且必须放在所有 target 之前;--help 看可用 target)"; exit 1; }

  DIR="${SPEC%%|*}"; REST="${SPEC#*|}"
  DOCKERFILE="${REST%%|*}"; REST="${REST#*|}"
  BUILD_ARGS="${REST%%|*}"; REST="${REST#*|}"
  IMAGE="${REST%%|*}"; K8S_PATHS="${REST#*|}"

  CTX="${ROOT}/${DIR}"
  [ -d "$CTX" ] || { echo "✗ source dir not found: $CTX"; exit 1; }
  [ -f "${CTX}/${DOCKERFILE}" ] || { echo "✗ Dockerfile not found: ${CTX}/${DOCKERFILE}"; exit 1; }

  ensure_repo "$IMAGE"

  cd "$CTX"

  SHA_BEFORE=""
  if [ "$DO_PULL" -eq 1 ]; then
    SHA_BEFORE="$(git rev-parse HEAD 2>/dev/null || echo "")"
    echo "─── [$IMAGE] fetch + reset --hard origin/$GIT_BRANCH ───"
    # per-repo flock(按源码目录 $DIR,非 $IMAGE):同源多 target(如 billing 的 api/openapi)
    # 与重叠的自动发版 run 会并发操作同一工作副本;串行化 git 操作,避免竞态踩坏
    # FETCH_HEAD / index(曾致 "Cannot rebase onto multiple branches" 发版失败)。
    # 用 fetch + reset --hard 而非 pull:确定性对齐远端,免疫 pull.rebase 与多分支 FETCH_HEAD。
    (
      flock 8
      git fetch origin "$GIT_BRANCH" --quiet
      # 切到 China 业务分支(本地无则按 origin 建跟踪分支);已在则 no-op
      git checkout "$GIT_BRANCH" 2>/dev/null || git checkout -t "origin/$GIT_BRANCH"
      git reset --hard "origin/$GIT_BRANCH"
    ) 8>"/tmp/raytone-repo-${DIR}.lock"
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
  # 构建身份(BUILD_SHA):tokenplatform-gateway 自 a3ad7fb 起在 Dockerfile 里 fail-closed 校验
  # 40 位小写全 SHA,并用 -ldflags 注入 buildinfo.CommitSHA —— 用量事件的 producer_build_sha
  # 靠它溯源到产出该事件的代码。对所有 target 统一传入:未声明 ARG BUILD_SHA 的 Dockerfile
  # 会忽略它(仅一条 unused build-arg 警告),将来别的仓加同样的护栏也就自动生效。
  # 同时以 GIT_SHA 再传一份:rdwork-backend 的 Dockerfile 声明的是 ARG GIT_SHA(写进
  # dist/.buildstamp)。名字不同但语义相同,两个都传,各仓认哪个用哪个。不传则该仓
  # buildstamp 的 head 保持 null(如实,不致命,但丢了「跑的是哪份代码」的溯源)。
  FULL_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"
  # 声明了 ARG BUILD_SHA 的仓,这里先自查一遍:比让 docker build 抛 grep 退出码好定位。
  if grep -qE '^[[:space:]]*ARG[[:space:]]+BUILD_SHA' "$DOCKERFILE" \
     && ! printf '%s\n' "$FULL_SHA" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "✗ [$IMAGE] $DOCKERFILE 要求 BUILD_SHA(40 位小写全 SHA),当前工作副本取到的是:'${FULL_SHA}'"
    exit 1
  fi
  TS="$RUN_TS"   # 整个 run 统一的时间戳,见上方 RUN_TS 的说明(同仓多镜像必须同 tag)
  TAG_SHA="${ENV}-${SHA}-${TS}"
  REF_SHA="${ECR_BASE}/${IMAGE}:${TAG_SHA}"

  # 有 ssh-agent 时把 SSH 转发给 BuildKit(saas 的 git 依赖在 cn 走 SSH 拉取需要);
  # 无 agent(笔记本/普通服务)则不加,Dockerfile 里 type=ssh,required=false 会自动跳过。
  SSH_FLAG=()
  [ -n "${SSH_AUTH_SOCK:-}" ] && SSH_FLAG=(--ssh default)

  # GitHub Packages 私有 npm 包(@raytone-lab/*)鉴权:把 GITHUB_TOKEN 作为 secret 喂给
  # BuildKit 的 --mount=type=secret,id=github_token。有 token 才传;没有则不传,
  # 纯 OSS 依赖的服务(gateway/publisher/landing 等)照常构建,Dockerfile 里读不到 secret
  # 就拿到空 token,只有用到私有包的 node 服务才会因此 401。
  SECRET_FLAG=()
  [ -n "${GITHUB_TOKEN:-}" ] && SECRET_FLAG=(--secret id=github_token,env=GITHUB_TOKEN)

  DOCKERFILE_TO_USE="$(prepare_dockerfile "$TARGET" "$CTX" "$DOCKERFILE")"
  # prepare_dockerfile 在 $() 子 shell 内无法回写 TMP_DOCKERFILES,故在此父作用域登记临时件(绝对路径)供 EXIT 清理
  [ "$DOCKERFILE_TO_USE" != "$DOCKERFILE" ] && TMP_DOCKERFILES+=("${CTX}/${DOCKERFILE_TO_USE}")

  echo "═══ [$IMAGE] build -> China ECR (platform: $PLATFORM, tag: $TAG_SHA, timeout: ${BUILD_TIMEOUT:-off}) ═══"
  # timeout 包住 build:上游镜像源(alpine CDN 等)抖动会让单步(如 apk add chromium)重试
  # 挂死数小时,曾制造并发窗口触发上面的 git 竞态。到点 TERM、宽限 60s 再 KILL,
  # set -e 下非零退出即让该 target 快速失败,而非静默挂起。BUILD_TIMEOUT= 置空则不限时。
  # shellcheck disable=SC2086
  ${BUILD_TIMEOUT:+timeout --signal=TERM --kill-after=60s "$BUILD_TIMEOUT"} docker build \
    --platform "$PLATFORM" \
    "${SSH_FLAG[@]}" \
    "${SECRET_FLAG[@]}" \
    -f "$DOCKERFILE_TO_USE" \
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
    DEPLOY_SPECS+=("${IMAGE}|${REF_SHA}|${K8S_PATHS}")   # 延迟到 deploy_manifests 锁内统一 patch
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
  echo "✓ China ECR push complete (${#PUSHED_REFS[@]} images)"
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
if [ "${#HEALTH_FAILED_APPS[@]}" -gt 0 ]; then
  echo "✗ 发版健康闸门未通过(镜像已推、清单已回写,但新 pod 没起来):"
  for item in "${HEALTH_FAILED_APPS[@]}"; do
    echo "  - $item"
  done
  echo "  排查:kubectl -n raytone-nprod get pods | grep <svc>;kubectl logs <新 RS 的 pod>"
  echo "  回滚:改回 GitOps 仓上一版 image tag 并 push,或 kubectl rollout undo"
fi

if [ "$DEPLOY" -eq 1 ]; then
  echo "Deploy: 清单已回写并 push GitLab,ArgoCD nprod 将自动同步。"
else
  echo "Next: review the pushed refs above, then update nprod manifests manually (或用 --deploy 自动回写)。"
fi

# 收尾:清 7 天前的 build cache + 悬空镜像,防缓存无上限膨胀。best-effort。
echo "═══ 本地清理:build cache(>7d) + dangling ═══"
docker image prune -f >/dev/null 2>&1 || true
docker builder prune -f --filter until=168h >/dev/null 2>&1 || true
echo "  ✓ 本地清理完成($(df -h / | awk 'NR==2{print $4" free, "$5}'))"

# 健康闸门未过 → 非零退出,让 deploy-on-push 把这次记成失败并发钉钉红告警。
[ "${#HEALTH_FAILED_APPS[@]}" -eq 0 ] || exit 1
