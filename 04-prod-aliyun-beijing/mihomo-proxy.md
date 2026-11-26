# Build-Box · prod-aliyun-beijing — mihomo 代理

## TL;DR

- **是什么**：北京 prod build box（`39.96.58.108`）上的 mihomo 代理，给 `docker build` / git / shell 提供快速国际出口。
- **为什么**：cn box 到 GitHub `:443` 被墙（`:22` 通）、docker.io 直连超时、官方 PyPI 龟速。构建重依赖服务（官方源大包 + git wheel）没有代理会慢到几十分钟。
- **当前状态**：mihomo v1.19.27（linux-amd64）已装、systemd 常驻、开机自启；`mixed-port 7890`、`allow-lan`（供容器经 docker 网关访问）、`external-controller 127.0.0.1:9000`。
- **当前节点**：固定 **美国-US-1**（本机实测 ~4.96 MB/s）。
- **关键**：`Auto` 按**延迟**选节点会挑到低带宽节点；须按**实测吞吐**手动固定到快节点。

## 1. 为什么需要它

| 目标 | cn 直连 | 走 mihomo |
| --- | --- | --- |
| GitHub 业务仓 | `:443` 被墙（用 SSH `:22` 绕） | HTTPS 也可 |
| docker.io base 镜像 | 超时（另有 registry-mirror 兜底） | 直连 |
| 官方 PyPI（saas 的 uv sync） | 龟速 / 经镜像有 hash mismatch 风险 | 官方源直连、hash 正确 |

saas 的 `uv sync` 会拉官方 PyPI 大包 + 从 GitHub 构建 git 子包（`ruidong-agent-core`），是全部 target 里最重的一步，代理对它收益最大。

## 2. 安装

| 项 | 值 |
| --- | --- |
| 二进制 | `/usr/local/bin/mihomo`（v1.19.27，linux-amd64）|
| 来源 | GitHub release `MetaCubeX/mihomo`；**box 下不了**，本机下好 scp，或从同架构 sibling box（如上海 `47.116.200.222`）直接复制，版本一致更省事 |
| systemd | `/etc/systemd/system/mihomo.service`（`ExecStart=/usr/local/bin/mihomo -d /etc/mihomo`，`enable --now`）|
| 配置目录 | `/etc/mihomo/`（`config.yaml` + geo 库；`cache.db` 首启自动生成，无需拷贝）|

## 3. 配置（`/etc/mihomo/config.yaml`）

- **来源**：ClashX 订阅 profile（trojanflare），与上海 box 同一份配置。更新节点时重拉订阅。
- **改动**（相对原 ClashX 配置）：
  - `mixed-port: 7890`（http+socks 同口）。
  - `allow-lan: true` + `bind-address: "*"`：监听 `*:7890`，**让 docker 构建容器经网关 `172.17.0.1:7890` 可达**。
  - `geo-auto-update: false`：禁自动更新（box 下不动 geo 库）。
  - `external-controller: 127.0.0.1:9000`（本地控制/查询 API）。
- **geo 库离线放置**（本机/sibling box 拿好放 `/etc/mihomo/`）：`geoip.metadb`、`geosite.dat`、`geoip.dat`。否则 `GEOIP,CN` 规则初始化时下载 MMDB 超时、配置校验失败。

## 4. 接线（哪些流量走代理）

| 场景 | 接法 | 备注 |
| --- | --- | --- |
| shell（curl/git/npm/pip） | `/etc/profile.d/proxy.sh`：`http_proxy/https_proxy/all_proxy` 指向 `127.0.0.1:7890` | 新会话生效；当前会话 `source` 一下 |
| git（HTTPS 仓） | 若走 HTTPS 仓再单配 `http.proxy`；GitHub 业务仓走 SSH，不受影响 | |
| **docker build（RUN 步骤）** | **不吃 shell 代理**（容器内 `127.0.0.1` 非宿主）。由 `build-push-prod-aliyun-bj.sh` 的 `BUILD_PROXY` 注入 build-arg | 见下 |

**`no_proxy` 白名单**（务必保留直连，否则国内源被绕远、ACR 推送 / GitOps push 出错）：
`localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.aliyuncs.com,.cr.aliyuncs.com,.aliyun.com,39.103.223.155(张家口 GitLab)`。

