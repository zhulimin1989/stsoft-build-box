#!/bin/bash
# nprod 自动发版 wrapper(在 build-box 上)。
# webhook 监听器按 GitHub repo 名调用:/root/deploy-on-push.sh <repo>
#
# repo → build target(s) 映射;逐 target 调 build-push-nprod-aws-beijing.sh --deploy。
# 单 target 失败 → 钉钉告警 + 记日志,不中断其它 target。
set -uo pipefail

REPO="${1:-}"
TRIGGER="${2:-手动触发}"   # webhook 透传的 GitHub 用户;手动跑则默认"手动触发"
[ -n "$REPO" ] || { echo "usage: $0 <github-repo-name> [trigger-user]"; exit 2; }

BUILD_DIR="${BUILD_DIR:-/root/repo}"
LOG_DIR="${LOG_DIR:-/var/log/raytone-deploy}"
DINGTALK_FILE="${DINGTALK_FILE:-/root/.dingtalk_webhook}"
mkdir -p "$LOG_DIR"

# repo → targets(空格分隔)。codesphere-user/admin 一仓出两镜像。
targets_of() {
  case "$1" in
    tokenplatform-gateway)          echo "gateway" ;;
    tokenplatform-publisher)        echo "publisher" ;;
    tokenplatform-rawbody-consumer) echo "tokenplatform-rawbody-consumer" ;;
    codesphere-user)                echo "codesphere-ops-user-api codesphere-ops-user-web" ;;
    codesphere-admin)               echo "codesphere-ops-admin-api codesphere-ops-admin-web" ;;
    codesphere-billing)             echo "codesphere-ops-billing-api codesphere-ops-billing-openapi" ;;
    raytone-landing)                echo "raytone-landing" ;;
    # Raytone Studio 前后端。旧仓名 raytone-studio-bankend(拼写错误)已在 GitHub 改名为
    # raytone-studio-backend;两个名字都映射,避免历史 webhook 或未更新的 clone 静默跳过。
    raytone-studio-backend|raytone-studio-bankend) echo "raytone-studio-api" ;;
    raytone-studio-frontend)        echo "raytone-studio-web" ;;
    # RDWORK 一仓两镜像:runtime(主面+转发面共用)+ migrate。两者 tag 必须一致,
    # 因为 chart 里 Job 的镜像是用同一个 image.tag 拼 <repo>-migrate:<tag> 的。
    # 下面的 for 循环是每个 target 调一次 build-push,所以靠本文件统一 export RUN_TS 对齐。
    rdwork-backend)                 echo "rdwork-backend rdwork-backend-migrate" ;;
    # 智能体广场:单进程全包,一个镜像一个 target。
    skill-plaza-standalone)         echo "skill-plaza" ;;
    *) echo "" ;;
  esac
}

# 钉钉自定义机器人通知。/root/.dingtalk_webhook 三行:
#   第1行 webhook URL(含 access_token)
#   第2行 加签 secret(留空=不加签;机器人若用"加签"安全模式才填)
#   第3行 关键词(机器人若用"自定义关键词"安全模式,消息必须含它,会自动前置)
# 缺文件则静默跳过。
notify_dingtalk() {
  local title="$1" text="$2"
  [ -r "$DINGTALK_FILE" ] || { echo "(no dingtalk config, skip notify)"; return 0; }
  local url secret kw send_url ts sign body
  url="$(sed -n 1p "$DINGTALK_FILE")"
  secret="$(sed -n 2p "$DINGTALK_FILE")"
  kw="$(sed -n 3p "$DINGTALK_FILE")"
  [ -n "$url" ] || return 0
  [ -n "$kw" ] && text="**${kw}**"$'\n\n'"${text}"   # 关键词出现在正文,满足"自定义关键词"模式
  send_url="$url"
  if [ -n "$secret" ]; then
    ts="$(date +%s)000"
    sign="$(printf '%s\n%s' "$ts" "$secret" | openssl dgst -sha256 -hmac "$secret" -binary | base64)"
    sign="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote_plus(sys.argv[1]))' "$sign")"
    send_url="${url}&timestamp=${ts}&sign=${sign}"
  fi
  body="$(python3 -c 'import json,sys;print(json.dumps({"msgtype":"markdown","markdown":{"title":sys.argv[1],"text":sys.argv[2]}}))' "$title" "$text")"
  curl -s -m 10 -H 'Content-Type: application/json' -d "$body" "$send_url" >/dev/null 2>&1 || true
}

