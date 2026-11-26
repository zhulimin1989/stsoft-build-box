#!/usr/bin/env bash
# raytone 生产镜像构建 —— 环境:prod-aws-use1(AWS us-east-1 · 集群 raytonelab-prod-use1),推 us-east-1 ECR。
#   (国内 nprod 用 build-push-nprod-aws-beijing.sh;香港 uat 用 build-push-uat-aws-hongkong.sh)
# 鉴权:docker 的 ecr-login 凭证助手自动取 token,无需 docker login。
#   - 美东构建机(主用):走实例角色,直接  ./build-push-prod-aws-use1.sh <targets|all>
#   - 本地笔记本(备用):AWS_PROFILE=bedrock-us ./build-push-prod-aws-use1.sh <targets|all>
#
# tag: prod-<gitsha7>-<YYYYMMDD-HHMM>(唯一 tag;ECR tag 不可变,不推 latest-prod);push 后 CRR 自动复制到 ap-southeast-1。
#
# 用法示例:
#   ./build-push-prod-aws-use1.sh all                                   # 构建+推全部 13 个服务
#   ./build-push-prod-aws-use1.sh codesphere-ops-billing-openapi        # 单个
#   ./build-push-prod-aws-use1.sh gateway publisher raytone-landing    # 多个
#   ./build-push-prod-aws-use1.sh -h|--help                             # 打印用法 + target 清单
#
# 完整构建指令(= all,显式列全 10 个 target,cutover 前一把全建):
#   ./build-push-prod-aws-use1.sh \
#     codesphere-ops-user-api codesphere-ops-user-web \
#     codesphere-ops-admin-api codesphere-ops-admin-web \
#     codesphere-ops-billing-api codesphere-ops-billing-openapi \
#     raytone-landing gateway publisher tokenplatform-rawbody-consumer
set -euo pipefail

ECR="654654182678.dkr.ecr.us-east-1.amazonaws.com"
PLATFORM="linux/amd64"
ROOT="$(cd "$(dirname "$0")" && pwd)"

# target -> "业务目录|Dockerfile|build-args|镜像名(留空=raytone-<target>)|发布分支"
# 发布分支:构建前强制 checkout 回这个分支 + ff 拉最新,防止有人在 box 上手动切错分支。
spec() {
  case "$1" in
    codesphere-ops-user-api)        echo "codesphere-user|Dockerfile.api|||prod" ;;
    codesphere-ops-user-web)        echo "codesphere-user|Dockerfile.web|--build-arg VITE_AUTH0_DOMAIN=dev-by01ng3didk64hkd.us.auth0.com --build-arg VITE_AUTH0_CLIENT_ID=60h5PvKRaNyq3G2d7ZmlQl9DEKJuvgHY --build-arg VITE_AUTH0_DB_CONNECTION=Username-Password-Authentication --build-arg VITE_GTM_ID=GTM-TMRWS96V||prod" ;;
    codesphere-ops-admin-api)       echo "codesphere-admin|Dockerfile.api|||prod" ;;
    codesphere-ops-admin-web)       echo "codesphere-admin|Dockerfile.web|--build-arg VITE_USER_APP_URL=https://platform.raytone.ai||prod" ;;
    codesphere-ops-billing-api)     echo "codesphere-billing|Dockerfile|||prod" ;;
    codesphere-ops-billing-openapi) echo "codesphere-billing|Dockerfile.openapi|||prod" ;;
    raytone-landing)                echo "raytone-landing|Dockerfile||raytone-landing|prod" ;;
    gateway)                        echo "tokenplatform-gateway|Dockerfile|||prod" ;;
    publisher)                      echo "tokenplatform-publisher|Dockerfile|||prod" ;;
    tokenplatform-rawbody-consumer) echo "tokenplatform-rawbody-consumer|Dockerfile|||prod" ;;
    # ── Raytone Studio 三件套(2026-09-08 加)──────────────────────────────
    # ★★ 本脚本 spec 是 5 段且**末段是发布分支**:目录|Dockerfile|build-args|镜像名|分支
    #    (解析:IMG="${REST%%|*}"; BR="${REST#*|}")。02-uat-aws-hongkong 同样 5 段但
    #    末段是 GitOps values 路径 —— 照它抄会把 values 路径当分支去 checkout,必挂。
    # ★ 本脚本**没有 --deploy 回写能力**,tag 要手改
    #   aws-eks-raytone-k8s/prod-aws-use1/<svc>/values.yaml 再 push GitLab。
    raytone-studio-api)             echo "raytone-studio-backend|Dockerfile||raytone-studio-api|prod" ;;
    # ★★ 前端把目标环境产物编译进镜像,必须显式给 BUILD_MODE。海外生产是 public-saas-overseas
    #    (前端仓需先有 .env.public-saas-overseas)。漏掉 → 构出 private-test 产物、接口地址全错;
    #    抄成 public-saas-hk → 门户/购买跳到香港 UAT,而页面完全正常、无报错。
    raytone-studio-web)             echo "raytone-studio-frontend|Dockerfile|--build-arg BUILD_MODE=${STUDIO_WEB_BUILD_MODE:-public-saas-overseas}|raytone-studio-web|prod" ;;
    # ★ PUBLIC_BASE_PATH 必须传**空串** —— Dockerfile 默认值是 /plaza,漏传会构出子路径产物,
    #   浏览器按协议相对 URL 去请求主机名 "assets",页面资源全 404。
    skill-plaza)                    echo "skill-plaza-standalone|Dockerfile|--build-arg PUBLIC_BASE_PATH=|raytone-skill-plaza|prod" ;;
    *) return 1 ;;
  esac
}

