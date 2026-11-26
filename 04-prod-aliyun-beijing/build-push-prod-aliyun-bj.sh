#!/bin/bash
# Build + push raytone images to Aliyun Beijing ACR for prod-aliyun-beijing.
#
# This script is intentionally separate from build-push.sh and build-push-china.sh
# so Aliyun Beijing prod publishing cannot affect AWS prod or aws-cn nprod flows.
#
# Usage:
#   ./build-push-prod-aliyun-bj.sh                                 # all targets; 每次构建前 pull 最新 origin/prod
#   ./build-push-prod-aliyun-bj.sh --no-pull                       # skip git pull, 只用本地代码构建
#   ./build-push-prod-aliyun-bj.sh gateway raytone-landing         # selected targets; 同样会先 pull 最新 prod
#   ./build-push-prod-aliyun-bj.sh --deploy gateway                # build + push + patch GitOps + push GitLab
#   ACR_ENSURE_REPO=1 ./build-push-prod-aliyun-bj.sh gateway       # 仅当需要脚本自动检查/创建 ACR repo 时使用
#   BUILD_PROXY=http://172.17.0.1:7890 ./build-push-prod-aliyun-bj.sh gateway        
#                                                                  # 让 docker build RUN 步骤走 box 上 mihomo(见 mihomo-proxy.md)
#                                                                  # 官方源(pypi/github)走代理、国内 mirror 仍直连;仅构建期,不进镜像
#
# Raytone Studio 三件套首次上线(ACR 里三个 repo 都还不存在):
#   ACR_ENSURE_REPO=1 ./build-push-prod-aliyun-bj.sh skill-plaza raytone-studio-api raytone-studio-web
#
# Targets (exact CLI names) — 前 10 个在 ALL_TARGETS 里(不带参数即全量):
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
#
# 以下 3 个**只能显式指名**构建,刻意不在 ALL_TARGETS 里(理由见 ALL_TARGETS 处注释):
#   raytone-studio-api               # 仓 raytone-studio-backend(FastAPI+alembic)
#   raytone-studio-web               # 仓 raytone-studio-frontend(Vite+nginx);BUILD_MODE=public-saas-prod
#   skill-plaza                      # 仓 skill-plaza-standalone;PUBLIC_BASE_PATH 必须传空串
#
# Repo shortcuts are not accepted as targets:
#   codesphere-user  -> codesphere-ops-user-api codesphere-ops-user-web
#   codesphere-admin -> codesphere-ops-admin-api codesphere-ops-admin-web
#
# Defaults:
#   ACR instance: cri-bcaf32kdltboox4l
#   Region:       cn-beijing
#   Registry:     raytone-prod-aliyun-bj-acr-registry-vpc.cn-beijing.cr.aliyuncs.com
#   Namespace:    raytone-prod
#   GitOps env:   prod-aliyun-beijing
#   Platform:     linux/amd64
#
# Auth:
#   1. If ACR_USER / ACR_PASS are set, use them.
#   2. Else read ACR_AUTH_FILE (default: ~/.acr_prod_aliyun_bj.json) with fields:
#        {"username":"...","password":"..."}
#
# Tag format:
#   prod-<gitsha7>-<YYYYMMDD-HHMM>   # 与 prod / prod-aliyun-beijing manifest 口径一致
#
# Branch policy:
#   - 默认从各业务仓 prod 分支拉代码构建(正式发布分支)
#   - 默认动作是: git fetch origin prod -> git checkout prod -> git pull --ff-only origin prod
#   - 只有显式传 --no-pull 时，才跳过拉最新代码
#   - 镜像 tag 前缀仍固定为 prod，source branch 和 deploy tag 解耦
#
# Notes:
#   - Build in Beijing should stay on linux/amd64 to match ACK node arch.
#   - Gateway, Publisher, rawbody-consumer, and codesphere-user use dedicated China Dockerfiles for Beijing builds.
#   - ACR repo 默认认为已预创建；只有显式传 ACR_ENSURE_REPO=1 才调用 aliyun cr API 做检查/建仓。
#   - 北京 ACR 开了 tag 不可变策略，因此这里只 push 唯一 tag，不再 push latest-prod。
#   - This script only touches prod-aliyun-beijing GitOps values when --deploy is set.

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
      DEPLOY=1
      shift
      ;;
    --update-k8s)
      echo "✗ --update-k8s is disabled. 自动发版请用 --deploy；手动场景请手改清单。"
      exit 1
      ;;
    --help|-h)
      # 两行简式用法(对齐 01-prod-aws-use1 的 --help)。前 10 个从下方 ALL_TARGETS 行提取(改列表无需同步这里);
      # 后 3 个是 case 支持但刻意不在 ALL_TARGETS 的 Studio 三件套(不带参数的全量发版不含它们,须显式指名)
      echo "用法: $0 [--deploy] [--no-pull] <target...>   # 省略 target = 全量(仅 ALL_TARGETS 的 10 个)"
      echo "targets: $(sed -n 's/^ALL_TARGETS="\(.*\)"$/\1/p' "$0") raytone-studio-api raytone-studio-web skill-plaza   # 后 3 个不在 ALL_TARGETS,只能显式指名构建"
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

