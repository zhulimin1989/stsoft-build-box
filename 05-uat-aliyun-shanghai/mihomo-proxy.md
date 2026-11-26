# Build-Box · uat-aliyun-shanghai — mihomo 代理

## TL;DR

- **是什么**：上海 build box（`47.116.200.222`）上的 mihomo 代理，给 `docker build` / git / shell 提供快速国际出口。
- **为什么**：cn box 到 GitHub `:443` 被墙（`:22` 通）、docker.io 直连超时、官方 PyPI 龟速。构建重依赖服务（官方源大包 + git wheel）没有代理会慢到几十分钟。
- **当前状态**：mihomo v1.19.27 已装、systemd 常驻、开机自启；`mixed-port 7890`、`allow-lan`（供容器经 docker 网关访问）。
- **关键**：`Auto` 按**延迟**选节点会挑到低带宽节点（SG/HK ~0.06MB/s）；须按**实测吞吐**手动固定到快节点（实测 `美国-US-1` ~6MB/s）。

## 1. 为什么需要它

| 目标 | cn 直连 | 走 mihomo |
| --- | --- | --- |
| GitHub 业务仓 | `:443` 被墙（用 SSH `:22` 绕，见 [16/构建机 SSH]） | HTTPS 也可 |
| docker.io base 镜像 | 超时（另有 registry-mirror 兜底，见下） | 直连 |
| 官方 PyPI（saas 的 uv sync） | 龟速 / 经镜像有 hash mismatch 风险 | 官方源直连、hash 正确 |

saas 的 `uv sync` 会拉官方 PyPI 大包 + 从 GitHub 构建 3 个 git 子包（`ruidong-agent-core`），是全部 target 里最重的一步，代理对它收益最大。

## 2. 安装（binary 从本机 scp，因 box 到 GitHub 被墙）

| 项 | 值 |
| --- | --- |
| 二进制 | `/usr/local/bin/mihomo`（v1.19.27，linux-amd64）|
| 来源 | GitHub release `MetaCubeX/mihomo`；**box 下不了，须本机下好 scp** |
| systemd | `/etc/systemd/system/mihomo.service`（`ExecStart=/usr/local/bin/mihomo -d /etc/mihomo`，`enable --now`）|
| 配置目录 | `/etc/mihomo/`（`config.yaml` + geo 库）|

## 3. 配置（`/etc/mihomo/config.yaml`）

- **来源**：ClashX 订阅 profile `00848607-...`（trojanflare）。订阅 URL：`https://s2.trojanflare.one/clashx/00848607-eeb7-4e86-a69b-cf556735eb1e`（更新节点时重拉）。
- **改动**（相对原 ClashX 配置）：
  - `port: 7890` → `mixed-port: 7890`（http+socks 同口）；`socks-port` 注掉。
  - `allow-lan: false` → `true` + `bind-address: "*"`：监听 `*:7890`，**让 docker 构建容器经网关 `172.17.0.1:7890` 可达**。
  - `geo-auto-update: false`：禁自动更新（box 下不动 geo 库）。
- **geo 库离线放置**（本机下好 scp 到 `/etc/mihomo/`）：`geoip.metadb`、`geosite.dat`、`geoip.dat`。否则 `GEOIP,CN` 规则初始化时下载 MMDB 超时、配置校验失败。
- `external-controller: 127.0.0.1:9000`（本地控制/查询 API）。

## 4. 接线（哪些流量走代理）

| 场景 | 接法 | 备注 |
| --- | --- | --- |
| shell（curl/git/npm/pip） | `/etc/profile.d/proxy.sh`：`http_proxy/https_proxy/all_proxy=http://127.0.0.1:7890` | 新会话生效；当前会话 `source` 一下 |
| git（HTTPS 仓） | `git config --global http.proxy http://127.0.0.1:7890` | GitHub 业务仓走 SSH，不受影响 |
| **docker build（RUN 步骤）** | **不吃 shell 代理**（容器内 `127.0.0.1` 非宿主）。由 `build-push-uat-aliyun-sh.sh` 的 `BUILD_PROXY` 注入 build-arg | 见下 |

**`no_proxy` / `NO_PROXY` 白名单**（务必保留直连，否则国内源被绕远、ACR 推送出错）：
`localhost,127.0.0.1,内网网段,.aliyuncs.com,.aliyun.com,mirrors.aliyun.com,goproxy.cn,.npmmirror.com,registry.npmmirror.com,.tuna.tsinghua.edu.cn,39.103.223.155(张家口 GitLab)`。

### docker build 走代理

```bash
# 172.17.0.1 = docker0 网关,容器经它到宿主 mihomo(需 allow-lan)
BUILD_PROXY=http://172.17.0.1:7890 ./build-push-uat-aliyun-sh.sh gateway
```

`build-push-uat-aliyun-sh.sh` 检测到 `BUILD_PROXY` 后，给 `docker build` 注入 `--build-arg HTTP_PROXY/HTTPS_PROXY/NO_PROXY`（docker 预定义 proxy build-arg，仅构建期、不进镜像 history）。国内 mirror 在 `NO_PROXY` 白名单里仍走直连，只有官方源（pypi/github/pythonhosted）走代理。

## 5. 选节点（关键：按吞吐不按延迟）

`Proxy`(Selector) → `Auto`(URLTest) → 具体节点。**`Auto` 按延迟选，会挑到低带宽节点**（实测 SG/HK/OS 仅 ~0.02–0.13 MB/s）。须实测吞吐后**把 `Proxy` 固定到快节点**。

实测（经 GitHub release 17MB 文件，`curl -L`）：

| 节点 | 吞吐 |
| --- | --- |
| **美国-US-1** | **~6 MB/s**（选它）|
| 日本-TY-1 | ~2.5 MB/s |
| 香港/大阪/新加坡 | <0.15 MB/s |

控制 API（`127.0.0.1:9000`）：

```bash
# 列节点
curl -s http://127.0.0.1:9000/proxies/Proxy | python3 -c 'import sys,json;[print(n) for n in json.load(sys.stdin)["all"]]'
# 固定到某节点
curl -X PUT http://127.0.0.1:9000/proxies/Proxy -d '{"name":"美国-US-1-流量倍率:1"}'
# 切节点后,已建立的老连接仍在旧节点 → 掐掉逼重连
curl -s http://127.0.0.1:9000/connections | python3 -c 'import sys,json,urllib.request;[urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:9000/connections/{x[\"id\"]}",method="DELETE")) for x in json.load(sys.stdin)["connections"]]'
```

> ⚠️ 切节点只对**新连接**生效。uv 那条长连接不会自动迁移，必须掐掉旧连接才会重连到新节点。实测切 US-1 + 掐连接后，saas 下载从 ~77KB/s 飙到 ~12MB/s。

## 6. 与其它加速手段的关系

- **docker registry-mirror**（`/etc/docker/daemon.json`：daocloud/1ms/docker-cn）：解决 `docker pull` base 镜像（python/node），与本代理**互补**——registry-mirror 管 base 镜像层，BUILD_PROXY 管 RUN 步骤内的包下载。
- GitHub 业务仓源码：走 **SSH**（`id_ed25519_github_raytone_buildbox`），非本代理。

## 7. 校验

```bash
systemctl is-active mihomo                                   # active
ss -ltnp | grep 7890                                          # *:7890 LISTEN
https_proxy=http://127.0.0.1:7890 curl -sI https://pypi.org/simple/  # 200
```
