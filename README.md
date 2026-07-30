# BBR TCP 调优工具

> **银趴火山帮** 出品 · 从 [VPS 开荒脚本](https://github.com/chnnic/SSH-Hardening) 同步至 V3.11.6 独立提取

专注 TCP 性能调优的交互式工具，支持智能向导、场景化预设（中转/落地/线路落地）、自动 BDP 计算、手动配置、tc 限速（htb 整形 + fq pacing）、initcwnd 调整。

> **运行依赖：** 需 **bash**（使用了数组 / `[[ ]]` / here-string 等）。Alpine 需 `apk add bash`，OpenWrt 需 `opkg install bash`。脚本头部带解释器守卫，非 bash 环境会自动切换或 fail-fast 提示。

> **维护说明：** 本工具从 `SSH-Hardening` 的 BBR 模块同步提取，版本同步规则见 [SYNC_BBR.md](SYNC_BBR.md)。

---

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chnnic/BBR-tune/refs/heads/main/bbr-tune.sh)
```

或本地：

```bash
wget -O bbr-tune.sh https://raw.githubusercontent.com/chnnic/BBR-tune/refs/heads/main/bbr-tune.sh
chmod +x bbr-tune.sh
sudo ./bbr-tune.sh
```

进入脚本后可选 `10) 设置 bbr 快捷键`，之后任意终端输入 `bbr` 即可启动。

---

## 主菜单

```
════════════════════════════════════════
       BBR TCP 调优工具
  ··银趴火山帮··
────────────────────────────────────────
            BBR TCP 调优
════════════════════════════════════════
  网卡 eth0  CC bbr  cwnd 10（默认）  限速 未设置
  缓冲 rmem 64MB  wmem 64MB  物理内存 2048MB
  ──────────────────────────────────────
  1  智能向导（推荐）
  2  自动配置               3  手动配置
  ──────────────────────────────────────
  4  限速设置               5  initcwnd 设置
  6  备份 TCP 配置          7  还原 TCP 配置
  8  BBR 诊断
  9  更新脚本              10  设置 bbr 快捷键
  0  退出                  00  退出脚本
```

---

## 三类预设体系

### 通用预设（普通 VPS）

| 预设 | 缓冲区（按内存动态） | 适用 |
|------|---------------------|------|
| `balanced` 均衡跨境 | 16-64 MB | 网页 / 代理 / 日常综合 |
| `latency` 低延迟交互 | 32 MB | SSH / 游戏 / 远程桌面 |
| `throughput` 高吞吐 | 64-512 MB | 大带宽 / 万兆 / 下载上传 |

只写入 BBR、缓冲区、连接质量和 UDP 相关参数，不修改 `/etc/sysctl.conf`。

### 场景化预设（代理架构专用）

| 预设 | 缓冲区（2GB 档） | NOTSENT | swap | 额外参数 |
|------|-----------------|---------|------|---------|
| **中转机** `relay` | 64 MB | 256K（小） | 10 | 代理并发；可选转发 + conntrack |
| **落地机** `landing` | 128 MB | 2M（大） | 5 | 代理并发；可选转发 |
| **线路落地机** `line_landing` | 64 MB | 128K（极小） | 5 | 代理并发；可选转发 |

**三种架构的流量模型：**

```
中转机：     客户端 ←→ [中转] ←→ 落地        双向、并发多
落地机：           中转 → [落地] → 目标网站    单向上行、大带宽
线路落地机： 客户端 → [IPLC落地] → 目标网站    低延迟优先、直连用户
```

**设计差异：**

| 维度 | 中转机 | 落地机 | 线路落地机 |
|------|--------|--------|-----------|
| 缓冲区策略 | 中等（兼顾并发） | 大（吃满跨境带宽） | 中等（低延迟优先） |
| NOTSENT | 小（降单连接延迟） | 大（高吞吐） | 极小（即时响应） |
| swappiness | 10（容忍多进程） | 5 | 5 |

场景预设只默认写入代理并发参数。脚本会单独询问是否启用内核 IPv4/IPv6 转发，默认选择“否”；只有本机实际承担路由或 NAT 时才需要启用。

---

## 功能详解

### 1. 智能向导（推荐）

```
  [通用预设]
  1) 均衡跨境    — 默认推荐，适合大多数 VPS
  2) 低延迟交互  — SSH/游戏/远程桌面
  3) 高吞吐传输  — 大带宽/下载上传优先

  [场景化预设]
  4) 中转机      — 双向转发/大并发（如 sing-box 中转）
  5) 落地机      — 跨境上行/大缓冲（落地代理出口）
  6) 线路落地机  — CN2/IPLC/直连用户/低延迟优先

  7) 自动推荐    — 根据当前内存智能选择