TARGETS="$(targets_of "$REPO")"
[ -n "$TARGETS" ] || { echo "unknown/unmapped repo: $REPO (忽略)"; exit 0; }

cd "$BUILD_DIR" || { echo "✗ build dir 不存在: $BUILD_DIR"; exit 1; }
TS="$(date +%Y%m%d-%H%M%S)"

# 镜像 tag 的时间戳:本次 repo 的所有 target 统一用一个(北京时间,与 build-push 内的算法一致)。
# ★ 下面是每个 target 调一次 build-push,若不统一传,同一个源码仓出的多个镜像会因跨分钟
#   拿到不同 tag。rdwork-backend 的 runtime 与 -migrate 就依赖这条对齐:chart 里 Job 的
#   镜像地址是用同一个 image.tag 拼 <repo>-migrate:<tag>,tag 一漂就 ImagePullBackOff。
export RUN_TS="$(TZ=Asia/Shanghai date +%Y%m%d-%H%M)"
FAILED=()

echo "═══ deploy-on-push: repo=$REPO targets=[$TARGETS] trigger=$TRIGGER @ $TS ═══"
REPO_URL="https://github.com/raytone-lab/${REPO}"
SRC="$BUILD_DIR/$REPO"
for t in $TARGETS; do
  LOG="$LOG_DIR/${REPO}-${t}-${TS}.log"
  echo "── $REPO → $t (log: $LOG) ──"
  t0=$(date +%s)
  ./build-push-nprod-aws-beijing.sh --deploy nprod "$t" >"$LOG" 2>&1; rc=$?
  dur=$(( $(date +%s) - t0 ))
  # 构建后读 test HEAD 的提交(此时 build-push-china 已 pull 到部署的 commit,对得上 tag);全角｜分隔
  GINFO=$(git -C "$SRC" log -1 --format='%h｜%s｜%an' 2>/dev/null)
  GSHA="${GINFO%%｜*}"; _r="${GINFO#*｜}"; GMSG="${_r%%｜*}"; GAUTHOR="${_r##*｜}"
  if [ "$rc" -eq 0 ]; then
    echo "  ✓ $t"
    tag=$(grep -oE 'nprod-[0-9a-f]{7}-[0-9]{8}-[0-9]{4}' "$LOG" | tail -1)
    notify_dingtalk "nprod 发版成功 ${t}" "$(printf '#### ✅ nprod 自动发版成功\n\n- **服务**: %s\n- **仓库**: [%s](%s) · 分支 test\n- **触发人**: %s\n- **镜像 tag**: `%s`\n- **提交**: `%s` %s\n- **提交人**: %s\n- **耗时**: %ss\n- **时间**: %s\n\n[ArgoCD 控制台](http://43.196.147.233:8084)' "$t" "$REPO" "$REPO_URL" "$TRIGGER" "${tag:-?}" "${GSHA:-?}" "${GMSG:-}" "${GAUTHOR:-}" "$dur" "$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S 北京时间')")"
  else
    echo "  ✗ $t 失败(详见 $LOG)"
    FAILED+=("$t")
    notify_dingtalk "nprod 发版失败 ${t}" "$(printf '#### 🔴 nprod 自动发版失败\n\n- **服务**: %s\n- **仓库**: [%s](%s) · 分支 test\n- **触发人**: %s\n- **提交**: `%s` %s\n- **耗时**: %ss\n- **时间**: %s\n\n> %s' "$t" "$REPO" "$REPO_URL" "$TRIGGER" "${GSHA:-?}" "${GMSG:-}" "$dur" "$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S 北京时间')" "$(tail -n 6 "$LOG" | tr '\n' ' ' | tail -c 280)")"
  fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "✗ 失败 target: ${FAILED[*]}"
  exit 1
fi
echo "✓ $REPO 全部 target 发版完成"