ACR_INSTANCE_ID="${ACR_INSTANCE_ID:-cri-bcaf32kdltboox4l}"
REGION="${REGION:-cn-beijing}"
ACR_REGISTRY="${ACR_REGISTRY:-raytone-prod-aliyun-bj-acr-registry-vpc.cn-beijing.cr.aliyuncs.com}"
ACR_NAMESPACE="${ACR_NAMESPACE:-raytone-prod}"
ACR_AUTH_FILE="${ACR_AUTH_FILE:-$HOME/.acr_prod_aliyun_bj.json}"
PLATFORM="${PLATFORM:-linux/amd64}"
IMAGE_TAG_PREFIX="${IMAGE_TAG_PREFIX:-prod}"
ACR_ENSURE_REPO="${ACR_ENSURE_REPO:-0}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_K8S_REPO="${ROOT}/../iac/aws-eks-raytone-k8s"
if [ -d "${ROOT}/iac/aws-eks-raytone-k8s/.git" ]; then
  DEFAULT_K8S_REPO="${ROOT}/iac/aws-eks-raytone-k8s"
fi
K8S_REPO="${K8S_REPO:-$DEFAULT_K8S_REPO}"
GITOPS_ENV_DIR="${GITOPS_ENV_DIR:-prod-aliyun-beijing}"
GITOPS_BRANCH="${GITOPS_BRANCH:-main}"
# ArgoCD 只读张家口 GitLab → manifest 仓 pull/push 都走 GitLab、必达。
GITOPS_PRIMARY_REMOTE="${GITOPS_PRIMARY_REMOTE:-gitlab}"
ARGOCD_FILE="${ARGOCD_FILE:-$HOME/.argocd_nudge}"

# GitHub Packages 私有包兜底：没显式传环境变量时，优先读取 box 本地 token 文件。
if [ -z "${GITHUB_TOKEN:-}" ] && [ -r "$HOME/.github_token" ]; then
  GITHUB_TOKEN="$(cat "$HOME/.github_token")"
  export GITHUB_TOKEN
  echo "ⓘ GITHUB_TOKEN 未在环境中，已从 ~/.github_token 读取"
fi

read_acr_field() {
  local field="$1"
  local file="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg field "$field" '.[$field] // empty' "$file"
  else
    python3 - "$field" "$file" <<'PY'
import json
import sys
field, path = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)
print(data.get(field, ''))
PY
  fi
}

acr_login() {
  local user="${ACR_USER:-}"
  local pass="${ACR_PASS:-}"

  if [ -z "$user" ] || [ -z "$pass" ]; then
    if [ ! -r "$ACR_AUTH_FILE" ]; then
      echo "✗ 缺少 ACR 凭据：请设置 ACR_USER/ACR_PASS，或准备 $ACR_AUTH_FILE"
      exit 1
    fi
    user="$(read_acr_field username "$ACR_AUTH_FILE")"
    pass="$(read_acr_field password "$ACR_AUTH_FILE")"
  fi

  [ -n "$user" ] || { echo "✗ ACR 用户名为空"; exit 1; }
  [ -n "$pass" ] || { echo "✗ ACR 密码为空"; exit 1; }

  echo "═══ ACR login ($ACR_REGISTRY) ═══"
  docker login --username "$user" --password-stdin "$ACR_REGISTRY" <<< "$pass"
  echo ""
}