```

确认后自动保存当前运行参数，再应用所选预设。

自动推荐规则：小于 768MB 使用 `latency`，768MB-4GB 使用 `balanced`，4GB 及以上使用 `throughput`。

---

### 2. 自动配置（BDP 三维计算）

根据 **内存 × 延迟 × 带宽** 三维自动计算 BDP，推导最优缓冲区。

- **内存：** 512MB / 1GB / 2GB / 4GB / 8GB / 16GB+
- **延迟：** 100ms 以内 / 100-200ms / 200ms 以上
- **带宽：** 100M / 200M / 500M / 1G / 2G / 5G / 10G

**BDP 估算：** `BDP(MB) = 带宽(Mbps) × RTT(ms) ÷ 8000`，缓冲目标按约 `1.5 × BDP` 向上取整，再匹配安全档位。所选内存高于实际物理内存时按实际值计算，最终缓冲不超过物理内存的 25%。

---

### 3. 手动选择缓冲区（两步式）

**第一步：选用途**
```
  1) 中转机      — 双向转发/大并发（如 sing-box 中转）
  2) 落地机      — 跨境上行/大缓冲（落地代理出口）
  3) 线路落地机  — CN2/IPLC/直连用户/低延迟优先
  4) 通用 / 单机 — 普通 VPS（网页/SSH/服务）
```

**第二步：选缓冲区（带场景化智能推荐）**

工具会根据所选场景 + 当前内存，给出推荐档位提示，例如中转机 2GB 内存会提示「推荐 6 (64MB) 或 7 (128MB)」。

| 档位 | 缓冲区 | 适用 |
|------|--------|------|
| 1 | 12 MB | 低带宽 / 低延迟 |
| 2 | 16 MB | 小内存保守 |
| 3 | 20 MB | 中低带宽 |
| 4 | 32 MB | 1G 跨境甜点区（~150ms BDP，推荐） |
| 5 | 40 MB | 中等带宽（1G） |
| 6 | 64 MB | 高带宽（1G+ 跨境） |
| 7 | 128 MB | 超高带宽（2G/高延迟） |
| 8 | 256 MB | 万兆 / 跨洋（5G/100ms） |
| 9 | 512 MB | 万兆 / 长距离（10G/100ms） |
| 10 | 1024 MB | 极限（10G+/200ms+，需 8G+ 内存） |

选定后待发送队列和并发参数按场景独立计算。内核转发仍需单独确认；仅启用转发的中转预设会写入按内存分档的 conntrack 参数。

---

### 4. 限速设置（tc）

防止 BBR 大缓冲区导致重传爆炸。

| 档位 | 速率 |
|------|------|
| 1-5 | 200M / 500M / 780M / 1G / 2G |
| 6 | 自定义（Mbps） |
| 7 | 取消限速 |

**队列结构（保留 BBR pacing）：** 统一用 `htb` 做聚合整形（真正的硬上限）、叶子挂 `fq` 保留 BBR 的 pacing。旧版多队列网卡用 root `tbf` 会顶掉 `fq`、废掉 BBR pacing，反而伤害跨境高 BDP 吞吐；而单纯 `fq maxrate` 只能限「每流」、限不住聚合。`htb`(整形) + `fq`(pacing) 同时满足两者。

**burst 随速率缩放：** `burst/cburst` 按速率自动缩放（约 8ms 量级，≈ RATE KB，下限 32KB），避免固定 burst 在高速率下令牌饥饿导致跑不满设定速率。

应用前会识别 root qdisc。系统默认的 `mq`、`fq`、`fq_codel`、`noqueue`、`pfifo_fast` 可直接替换，其中无法可靠删除的 `mq/noqueue` 使用 `tc qdisc replace` 原子安装 HTB。遇到外部 `tbf`、CAKE、HTB 等 QoS 时默认拒绝覆盖，并展示现有 qdisc/class/filter；输入 `FORCE <网卡>` 后才会强制接管。取消限速时外部规则会标注为“外部”，不会误报已删除；输入 `DELETE <网卡>` 后才会删除。接管或删除前会把文本与 JSON 诊断输出保存到 `/var/lib/vps-tools/tc-backups/`。支持 systemd、OpenRC 和 SysV 持久化。

限速状态保存在 `/var/lib/vps-tools/tc-fq.state`。网卡重建导致运行规则回到 `mq/fq` 时，更新脚本、应用 BBR 配置或重新进入工具会自动恢复，并刷新旧版持久化助手。界面会区分“未设置”和“已保存、未生效”；默认网卡名称变化时只提示人工确认，不会把旧配置静默迁移到新网卡。

> **依赖：** 需内核 `sch_htb` + `sch_fq` 模块（主流发行版默认含）；缺失时自动报错并清理 root qdisc，不会留半套规则。
> **OpenVZ：** 自动检测并提示，tc 通常被宿主机限制。

---

### 5. initcwnd 设置

| 档位 | 值 | 说明 |
|------|-----|------|
| 1 | 10 | 默认保守 |
| 2 | 50 | 跨国高延迟推荐 |
| 3 | 100 | 激进 |
| 4 | 自定义 | 1-1000 |

支持 IPv4、IPv6 和 `default dev eth0` 这类无网关路由，保留默认路由的 `metric`、`src`、`proto` 等属性，并支持 systemd、OpenRC 和 SysV 持久化。

> **LXC：** 自动检测，无独立网络命名空间权限时给出宿主机命令。

---

### 6 / 7. 备份与还原

首次调优会将运行参数保存为权限 `600` 的持久基线；每次应用前保存运行快照。BBR 核心参数失败或持久化文件写入失败时自动恢复本次修改前参数，场景切换时可恢复首次调优前基线，不再猜测内核默认值。

---

## 写入的 sysctl 参数

### 通用预设

```ini
# ── 内存管理 ──
vm.swappiness