# ★ Studio 三件套(raytone-studio-api / raytone-studio-web / skill-plaza)曾刻意不进
#   ALL(源码仓未 clone 时全量发版会在缺失目录处失败);2026-09-08 三个仓已 clone 到
#   本 box(/root/repo/{raytone-studio-backend,raytone-studio-frontend,skill-plaza})
#   且首轮镜像已构建验证,前置补齐,正式并入 ALL。
ALL="codesphere-ops-user-api codesphere-ops-user-web codesphere-ops-admin-api codesphere-ops-admin-web codesphere-ops-billing-api codesphere-ops-billing-openapi raytone-landing gateway publisher tokenplatform-rawbody-consumer raytone-studio-api raytone-studio-web skill-plaza"

[ $# -eq 0 ] && { echo "用法: $0 <target...|all>"; echo "targets: $ALL"; exit 1; }
case "$1" in -h|--help) echo "用法: $0 <target...|all>"; echo "targets: $ALL"; exit 0 ;; esac
[ "$1" = "all" ] && set -- $ALL

# tag 时间用北京时区(box 系统时钟是 UTC,这里只本地化 tag,避免国内看着差 8 小时)
TS="$(TZ='Asia/Shanghai' date +%Y%m%d-%H%M)"
# 本地清理:push 成功后删掉刚推的本地 tag(registry 已有,本地留着只占盘)。
# best-effort,绝不因清理失败中断发版(脚本 set -e)。
prune_local_image() {
  local ref
  for ref in "$@"; do
    [ -n "${ref:-}" ] && docker image rm "$ref" >/dev/null 2>&1 || true
  done
  return 0
}