spec_of_target() {
  case "$1" in
    codesphere-ops-user-api)        echo "codesphere-user|Dockerfile.api.china||raytone-codesphere-ops-user-api|${GITOPS_ENV_DIR}/codesphere-ops-user-api/values.yaml|prod" ;;
    codesphere-ops-user-web)        echo "codesphere-user|Dockerfile.web.china|--build-arg VITE_AUTH0_DOMAIN=dev-by01ng3didk64hkd.us.auth0.com --build-arg VITE_AUTH0_CLIENT_ID=60h5PvKRaNyq3G2d7ZmlQl9DEKJuvgHY --build-arg VITE_AUTH0_DB_CONNECTION=Username-Password-Authentication --build-arg VITE_GTM_ID=GTM-TMRWS96V|raytone-codesphere-ops-user-web|${GITOPS_ENV_DIR}/codesphere-ops-user-web/values.yaml|prod" ;;
    codesphere-ops-admin-api)       echo "codesphere-admin|Dockerfile.api.china||raytone-codesphere-ops-admin-api|${GITOPS_ENV_DIR}/codesphere-ops-admin-api/values.yaml|prod" ;;
    codesphere-ops-admin-web)       echo "codesphere-admin|Dockerfile.web.china|--build-arg VITE_USER_APP_URL=https://platform.iruidong.com|raytone-codesphere-ops-admin-web|${GITOPS_ENV_DIR}/codesphere-ops-admin-web/values.yaml|prod" ;;
    codesphere-ops-billing-api)     echo "codesphere-billing|Dockerfile.china||raytone-codesphere-ops-billing-api|${GITOPS_ENV_DIR}/codesphere-ops-billing-api/values.yaml|prod" ;;
    codesphere-ops-billing-openapi) echo "codesphere-billing|Dockerfile.openapi.china||raytone-codesphere-ops-billing-openapi|${GITOPS_ENV_DIR}/codesphere-ops-billing-openapi/values.yaml|prod" ;;
    raytone-landing)                echo "raytone-landing|Dockerfile|${RAYTONE_LANDING_BUILD_ARGS:-}|raytone-landing|${GITOPS_ENV_DIR}/raytone-landing/values.yaml|prod" ;;
    gateway)                        echo "tokenplatform-gateway|Dockerfile.china|--build-arg ALPINE_MIRROR=mirrors.aliyun.com --build-arg GOPROXY=https://goproxy.cn,direct|raytone-gateway|${GITOPS_ENV_DIR}/gateway/values.yaml|prod" ;;
    publisher)                      echo "tokenplatform-publisher|Dockerfile.china|--build-arg PUBLISHER_BUILDER_IMAGE=${PUBLISHER_BUILDER_IMAGE:-public.ecr.aws/docker/library/golang:1.25} --build-arg RUNTIME_IMAGE=${PUBLISHER_RUNTIME_IMAGE:-public.ecr.aws/docker/library/alpine:3.20} --build-arg GOPROXY=https://goproxy.cn,direct|raytone-publisher|${GITOPS_ENV_DIR}/publisher/values.yaml|prod" ;;
    tokenplatform-rawbody-consumer) echo "tokenplatform-rawbody-consumer|Dockerfile.china|--build-arg GOPROXY=https://goproxy.cn,direct|raytone-tokenplatform-rawbody-consumer|${GITOPS_ENV_DIR}/tokenplatform-rawbody-consumer/values.yaml|prod" ;;
    # ── 智能体广场:单进程全包(前端页面 + /api + skill zip),一个镜像 ──
    # ★ PUBLIC_BASE_PATH 必须传**空串**,不能传 "/" —— Dockerfile 里是
    #   VITE_BASE_PATH=${PUBLIC_BASE_PATH}/,传 "/" 会拼成 "//",vite base 变 "//",
    #   浏览器按协议相对 URL 去请求主机名 "assets",页面资源全 404。
    # ★ Dockerfile 依赖 npmmirror 改 sharp/libvips 下载源(默认已设),否则 npm ci 必失败。
    skill-plaza)                    echo "skill-plaza-standalone|Dockerfile|--build-arg PUBLIC_BASE_PATH=|raytone-skill-plaza|${GITOPS_ENV_DIR}/skill-plaza/values.yaml|prod" ;;
    # ── Raytone Studio(产品 slug raytone-studio)前后端 ──
    # 两个 Dockerfile 自带国内镜像源(daocloud / npmmirror / 清华),没有也不需要 .china 变体。
    raytone-studio-api)             echo "raytone-studio-backend|Dockerfile||raytone-studio-api|${GITOPS_ENV_DIR}/raytone-studio-api/values.yaml|prod" ;;
    # ★★ 前端把目标环境产物**编译进镜像**,必须显式给 BUILD_MODE。本环境是 public-saas-prod
    #    (对应前端仓的 .env.public-saas-prod)。
    #    · 漏掉 → 默认构出 private-test 产物,接口地址全错
    #    · 抄成 public-saas-uat/-test → VITE_SAAS_PORTAL_URL / VITE_SAAS_PURCHASE_URL 是
    #      构建期编死的,生产用户点「平台门户 / 购买」会跳到上海 UAT 或 nprod,
    #      而页面本身完全正常、控制台无报错 —— 最难发现的一类配置错。
    raytone-studio-web)             echo "raytone-studio-frontend|Dockerfile|--build-arg BUILD_MODE=${STUDIO_WEB_BUILD_MODE:-public-saas-prod}|raytone-studio-web|${GITOPS_ENV_DIR}/raytone-studio-web/values.yaml|prod" ;;
    *) echo ""; return 1 ;;
  esac
}