# ── BBR 核心 ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── 缓冲区 ──
net.core.rmem_max / wmem_max
net.ipv4.tcp_rmem = 4096 131072 <上限>
net.ipv4.tcp_wmem = 4096 16384 <上限>
net.ipv4.tcp_notsent_lowat

# ── 连接质量 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# ── UDP 缓冲（QUIC / Hysteria2 / TUIC 代理）──
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
```

### 场景化预设额外参数

**中转机 / 落地机 / 线路落地机共有的代理并发参数：**

```ini
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535   # 扩大出站端口，防中转高并发端口耗尽
net.ipv4.tcp_max_tw_buckets = 500000         # 容纳更多 TIME_WAIT
fs.file-max = 1048576                         # 高并发 fd 上限
```

> **fd 上限提醒：** `fs.file-max` 仅系统总上限；单个代理进程的 fd 受 systemd `LimitNOFILE` 限制。应用场景预设后，脚本会自动检测常见代理 service（xray / sing-box / hysteria / tuic / v2ray / trojan / mihomo 等）的 `LimitNOFILE`，偏低时询问是否写入 `LimitNOFILE=1048576` 的 drop-in。

**用户确认路由/NAT 用途后才写入：**

```ini
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.<出口网卡>.accept_ra = 2       # forwarding 下继续接收 SLAAC RA
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

**启用转发的中转机额外写入 conntrack：**

```ini
net.netfilter.nf_conntrack_max = 131072 / 262144 / 524288 / 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
```

`nf_conntrack_max` 按 `<1GB`、`1-2GB`、`2-4GB`、`≥4GB` 四档物理内存选择。仅用户启用内核转发时尝试 `modprobe nf_conntrack`。

---

## 安全机制

| 机制 | 说明 |
|------|------|
| 内核支持检测 | 应用前检测内核 ≥ 4.9、`tcp_bbr` 模块 |
| sysctl 权限检测 | 自动识别无特权容器并拦截 |
| 物理内存校验 | 自动/智能模式按实际物理内存计算，缓冲上限 25%；手动超限需二次确认 |
| 保守 TCP 默认值 | 每连接接收默认 128KB、发送默认 16KB；`tcp_mem` 等全局内存策略交还内核 |
| 事务应用 | BBR 或 `fq` 写入失败、回读不一致时回滚运行参数，不覆盖旧持久化配置 |
| 基线恢复 | 场景残留和旧版激进参数恢复首次调优前值，不写危险的猜测默认值 |
| tc 所有权 | 默认不覆盖或删除第三方 qdisc；接管需 `FORCE <网卡>`，删除需 `DELETE <网卡>`，操作前保存快照 |
| 内核转发 | 场景预设默认不修改；路由/NAT 用途需用户明确启用 |
| IPv6 RA | 启用 forwarding 时同时设置 `default` 与当前出口 `accept_ra=2` |
| conntrack 模块 | 仅启用内核转发时尝试 modprobe，容量按内存分档 |
| 自动备份 | 每次应用保存运行快照，可一键还原 |

