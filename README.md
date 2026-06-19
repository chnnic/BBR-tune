# BBR TCP 调优工具

> **银趴火山帮** 出品 · 从 [VPS 开荒脚本](https://github.com/chnnic/SSH-Hardening) 同步至 V3.5.9 独立提取

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
  1) 智能向导（推荐）
  2) 自动配置（内存/延迟/带宽）
  3) 手动选择缓冲区大小
  ──────────────────────────────────────
  4) 限速设置（tc）   5) initcwnd 设置
  6) 备份 TCP 配置    7) 还原 TCP 配置
  0) 返回主菜单        00) 退出脚本
```

---

## 三类预设体系

### 通用预设（普通 VPS）

| 预设 | 缓冲区（按内存动态） | 适用 |
|------|---------------------|------|
| `balanced` 均衡跨境 | 16-64 MB | 网页 / 代理 / 日常综合 |
| `latency` 低延迟交互 | 32 MB | SSH / 游戏 / 远程桌面 |
| `throughput` 高吞吐 | 64-512 MB | 大带宽 / 万兆 / 下载上传 |

只写入 15 个核心 BBR 参数，不污染系统。

### 场景化预设（代理架构专用）

| 预设 | 缓冲区（2GB 档） | NOTSENT | ADV_WIN | swap | 额外参数 |
|------|-----------------|---------|---------|------|---------|
| **中转机** `relay` | 64 MB | 256K（小） | 2 | 10 | 转发 + conntrack |
| **落地机** `landing` | 128 MB | 2M（大） | 3 | 5 | 转发 |
| **线路落地机** `line_landing` | 64 MB | 128K（极小） | 2 | 5 | 转发 |

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
| ADV_WIN | 2（标准） | 3（接收激进） | 2（保高 BDP 接收） |
| swappiness | 10（容忍多进程） | 5 | 5 |

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

应用前自动提示备份旧配置，备份后再确认应用。

---

### 2. 自动配置（BDP 三维计算）

根据 **内存 × 延迟 × 带宽** 三维自动计算 BDP，推导最优缓冲区。

- **内存：** 512MB / 1GB / 2GB / 4GB / 8GB / 16GB+
- **延迟：** 100ms 以内 / 100-200ms / 200ms 以上
- **带宽：** 100M / 200M / 500M / 1G / 2G / 5G / 10G

**BDP 估算：** `BDP = 带宽(MB/s) × 延迟(s) × 1.5`，结果超过物理内存一半自动降级。

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

选定后窗口/队列参数按场景独立计算，并自动注入对应的转发/conntrack 参数。

---

### 4. 限速设置（tc）

防止 BBR 大缓冲区导致重传爆炸。

| 档位 | 速率 |
|------|------|
| 1-5 | 200M / 500M / 780M / 1G / 2G |
| 6 | 自定义（Mbps） |
| 7 | 取消限速 |

**队列结构（保留 BBR pacing）：** 统一用 `htb` 做聚合整形（真正的硬上限）、叶子挂 `fq` 保留 BBR 的 pacing。旧版多队列网卡用 root `tbf` 会顶掉 `fq`、废掉 BBR pacing，反而伤害跨境高 BDP 吞吐；而单纯 `fq maxrate` 只能限「每流」、限不住聚合。`htb`(整形) + `fq`(pacing) 同时满足两者。

**burst 随速率缩放：** `burst/cburst` 按速率自动缩放（约 8ms 量级，≈ RATE KB，下限 32KB），避免固定 burst 在高速率下令牌饥饿导致跑不满设定速率。持久化到 `/etc/systemd/system/tc-fq.service`（`After/Wants=network-online.target`，确保网卡就绪后再应用）。

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

持久化到 `/etc/systemd/system/initcwnd.service`。

> **LXC：** 自动检测，无独立网络命名空间权限时给出宿主机命令。

---

### 6 / 7. 备份与还原

应用新配置前自动备份带时间戳的旧配置，可一键还原或清除全部备份。

---

## 写入的 sysctl 参数

### 通用预设（15 个核心参数）

```ini
# ── 内存管理 ──
vm.swappiness
vm.min_free_kbytes

# ── BBR 核心 ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── 缓冲区 ──
net.core.rmem_max / wmem_max
net.ipv4.tcp_rmem / tcp_wmem
net.ipv4.tcp_mem
net.ipv4.tcp_adv_win_scale
net.ipv4.tcp_notsent_lowat

# ── 连接质量 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 60

# ── UDP 缓冲（QUIC / Hysteria2 / TUIC 代理）──
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
```

### 场景化预设额外参数

**中转机 / 落地机 / 线路落地机 共有（8 项转发/并发参数）：**

```ini
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535   # 扩大出站端口，防中转高并发端口耗尽
net.ipv4.tcp_max_tw_buckets = 500000         # 容纳更多 TIME_WAIT
fs.file-max = 1048576                         # 高并发 fd 上限
```

> **fd 上限提醒：** `fs.file-max` 仅系统总上限；单个代理进程的 fd 受 systemd `LimitNOFILE` 限制。应用场景预设后，脚本会自动检测常见代理 service（xray / sing-box / hysteria / tuic / v2ray / trojan / mihomo 等）的 `LimitNOFILE`，偏低时询问是否写入 `LimitNOFILE=1048576` 的 drop-in。

**仅中转机额外（3 项 conntrack）：**

```ini
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
```

应用场景预设前自动 `modprobe nf_conntrack` 加载内核模块。

---

## 安全机制

| 机制 | 说明 |
|------|------|
| 内核支持检测 | 应用前检测内核 ≥ 4.9、`tcp_bbr` 模块 |
| sysctl 权限检测 | 自动识别无特权容器并拦截 |
| 物理内存校验 | 缓冲区超过物理内存一半自动降级 |
| 逐行应用 | `sysctl -w` 逐行写入，跳过内核不支持的参数 |
| conntrack 模块 | 场景预设前自动 modprobe |
| 自动备份 | 应用前备份，可一键还原 |

---

## 兼容性

| 环境 | 支持 |
|------|------|
| Debian / Ubuntu / CentOS / Rocky | ✓ 完整 |
| Alpine Linux | ✓ 需 `apk add bash`（非 bash 自动切换 / fail-fast 提示） |
| OpenWrt | ✓ dumb 终端兼容 |
| LXC 容器 | ⚠ sysctl/initcwnd 受限，自动提示 |
| OpenVZ 容器 | ⚠ tc 限速受限，自动提示 |
| 无特权容器 | ⚠ sysctl 写入被拒，自动检测 |

---

## 实战示例

**sing-box 中转机（2GB 内存）：**
```
智能向导 → 4) 中转机
→ 自动写入 64MB 缓冲 + 转发 + conntrack（1048576 连接）
```

**跨境落地机（8GB 内存 + 10Gbps）：**
```
手动配置 → 2) 落地机 → 8 (512MB)
→ 512MB 大缓冲吃满带宽 + 转发参数
```

**CN2 GIA 线路落地（1GB 内存）：**
```
智能向导 → 6) 线路落地机
→ 32MB 缓冲 + ADV_WIN=2（保高 BDP 接收）+ NOTSENT 极小（低延迟）+ 转发参数
配合 initcwnd 50
```

---

## 关键文件路径

| 文件 | 说明 |
|------|------|
| `/etc/sysctl.d/99-vps-bbr.conf` | sysctl 调优配置 |
| `/etc/sysctl.d/99-vps-bbr.conf.bak.*` | 历史备份 |
| `/etc/systemd/system/tc-fq.service` | tc 限速自启 |
| `/etc/systemd/system/initcwnd.service` | initcwnd 自启 |

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