# ★★ Studio 三件套(raytone-studio-api / raytone-studio-web / skill-plaza)**刻意不在**
#    这个列表里,只能显式指名构建。两个原因,都会让不带参数的全量发版直接崩:
#    1) 脚本对每个 target 做 `[ -d "$CTX" ] || exit 1`(CTX=脚本同级的仓目录)——
#       这三个仓在本 box 上还没 clone,进了全量列表就会让整条既有 prod 发版链路 exit 1。
#    2) 第 6 个字段是硬编码的 `prod` 分支,而当前:
#       · raytone-studio-backend / -frontend 的 origin/prod 还停在初始化 commit(eb5c162)
#       · skill-plaza-standalone **连 prod 分支都没有**(只有 test / uat)
#       ⟹ `git checkout -t origin/prod` 会失败。
#    前置补齐(仓已 clone + prod 分支已建 + 首轮镜像已验)之后,再把三个名字并入本列表。
ALL_TARGETS="gateway publisher tokenplatform-rawbody-consumer codesphere-ops-user-api codesphere-ops-user-web codesphere-ops-admin-api codesphere-ops-admin-web codesphere-ops-billing-api codesphere-ops-billing-openapi raytone-landing"

if [ $# -eq 0 ]; then
  TARGETS="$ALL_TARGETS"
  EXPLICIT_TARGETS=0
else
  TARGETS="$*"
  EXPLICIT_TARGETS=1
fi

acr_namespace_exists() {
  aliyun cr get-namespace \
    --region "$REGION" \
    --instance-id "$ACR_INSTANCE_ID" \
    --namespace-name "$ACR_NAMESPACE" \
    >/dev/null 2>&1
}

ensure_repo() {
  local image="$1"
  if aliyun cr get-repository \
    --region "$REGION" \
    --instance-id "$ACR_INSTANCE_ID" \
    --repo-name "$image" \
    --repo-namespace-name "$ACR_NAMESPACE" \
    >/dev/null 2>&1; then
    return 0
  fi

  echo "＋ create ACR repo: ${ACR_NAMESPACE}/${image}"
  aliyun cr create-repository \
    --region "$REGION" \
    --instance-id "$ACR_INSTANCE_ID" \
    --repo-name "$image" \
    --repo-namespace-name "$ACR_NAMESPACE" \
    --repo-type PRIVATE \
    --summary "raytone prod aliyun beijing ${image}" \
    >/dev/null
}

patch_k8s_refs() {
  local image="$1"
  local ref="$2"
  local paths="$3"

  [ "$UPDATE_K8S" -eq 1 ] || return 0
  [ -d "$K8S_REPO/.git" ] || { echo "✗ K8S_REPO not found or not a git repo: $K8S_REPO"; exit 1; }

  for rel in $paths; do
    local file="$K8S_REPO/$rel"
    if [ ! -f "$file" ]; then
      echo "! skip missing k8s manifest: $rel"
      continue
    fi
    echo "→ patch $rel image.tag -> ${ref##*:}"
    python3 - "$file" "$ref" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
ref = sys.argv[2]
tag = ref.rsplit(':', 1)[1]
s = path.read_text()

ns, n = re.subn(r'(^\s*tag:\s*).+$', rf'\g<1>{tag}', s, count=1, flags=re.M)
if n == 0:
    raise SystemExit(f'no image.tag line in {path}')
path.write_text(ns)
PY
  done
}

argocd_refresh() {
  [ "$#" -gt 0 ] || return 0
  [ -r "$ARGOCD_FILE" ] || return 0
  local srv pw tok app
  srv="$(sed -n 1p "$ARGOCD_FILE")"
  pw="$(sed -n 2p "$ARGOCD_FILE")"
  [ -n "$srv" ] && [ -n "$pw" ] || return 0

  tok="$(curl -s -m 10 -X POST "$srv/api/v1/session" -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys;print(json.dumps({"username":"admin","password":sys.argv[1]}))' "$pw")" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
  [ -n "$tok" ] || { echo "  ⚠ ArgoCD 登录失败，跳过即时刷新"; return 0; }

  for app in "$@"; do
    if curl -s -m 15 -H "Authorization: Bearer $tok" "$srv/api/v1/applications/${app}?refresh=hard" >/dev/null 2>&1; then
      echo "  ⟳ 已触发 ArgoCD 刷新 $app"
    else
      echo "  ⚠ ArgoCD 刷新 $app 失败，等待自动轮询"
    fi
  done
}

deploy_manifests() {
  [ "$DEPLOY" -eq 1 ] || return 0
  [ "${#DEPLOY_SPECS[@]}" -gt 0 ] || { echo "⊘ deploy: 无成功构建，跳过清单回写"; return 0; }
  [ -d "$K8S_REPO/.git" ] || { echo "✗ deploy: GitOps 仓不存在: $K8S_REPO"; return 1; }

  echo ""
  echo "═══ deploy: 回写 GitOps 清单 + push GitLab ═══"
  (
    flock 9
    cd "$K8S_REPO"
    git checkout --quiet "$GITOPS_BRANCH" 2>/dev/null || git checkout -t "$GITOPS_PRIMARY_REMOTE/$GITOPS_BRANCH"
    git pull --rebase --quiet "$GITOPS_PRIMARY_REMOTE" "$GITOPS_BRANCH" || { echo "✗ git pull --rebase 失败"; exit 1; }

    local addpaths=() spec image rest ref paths
    UPDATE_K8S=1
    for spec in "${DEPLOY_SPECS[@]}"; do
      image="${spec%%|*}"
      rest="${spec#*|}"
      ref="${rest%%|*}"
      paths="${rest#*|}"
      patch_k8s_refs "$image" "$ref" "$paths"
      addpaths+=($paths)
    done

    git add "${addpaths[@]}"
    if git diff --cached --quiet; then
      echo "  (清单无变化，跳过 commit/push)"
      exit 0
    fi

    echo "  GitOps 改动文件:"
    git --no-pager diff --cached --stat | sed 's/^/    /'

    git commit --quiet -m "prod-aliyun-beijing auto-deploy: update image tags"
    # GitLab(ArgoCD 源)必达
    git push --quiet "$GITOPS_PRIMARY_REMOTE" HEAD:"$GITOPS_BRANCH" || { echo "✗ GitLab push 失败"; exit 1; }
    echo "  ✓ commit + push GitLab 完成"
  ) 9>/tmp/raytone-prod-aliyun-bj-gitops.lock

  local nudge=() spec p envdir svc
  for spec in "${DEPLOY_SPECS[@]}"; do
    for p in ${spec##*|}; do
      envdir="${p%%/*}"
      svc="${p#*/}"
      svc="${svc%%/*}"
      nudge+=("${envdir}-${svc}")
    done
  done
  argocd_refresh "${nudge[@]}"
}

if [ "$ACR_ENSURE_REPO" -eq 1 ]; then
  acr_namespace_exists || { echo "✗ ACR namespace 不存在: $ACR_NAMESPACE"; exit 1; }
fi
acr_login

SSH_AGENT_STARTED=0
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  SSH_KEY=""
  for k in "$HOME/.ssh/raytone_gitops_deploy" "$HOME/.ssh/id_ed25519_github_raytone_buildbox" "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
    [ -f "$k" ] && { SSH_KEY="$k"; break; }
  done
  if [ -n "$SSH_KEY" ]; then
    echo "ⓘ 无 ssh-agent，自动起临时 agent 并加载 $SSH_KEY"
    eval "$(ssh-agent -s)" >/dev/null
    SSH_AGENT_STARTED=1
    trap '[ "$SSH_AGENT_STARTED" = 1 ] && ssh-agent -k >/dev/null 2>&1 || true' EXIT
    if ! ssh-add "$SSH_KEY" >/dev/null 2>&1; then
      echo "⚠ ssh-add 失败，放弃 SSH 转发；带 git 依赖的服务会构建失败"
      ssh-agent -k >/dev/null 2>&1 || true
      unset SSH_AUTH_SOCK SSH_AGENT_PID
      SSH_AGENT_STARTED=0
    fi
  else
    echo "ⓘ 未找到可用 SSH key；带 git 依赖的服务可能构建失败"
  fi
fi

PUSHED_REFS=()
DEPLOY_SPECS=()
SKIPPED_TARGETS=()
TMP_DOCKERFILES=()

cleanup_tmp_dockerfiles() {
  local f
  for f in "${TMP_DOCKERFILES[@]:-}"; do
    [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
  done
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
  local dockerfile="$3"
  # 目前没有 target 需要临时改写 Dockerfile(原 codesphere-saas 的 uv 引导补丁随服务下线一并移除),
  # 保留本函数作钩子:原样返回传入的 Dockerfile。
  printf '%s\n' "$dockerfile"
  return 0
}

for TARGET in $TARGETS; do
  SPEC="$(spec_of_target "$TARGET")" || { echo "✗ unknown target: $TARGET"; exit 1; }

  DIR="${SPEC%%|*}"
  REST="${SPEC#*|}"
  DOCKERFILE="${REST%%|*}"
  REST="${REST#*|}"
  BUILD_ARGS="${REST%%|*}"
  REST="${REST#*|}"
  IMAGE="${REST%%|*}"
  REST="${REST#*|}"
  K8S_PATHS="${REST%%|*}"
  RELEASE_BRANCH="${REST#*|}"

  CTX="${ROOT}/${DIR}"
  [ -d "$CTX" ] || { echo "✗ source dir not found: $CTX"; exit 1; }
  [ -d "$CTX/.git" ] || { echo "✗ not a git repo: $CTX"; exit 1; }

  if [ "$ACR_ENSURE_REPO" -eq 1 ]; then
    ensure_repo "$IMAGE"
  fi

  cd "$CTX"

  SHA_BEFORE=""
  if [ "$DO_PULL" -eq 1 ]; then
    SHA_BEFORE="$(git rev-parse HEAD 2>/dev/null || echo "")"
    echo "─── [$IMAGE] checkout + pull origin/$RELEASE_BRANCH ───"
    git fetch origin "$RELEASE_BRANCH" --quiet
    git checkout "$RELEASE_BRANCH" 2>/dev/null || git checkout -t "origin/$RELEASE_BRANCH"
    git pull --ff-only --quiet origin "$RELEASE_BRANCH"

    SHA_AFTER="$(git rev-parse HEAD 2>/dev/null || echo "")"
    if [ -n "$SHA_BEFORE" ] && [ "$SHA_BEFORE" != "$SHA_AFTER" ]; then
      echo "  ↻ 代码更新 ${SHA_BEFORE:0:7}..${SHA_AFTER:0:7}:"
      git --no-pager log --oneline --no-decorate "$SHA_BEFORE..$SHA_AFTER" | sed 's/^/      · /'
      echo "  改动文件:"
      git --no-pager diff --stat "$SHA_BEFORE" "$SHA_AFTER" | sed 's/^/      /'
    elif [ -n "$SHA_BEFORE" ]; then
      echo "  = 无代码更新 (HEAD ${SHA_AFTER:0:7})"
    fi
    echo ""

    if [ "$EXPLICIT_TARGETS" -eq 0 ]; then
      if [ -n "$SHA_BEFORE" ] && [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then
        echo "⊘ [$IMAGE] no git update (HEAD: ${SHA_AFTER:0:7})，skip build/push"
        SKIPPED_TARGETS+=("$IMAGE @ ${SHA_AFTER:0:7}")
        cd "$ROOT"
        echo ""
        continue
      fi
    fi
  fi

  # Dockerfile 检查放在 checkout+pull 之后:目标 Dockerfile 可能只存在于 release 分支
  [ -f "${CTX}/${DOCKERFILE}" ] || { echo "✗ Dockerfile not found: ${CTX}/${DOCKERFILE} (branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null))"; exit 1; }

  SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || echo nogit)"
  # 构建身份(BUILD_SHA):gateway 自 a3ad7fb 起在 Dockerfile 里 fail-closed 校验 40 位小写全 SHA,
  # 并 -ldflags 注入 buildinfo.CommitSHA(用量事件 producer_build_sha 的来源)。统一对所有 target 传;
  # 未声明 ARG BUILD_SHA 的 Dockerfile 只会打一条 unused build-arg 警告。
  FULL_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"
  if grep -qE '^[[:space:]]*ARG[[:space:]]+BUILD_SHA' "${CTX}/${DOCKERFILE}" \
     && ! printf '%s\n' "$FULL_SHA" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "✗ [$IMAGE] $DOCKERFILE 要求 BUILD_SHA(40 位小写全 SHA),当前工作副本取到的是:'${FULL_SHA}'"
    exit 1
  fi
  TS="$(TZ=Asia/Shanghai date +%Y%m%d-%H%M)"
  TAG_SHA="${IMAGE_TAG_PREFIX}-${SHA}-${TS}"
  REF_SHA="${ACR_REGISTRY}/${ACR_NAMESPACE}/${IMAGE}:${TAG_SHA}"

  SSH_FLAG=()
  [ -n "${SSH_AUTH_SOCK:-}" ] && SSH_FLAG=(--ssh default)

  SECRET_FLAG=()
  [ -n "${GITHUB_TOKEN:-}" ] && SECRET_FLAG=(--secret id=github_token,env=GITHUB_TOKEN)

  # BUILD_PROXY 设置时,把代理注入 RUN 步骤(docker 预定义 proxy build-arg,不进镜像 history)。
  # cn box 让构建走本机 mihomo(docker 网关 172.17.0.1:7890,需 mihomo allow-lan)直连官方源,免 mirror。
  PROXY_FLAG=()
  if [ -n "${BUILD_PROXY:-}" ]; then
    # NO_PROXY 保留国内 mirror 直连(goproxy/npmmirror/阿里云/清华),只让官方源(pypi/github)走代理
    _NP="localhost,127.0.0.1,.aliyuncs.com,.aliyun.com,mirrors.aliyun.com,goproxy.cn,.npmmirror.com,registry.npmmirror.com,.tuna.tsinghua.edu.cn,.tsinghua.edu.cn"
    PROXY_FLAG=(--build-arg HTTP_PROXY="$BUILD_PROXY" --build-arg HTTPS_PROXY="$BUILD_PROXY" \
                --build-arg http_proxy="$BUILD_PROXY" --build-arg https_proxy="$BUILD_PROXY" \
                --build-arg NO_PROXY="$_NP" --build-arg no_proxy="$_NP")
  fi

  DOCKERFILE_TO_USE="$(prepare_dockerfile "$TARGET" "$CTX" "$DOCKERFILE")"

  echo "═══ [$IMAGE] build -> Aliyun Beijing ACR (platform: $PLATFORM, tag: $TAG_SHA) ═══"
  # shellcheck disable=SC2086
  docker build \
    --platform "$PLATFORM" \
    "${SSH_FLAG[@]}" \
    "${SECRET_FLAG[@]}" \
    "${PROXY_FLAG[@]}" \
    -f "$DOCKERFILE_TO_USE" \
    --build-arg BUILD_SHA="$FULL_SHA" \
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
  echo "✓ Aliyun Beijing ACR push complete (${#PUSHED_REFS[@]} images)"
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
  echo "Deploy: 清单已回写并 push GitLab，ArgoCD 将自动同步。"
else
  echo "Next: review the pushed refs above, then update prod-aliyun-beijing manifests manually (或用 --deploy 自动回写)。"
fi

# 收尾:清 7 天前的 build cache + 悬空镜像,防缓存无上限膨胀。best-effort。
echo "═══ 本地清理:build cache(>7d) + dangling ═══"
docker image prune -f >/dev/null 2>&1 || true
docker builder prune -f --filter until=168h >/dev/null 2>&1 || true
echo "  ✓ 本地清理完成($(df -h / | awk 'NR==2{print $4" free, "$5}'))"