---

## 兼容性

| 环境 | 支持 |
|------|------|
| Debian / Ubuntu / CentOS / Rocky | ✓ 完整 |
| Alpine Linux | ✓ 需 `apk add bash`（非 bash 自动切换 / fail-fast 提示） |
| OpenWrt | △ sysctl 调优可用；tc/initcwnd 暂无 procd 持久化 |
| 服务管理 | ✓ systemd / OpenRC / SysV |
| LXC 容器 | ⚠ sysctl/initcwnd 受限，自动提示 |
| OpenVZ 容器 | ⚠ tc 限速受限，自动提示 |
| 无特权容器 | ⚠ sysctl 写入被拒，自动检测 |

---

## 实战示例

**sing-box 中转机（2GB 内存）：**
```
智能向导 → 4) 中转机
→ 选择启用内核转发，写入 64MB 缓冲 + 转发 + 按实际内存分档的 conntrack
```

**跨境落地机（8GB 内存 + 10Gbps）：**
```
手动配置 → 2) 落地机 → 9 (512MB)
→ 用户态代理选择不启用内核转发，写入 512MB 上限和代理并发参数
```

**CN2 GIA 线路落地（1GB 内存）：**
```
智能向导 → 6) 线路落地机
→ 32MB 缓冲 + NOTSENT 极小（低延迟）；仅路由/NAT 时启用转发
配合 initcwnd 50
```

---

## 关键文件路径

| 文件 | 说明 |
|------|------|
| `/etc/sysctl.d/99-vps-bbr.conf` | sysctl 调优配置 |
| `/etc/sysctl.d/99-vps-bbr.conf.bak.*` | 历史备份 |
| `/var/lib/vps-tools/bbr-sysctl-baseline.conf` | 首次调优前 sysctl 运行基线（600） |
| `/var/lib/vps-tools/tc-fq.state` | 本工具 tc 规则所有权和速率状态（600） |
| `/var/lib/vps-tools/tc-backups/` | 接管或删除外部 qdisc 前的文本与 JSON 诊断快照（目录 700、文件 600） |
| `/etc/systemd/system/tc-fq.service` | tc 限速自启 |
| `/etc/systemd/system/initcwnd.service` | initcwnd 自启 |
| `/etc/init.d/tc-fq` / `initcwnd` | OpenRC / SysV 自启脚本 |

---

## 常用查看命令

```bash
sysctl net.ipv4.tcp_congestion_control          # 当前算法
sysctl net.ipv4.tcp_available_congestion_control # 可用算法
sysctl net.core.rmem_max net.core.wmem_max       # 缓冲区
lsmod | grep tcp_bbr                              # 模块
cat /etc/sysctl.d/99-vps-bbr.conf                 # 当前配置

# 中转机查看 conntrack
sysctl net.netfilter.nf_conntrack_max
cat /proc/sys/net/netfilter/nf_conntrack_count    # 当前连接数
```

如果 `tcp_available_congestion_control` 没有 `bbr`，需换内核：

```bash
# Debian/Ubuntu
apt install linux-image-amd64 && reboot
# Alpine
apk add linux-lts && reboot
```

---

## 上游同步与验证

BBR 核心逻辑由 `SSH-Hardening/src/modules/bbr.sh` 维护，本仓库只保留独立运行包装层。固定上游提交和模块哈希记录在 `UPSTREAM.env`。

```bash
scripts/sync-from-upstream.sh ../SSH-Hardening
bash -n bbr-tune.sh
shellcheck --severity=warning -x bbr-tune.sh scripts/sync-from-upstream.sh tests/smoke.sh
scripts/sync-from-upstream.sh --check ../SSH-Hardening
tests/smoke.sh
```

完整维护规则见 [SYNC_BBR.md](SYNC_BBR.md)。主仓 BBR 发生行为修改时，两个仓库应在同一批工作中分别提交并推送。

---

## 开源地址

