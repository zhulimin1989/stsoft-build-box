#!/bin/bash
# uat-aws-hongkong(HK)自动发版 wrapper(在 HK build-box 上)。
# webhook 监听器按 GitHub repo 名调用:/root/repo/deploy-on-push-uat-aws-hongkong.sh <repo> [trigger]
#
# repo → build target(s) 映射(同 beijing);逐 target 调 build-push-uat-aws-hongkong.sh --deploy。
# 单 target 失败 → 钉钉告警 + 记日志,不中断其它 target。
set -uo pipefail

REPO="${1:-}"
TRIGGER="${2:-手动触发}"
[ -n "$REPO" ] || { echo "usage: $0 <github-repo-name> [trigger-user]"; exit 2; }

BUILD_DIR="${BUILD_DIR:-/root/repo}"
LOG_DIR="${LOG_DIR:-/var/log/raytone-deploy}"
DINGTALK_FILE="${DINGTALK_FILE:-/root/.dingtalk_webhook}"
ARGOCD_URL="${ARGOCD_URL:-https://argocd.codesphere.run}"
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
    # ── 香港 UAT 首次接入(2026-09-01) ──
    raytone-studio-backend)         echo "raytone-studio-api" ;;
    raytone-studio-frontend)        echo "raytone-studio-web" ;;
    # ★★ 一个仓 → 两个 target,且两者必须拿到同一个 tag(k8s 侧 migrate Job 的镜像由
    #    rdwork-api/values.yaml 的同一个 image.tag 拼 <repo>-migrate:<tag>)。
    #    本脚本是**逐 target** 调 build-push 的,所以下面用 export RUN_TS 把时间戳固定住。
    rdwork-backend)                 echo "rdwork-backend rdwork-backend-migrate" ;;
    skill-plaza-standalone)         echo "skill-plaza" ;;
    *) echo "" ;;
  esac
}

# 钉钉自定义机器人通知(三行配置,缺文件则静默跳过)。同 beijing。
notify_dingtalk() {
  local title="$1" text="$2"
  [ -r "$DINGTALK_FILE" ] || { echo "(no dingtalk config, skip notify)"; return 0; }
  local url secret kw send_url ts sign body
  url="$(sed -n 1p "$DINGTALK_FILE")"; secret="$(sed -n 2p "$DINGTALK_FILE")"; kw="$(sed -n 3p "$DINGTALK_FILE")"
  [ -n "$url" ] || return 0
  [ -n "$kw" ] && text="**${kw}**"$'\n\n'"${text}"
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
FAILED=()

echo "═══ deploy-on-push(HK): repo=$REPO targets=[$TARGETS] trigger=$TRIGGER @ $TS ═══"
REPO_URL="https://github.com/raytone-lab/${REPO}"
SRC="$BUILD_DIR/$REPO"
# ★★ 把 tag 时间戳固定成本次 run 唯一一个值,再逐 target 调 build-push。
# 不这么做的话:build-push 每次被调用都会自己 date 一次,而 rdwork-backend 与
# rdwork-backend-migrate 是**两个 target 两次调用** —— 跨分钟边界就差 1 分钟,
# 而 k8s 侧两者共用同一个 image.tag ⟹ migrate Job ImagePullBackOff 而 runtime 正常。
export RUN_TS="$(TZ=Asia/Hong_Kong date +%Y%m%d-%H%M)"
echo "  RUN_TS=$RUN_TS (本次 run 内所有镜像共用此时间戳)"

for t in $TARGETS; do
  LOG="$LOG_DIR/${REPO}-${t}-${TS}.log"
  echo "── $REPO → $t (log: $LOG) ──"
  t0=$(date +%s)
  ./build-push-uat-aws-hongkong.sh --deploy uat-aws-hongkong "$t" >"$LOG" 2>&1; rc=$?
  dur=$(( $(date +%s) - t0 ))
  GINFO=$(git -C "$SRC" log -1 --format='%h｜%s｜%an' 2>/dev/null)
  GSHA="${GINFO%%｜*}"; _r="${GINFO#*｜}"; GMSG="${_r%%｜*}"; GAUTHOR="${_r##*｜}"
  if [ "$rc" -eq 0 ]; then
    echo "  ✓ $t"
    tag=$(grep -oE 'uat-aws-hongkong-[0-9a-f]{7}-[0-9]{8}-[0-9]{4}' "$LOG" | tail -1)
    notify_dingtalk "HK 发版成功 ${t}" "$(printf '#### ✅ HK(uat-aws-hongkong)自动发版成功\n\n- **服务**: %s\n- **仓库**: [%s](%s) · 分支 uat\n- **触发人**: %s\n- **镜像 tag**: `%s`\n- **提交**: `%s` %s\n- **提交人**: %s\n- **耗时**: %ss\n- **时间**: %s\n\n[ArgoCD 控制台](%s)' "$t" "$REPO" "$REPO_URL" "$TRIGGER" "${tag:-?}" "${GSHA:-?}" "${GMSG:-}" "${GAUTHOR:-}" "$dur" "$(TZ=Asia/Hong_Kong date '+%Y-%m-%d %H:%M:%S HKT')" "$ARGOCD_URL")"
  else
    echo "  ✗ $t 失败(详见 $LOG)"
    FAILED+=("$t")
    notify_dingtalk "HK 发版失败 ${t}" "$(printf '#### 🔴 HK(uat-aws-hongkong)自动发版失败\n\n- **服务**: %s\n- **仓库**: [%s](%s) · 分支 uat\n- **触发人**: %s\n- **提交**: `%s` %s\n- **耗时**: %ss\n- **时间**: %s\n\n> %s' "$t" "$REPO" "$REPO_URL" "$TRIGGER" "${GSHA:-?}" "${GMSG:-}" "$dur" "$(TZ=Asia/Hong_Kong date '+%Y-%m-%d %H:%M:%S HKT')" "$(tail -n 6 "$LOG" | tr '\n' ' ' | tail -c 280)")"
  fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "✗ 失败 target: ${FAILED[*]}"
  exit 1
fi
echo "✓ $REPO 全部 target 发版完成"