### docker build 走代理

```bash
# 172.17.0.1 = docker0 网关,容器经它到宿主 mihomo(需 allow-lan)
BUILD_PROXY=http://172.17.0.1:7890 ./build-push-prod-aliyun-bj.sh gateway
```

`build-push-prod-aliyun-bj.sh` 检测到 `BUILD_PROXY` 后，给 `docker build` 注入 `--build-arg HTTP_PROXY/HTTPS_PROXY/NO_PROXY`（docker 预定义 proxy build-arg，仅构建期、不进镜像 history）。国内 mirror 在 `NO_PROXY` 白名单里仍走直连，只有官方源（pypi/github/pythonhosted）走代理。`BUILD_PROXY` 对所有 target 生效。

## 5. 选节点（关键：按吞吐不按延迟）

`Proxy`(Selector) → `Auto`(URLTest) → 具体节点。**`Auto` 按延迟选，会挑到低带宽节点**。须实测吞吐后**把 `Proxy` 固定到快节点**。节点名带 `-流量倍率:X` 后缀，PUT 时要用全名。

本机实测（Cloudflare 20MB `__down`，经 `127.0.0.1:7890`）：

| 节点 | 吞吐 | 备注 |
| --- | --- | --- |
| **美国-US-1-流量倍率:1** | **~4.96 MB/s**（当前选它）| 倍率 1 |
| 荷兰-NL-4-流量倍率:0.1 | ~4.80 MB/s | 近乎同速，**流量只算 0.1 倍**，配额敏感时更划算 |
| 日本-TY-1-流量倍率:1 | ~0.60 MB/s | |
| 日本-OS / 香港-HK / 新加坡-SG | <0.05 MB/s | 废 |

控制 API（`127.0.0.1:9000`）：

```bash
# 列节点
curl -s http://127.0.0.1:9000/proxies/Proxy | python3 -c 'import sys,json;[print(n) for n in json.load(sys.stdin)["all"]]'
# 看当前
curl -s http://127.0.0.1:9000/proxies/Proxy | python3 -c 'import sys,json;print(json.load(sys.stdin)["now"])'
# 固定到某节点
curl -X PUT http://127.0.0.1:9000/proxies/Proxy -d '{"name":"美国-US-1-流量倍率:1"}'
# 切节点后,已建立的老连接仍在旧节点 → 掐掉逼重连
curl -s http://127.0.0.1:9000/connections | python3 -c 'import sys,json,urllib.request;[urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:9000/connections/{x[\"id\"]}",method="DELETE")) for x in json.load(sys.stdin)["connections"]]'
```

> ⚠️ 切节点只对**新连接**生效。uv 那条长连接不会自动迁移，必须掐掉旧连接才会重连到新节点。

## 6. 与其它加速手段的关系

- **docker registry-mirror**（`/etc/docker/daemon.json`）：解决 `docker pull` base 镜像，与本代理**互补**——registry-mirror 管 base 镜像层，BUILD_PROXY 管 RUN 步骤内的包下载。
- GitHub 业务仓源码：走 **SSH**，非本代理。

## 7. 校验

```bash
systemctl is-active mihomo                                    # active
ss -ltnp | grep -E ':7890|:9000'                              # *:7890 + 127.0.0.1:9000 LISTEN
curl -s http://127.0.0.1:9000/version                        # {"meta":true,"version":"v1.19.27"}
https_proxy=http://127.0.0.1:7890 curl -sI https://pypi.org/simple/   # 200
# 容器经 docker 网关到宿主 mihomo(BUILD_PROXY 依赖的 allow-lan 路径)
docker run --rm curlimages/curl -s -o /dev/null -x http://172.17.0.1:7890 -w '%{http_code}\n' https://pypi.org/simple/  # 200
```

## 8. 订阅配额

- 订阅有效期与剩余流量在 `Proxy` 节点列表里可见（`有效期… 剩余 … GB` 那条）。到期需重拉订阅、换配置、重选节点。
- 配额敏感场景优先选低倍率节点（如 NL-4 的 0.1 倍），同速省 10× 流量。