```
https://github.com/chnnic/BBR-tune
```

完整 VPS 开荒脚本（含本工具及更多功能）：

```
https://github.com/chnnic/SSH-Hardening
```

---

## 版本沿革

| 版本 | 主要变更 |
|------|---------|
| **同步 V3.11.6** | 修复更新或网卡重建后 tc 运行规则丢失却显示“未设置”：识别已保存但未生效的状态，更新完成、应用 BBR 配置及启动工具时自动恢复并升级旧版持久化助手；默认网卡变化时拒绝静默迁移 |
| **同步 V3.11.5** | 自动/智能配置按实际物理内存计算并将缓冲上限收紧至 25%，TCP 每连接默认缓冲恢复保守值；停止覆盖 `tcp_mem`、`min_free_kbytes` 及过时/高风险全局参数；场景转发改为按需确认，IPv6 RA 覆盖默认与当前出口，conntrack 按内存分档，并对 BBR 与 `fq` 执行写后回读和失败回滚 |
| **同步 V3.11.4** | 修复默认 `mq` 不能通过 `tc qdisc del` 删除导致限速应用及重启恢复失败，改用 `replace` 原子安装 HTB；外部限速会明确标注，输入 `DELETE <网卡>` 后可保存快照并删除 |
| **同步 V3.11.3** | tc 限速支持显式强制接管外部 `tbf` / CAKE / HTB：默认拒绝覆盖并展示拓扑，输入 `FORCE <网卡>` 后保存诊断快照、替换 root qdisc，并持久化重启后的接管授权 |
| **同步 V3.9.48** | 修复旧版生成的 `htb 1:` + `fq 100:` 限速因缺少状态文件被误判为外部 QoS；完整验证 tc 拓扑与本工具持久化标记后可安全修改或立即取消，第三方规则仍拒绝覆盖 |
| **同步 V3.9.45** | 修复场景恢复危险默认值、智能向导预检和失败误报；增加事务回滚、IPv6 RA 保护、tc 规则所有权、跨 init 持久化、IPv4/IPv6 无网关 initcwnd 路由解析，并修正 BDP 与 4GB 推荐逻辑 |
| **同步 V3.6.4** | 服务管理统一使用 `systemd_available` 检测，减少 cron / 容器环境下的 systemd 误判 |
| **同步 V3.6.3** | 新增脚本更新模块；新增 `bbr` 快捷键安装/刷新功能 |
| **同步 V3.6.2** | BBR 模块增强：sysctl 权限探测不再改变 TCP 参数；tc 限速服务运行时动态识别 `tc` 路径和默认网卡；不支持的 sysctl 参数会在持久化文件中注释；Alpine 内核包安装改为确认后执行；新增 BBR 诊断入口 |
| **同步 V3.6.1** | 修复 `initcwnd` 在无网关默认路由环境下设置失败 |
| **同步 V3.5.8** | 修复独立版缺失 4 个辅助函数（`ensure_conntrack_module` / `svc_daemon_reload` / `svc_enable` / `svc_disable`），独立运行限速 / 场景预设 / initcwnd 不再中断 |
| **同步 V3.5.6** | 新增 UDP 缓冲（QUIC/Hysteria2/TUIC）；场景预设加端口范围 + tw_buckets + file-max 防端口/fd 耗尽；应用后检测代理 service LimitNOFILE 并询问写 drop-in |
| **同步 V3.5.5** | 限速改 htb 整形 + fq pacing（多队列网卡保留 BBR pacing）；burst 随速率缩放；切换预设复位残留场景键；新增 32MB 缓冲档；修 BDP 双截断；line_landing ADV_WIN 1→2；加 bash 解释器守卫 |
| V3.5.2 | 手动配置加场景选择前置层（中转/落地/线路落地各自调优） |
| V3.5.1 | 场景预设注入转发 + conntrack 参数，自动 modprobe |
| V3.5.0 | 新增 3 个场景化预设（中转/落地/线路落地） |
| V3.4.1 | sysctl 参数精简到 15 个核心，按功能分组 |
| V3.2.5 | 支持万兆 / 4G+ 内存（256/512/1024MB 缓冲） |
| V3.2.0 | sysctl 逐行写入，跳过 Alpine 不支持的参数 |
| V3.1.6 | Alpine ash 兼容 |
| V3.0.0 | 整合 BBR 智能向导 + 三通用预设 |