declare -a PUSHED
for T in "$@"; do
  S="$(spec "$T")" || { echo "✗ 未知 target: $T"; exit 1; }
  DIR="${S%%|*}"; REST="${S#*|}"
  DF="${REST%%|*}"; REST="${REST#*|}"
  ARGS="${REST%%|*}"; REST="${REST#*|}"
  IMG="${REST%%|*}"; BR="${REST#*|}"
  IMG="${IMG:-raytone-$T}"
  CTX="$ROOT/$DIR"
  [ -d "$CTX/.git" ] || { echo "✗ 不是 git 仓: $CTX"; exit 1; }

  cd "$CTX"
  # 强制回到发布分支并拉最新;任一步失败立即退出,绝不拿错分支/旧码静默构建 prod。
  CUR="$(git branch --show-current)"
  [ "$CUR" = "$BR" ] || echo "⚠ [$IMG] 当前在 '$CUR',切回发布分支 '$BR'"
  OLD="$(git rev-parse --short=7 HEAD 2>/dev/null || echo none)"
  git fetch -q origin "$BR"            || { echo "✗ [$IMG] fetch 失败: origin/$BR"; exit 1; }
  git checkout -q "$BR" --             || { echo "✗ [$IMG] 切分支失败 -> $BR(工作区可能有改动)"; exit 1; }  # 尾 -- 消歧:仓里有同名文件/目录(如 gateway 的 test)时 git checkout 会歧义报错
  git pull --ff-only -q origin "$BR"   || { echo "✗ [$IMG] ff 拉取失败: origin/$BR(分支分叉?)"; exit 1; }
  [ -f "$CTX/$DF" ] || { echo "✗ 缺文件: $CTX/$DF"; exit 1; }
  SHA="$(git rev-parse --short=7 HEAD)"
  # 构建身份(BUILD_SHA):gateway 自 a3ad7fb 起在 Dockerfile 里 fail-closed 校验 40 位小写全 SHA,
  # 并 -ldflags 注入 buildinfo.CommitSHA(用量事件 producer_build_sha 的来源)。统一对所有 target 传;
  # 未声明 ARG BUILD_SHA 的 Dockerfile 只会打一条 unused build-arg 警告。
  FULL_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"
  if grep -qE '^[[:space:]]*ARG[[:space:]]+BUILD_SHA' "$DF" \
     && ! printf '%s\n' "$FULL_SHA" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "✗ [$IMG] $DF 要求 BUILD_SHA(40 位小写全 SHA),当前工作副本取到的是:'${FULL_SHA}'"
    exit 1
  fi
  if [ "$OLD" != "$SHA" ]; then
    echo "─── [$IMG] branch=$BR  $OLD → $SHA  本次拉取到新提交: ───"
    git --no-pager log --oneline --no-decorate "$OLD..$SHA" | sed 's/^/      /'
  else
    echo "─── [$IMG] branch=$BR @ $SHA(已是最新,无新提交)───"
  fi
  TAG="prod-$SHA-$TS"
  REF="$ECR/$IMG:$TAG"

  echo "═══ build  $IMG:$TAG   (dir=$DIR, dockerfile=$DF) ═══"
  # shellcheck disable=SC2086
  docker build --platform "$PLATFORM" -f "$DF" --build-arg BUILD_SHA="$FULL_SHA" $ARGS \
    -t "$REF" .

  echo "═══ push   $TAG ═══"
  docker push "$REF"

  PUSHED+=("$REF")
  prune_local_image "$REF"
  cd "$ROOT"
  echo "✓ $IMG done"
  echo ""
done

echo "═══════════════════════════════════════════════"
echo "✓ 推送完成(${#PUSHED[@]} 个) → 环境:prod-aws-use1(AWS us-east-1 · 集群 raytonelab-prod-use1)"
echo "  部署:改 aws-eks-raytone-k8s/prod-aws-use1/<服务>/values.yaml 的 image.tag → git push(GitLab)→ ArgoCD 自动同步:"
printf '  - %s\n' "${PUSHED[@]}"

# 收尾:清 7 天前的 build cache + 悬空镜像,防缓存无上限膨胀。best-effort。
echo "═══ 本地清理:build cache(>7d) + dangling ═══"
docker image prune -f >/dev/null 2>&1 || true
docker builder prune -f --filter until=168h >/dev/null 2>&1 || true
echo "  ✓ 本地清理完成($(df -h / | awk 'NR==2{print $4" free, "$5}'))"
