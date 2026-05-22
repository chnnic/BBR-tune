# BBR TCP 调优工具

> **银趴火山帮** 出品 · 从 [VPS 开荒脚本](https://github.com/chnnic/SSH-Hardening) V3.4.1 独立提取

专注 TCP 性能调优的交互式工具，支持智能向导、自动 BDP 计算、手动配置、tc 限速、initcwnd 调整，适用于跨境代理、游戏、万兆传输等不同场景。

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
  缓冲 rmem 64MB  wmem 64MB  tcp_r 64MB  tcp_w 64MB  物理内存 2048MB
  ──────────────────────────────────────
  1) 智能向导（推荐）
  2) 自动配置（内存/延迟/带宽）
  3) 手动选择缓冲区大小
  ──────────────────────────────────────
  4) 限速设置（tc）   5) initcwnd 设置
  6) 备份 TCP 配置    7) 还原 TCP 配置
  0) 返回主菜单        00) 退出脚本
  ──────────────────────────────────────
  请选择 [0-7]:
```

**状态栏实时显示：**
- 网卡名、拥塞控制算法（CC）、initcwnd、tc 限速
- rmem_max / wmem_max / tcp_rmem max / tcp_wmem max
- 物理内存（缓冲区超过一半时显示黄色警告）

---

## 功能详解

### 1. 智能向导（推荐）

启动时自动检测当前内存、内核 BBR 支持，给出推荐预设：

| 选项 | 预设 | 适用场景 |
|------|------|---------|
| 1 | `balanced` 均衡跨境 | 网页 / 代理 / 日常综合 |
| 2 | `latency` 低延迟交互 | SSH / 游戏 / 远程桌面 / 小包优先 |
| 3 | `throughput` 高吞吐传输 | 大带宽 / 高延迟 / 下载上传 |
| 4 | 自动推荐 | 根据当前内存智能选择 |

**自动推荐逻辑：**

| 内存 | 推荐预设 |
|------|---------|
| < 512 MB | `latency`（极小内存） |
| < 768 MB | `latency`（小内存） |
| < 1.5 GB | `balanced`（均衡） |
| < 4 GB | `balanced`（2G 中等） |
| ≥ 4 GB | `throughput`（万兆 / 跨洋） |

应用前自动提示备份旧配置（默认 Y），备份后再确认应用（默认 Y）。

---

### 2. 自动配置（BDP 三维计算）

根据 **内存 × 延迟 × 带宽** 三个维度自动计算 BDP（带宽时延积），推导最优缓冲区。

**内存选项：** 512MB / 1GB / 2GB / 4GB / 8GB / 16GB+

**延迟选项：**

| 选项 | 适用场景 |
|------|---------|
| 100ms 以内 | 国内 / 亚洲近距离 |
| 100 ~ 200ms | 跨国（如美西→中国） |
| 200ms 以上 | 欧洲→中国 / 长距离 |

**带宽选项：** 100M / 200M / 500M / 1G / 2G / 5G / 10G

**BDP 估算公式：** `BDP = 带宽(MB/s) × 延迟(s) × 1.5`，结果自动映射到对应缓冲区档位。

**安全保护：** 计算结果超过物理内存一半时自动降级。

---

### 3. 手动选择缓冲区

自动检测系统内存，内存相关参数（tcp_mem / min_free / swappiness）自动匹配，只需选择缓冲区大小：

| 选项 | 缓冲区 | 适用场景 |
|------|--------|---------|
| 1 | 12 MB | 低带宽 / 低延迟 |
| 2 | 16 MB | 小内存保守 |
| 3 | 20 MB | 中低带宽 |
| 4 | 40 MB | 中等带宽（1G） |
| 5 | 64 MB | 高带宽（1G+ 跨境） |
| 6 | 128 MB | 超高带宽（2G/高延迟） |
| 7 | 256 MB | 万兆 / 跨洋（5G/100ms） |
| 8 | 512 MB | 万兆 / 长距离（10G/100ms） |
| 9 | 1024 MB | 极限（10G+/200ms+，需 8G+ 内存） |

选择超过物理内存一半的档位时会警告确认，避免低内存机器误选导致 OOM。

---

### 4. 限速设置（tc）

使用 `tc` 对出口带宽进行精确限速，防止 BBR 大缓冲区导致重传（Retr）爆炸。

| 选项 | 速率 |
|------|------|
| 1 | 200 Mbps |
| 2 | 500 Mbps |
| 3 | 780 Mbps |
| 4 | 1 Gbps（1024 Mbps） |
| 5 | 2 Gbps（2048 Mbps） |
| 6 | 自定义（输入 Mbps 值） |
| 7 | 取消限速 |

**自动适配队列类型：** 检测网卡队列数，多队列（mq）使用 `tbf`，单队列使用 `fq maxrate`。

**持久化：** 限速规则写入 `/etc/systemd/system/tc-fq.service`，重启后自动恢复。

> **OpenVZ 容器：** 自动检测并提示，tc 在 OpenVZ 共享内核下通常被宿主机限制，建议联系服务商在宿主机层面配置。

---

### 5. initcwnd 设置

调整 TCP 初始拥塞窗口，对高延迟线路的首包速度提升明显。

| 选项 | 值 | 说明 |
|------|-----|------|
| 1 | 10 | 默认保守 |
| 2 | 50 | 跨国高延迟推荐 |
| 3 | 100 | 激进（可能丢包） |
| 4 | 自定义 | 1 ~ 1000 |

**持久化：** 写入 `/etc/systemd/system/initcwnd.service`，重启后自动执行。

> **LXC 容器：** 自动检测，LXC 无独立网络命名空间权限，`ip route change` 会被拒绝，工具会提示并给出宿主机手动命令。

---

### 6 / 7. 备份与还原

**备份：** 将当前 `/etc/sysctl.d/99-vps-bbr.conf` 复制为带时间戳的备份文件，每次应用新配置前自动触发（默认 Y）。

**还原：** 列出所有历史备份，按编号选择还原，并立即 `sysctl -p` 生效。支持一键清除全部备份。

备份文件示例：
```
/etc/sysctl.d/99-vps-bbr.conf.bak.20260522_163000
```

---

## 写入的 sysctl 参数（V3.4.1 精简版）

配置写入 `/etc/sysctl.d/99-vps-bbr.conf`，不修改 `/etc/sysctl.conf`。

**仅 15 个核心参数，按功能分 4 组：**

```ini
# ── 内存管理 ──
vm.swappiness                          # 内存交换倾向
vm.min_free_kbytes                     # 内核保留内存下限

# ── BBR 核心 ──
net.core.default_qdisc = fq            # 配合 BBR 的队列算法
net.ipv4.tcp_congestion_control = bbr  # 启用 BBR 拥塞控制

# ── 缓冲区 ──
net.core.rmem_max                      # Socket 读缓冲上限
net.core.wmem_max                      # Socket 写缓冲上限
net.ipv4.tcp_rmem                      # TCP 读缓冲范围
net.ipv4.tcp_wmem                      # TCP 写缓冲范围
net.ipv4.tcp_mem                       # TCP 总内存控制
net.ipv4.tcp_adv_win_scale             # 接收窗口缩放系数
net.ipv4.tcp_notsent_lowat             # 发送队列低水位

# ── 连接质量 ──
net.ipv4.tcp_fastopen = 3              # 启用 TCP Fast Open
net.ipv4.tcp_mtu_probing = 1           # PMTU 探测（改善跨境链路）
net.ipv4.tcp_ecn = 2                   # ECN 显式拥塞通知
net.ipv4.tcp_slow_start_after_idle = 0 # 空闲后不重置拥塞窗口
net.ipv4.tcp_tw_reuse = 1              # TIME_WAIT 复用
net.ipv4.tcp_fin_timeout = 10          # 缩短 FIN_WAIT 超时
net.ipv4.tcp_keepalive_time = 60       # keepalive 探测间隔
```

**有意删除的参数（VPS 无意义或内核已最优）：**

| 参数 | 删除原因 |
|------|---------|
| `vm.dirty_background_ratio` | 与 BBR 无关，影响磁盘写入策略 |
| `kernel.numa_balancing` | NUMA 是多路服务器特性，VPS 无效 |
| `kernel.panic / sysrq / pid_max` | 与 TCP 调优无关 |
| `vm.overcommit_memory` | Redis 专用，不应默认写入 |
| `net.core.netdev_max_backlog` | 万兆+ 才用得上，VPS 默认够 |
| `net.core.somaxconn` | 应用层参数 |
| `net.core.rmem_default / wmem_default` | 内核默认 212992 已最佳 |
| `net.ipv4.tcp_no_metrics_save` | 默认 0 已最佳 |
| `net.ipv4.tcp_max_tw_buckets` | 内核根据内存自动调整 |
| `net.ipv4.tcp_max_syn_backlog` | 内核默认通常够用 |
| `net.ipv4.tcp_keepalive_intvl / probes` | 细节非必须 |
| `net.ipv4.ip_local_port_range` | 跟拥塞控制无关 |
| `net.ipv4.conf.all.rp_filter` | 新内核默认严格模式，强行 1 反而宽松 |
| `net.ipv4.conf.all.arp_announce` | 单 IP VPS 无意义 |
| `tcp_timestamps / tcp_window_scaling / tcp_sack` | 内核默认开启，重复设置无意义 |

---

## 安全机制

| 机制 | 说明 |
|------|------|
| **内核支持检测** | 应用前检测内核 ≥ 4.9、`tcp_bbr` 模块、`tcp_available_congestion_control` |
| **sysctl 权限检测** | 自动识别无特权容器，立即拦截并提示 |
| **物理内存校验** | 缓冲区超过物理内存一半自动降级或警告 |
| **逐行应用** | `sysctl -w` 逐行写入，跳过 Alpine 等内核不支持的参数（如 `default_qdisc`） |
| **自动备份** | 应用前自动备份旧配置，可一键还原 |
| **配置校验** | 写入前先用 `nft -c` 等价方式校验 |

---

## 兼容性

| 环境 | 支持情况 |
|------|---------|
| Debian / Ubuntu | ✓ 完整支持 |
| CentOS / Rocky / AlmaLinux | ✓ 完整支持 |
| Alpine Linux | ✓ BusyBox ash 兼容（去除 `[[ ]]` / `=~` / 数组等 bash 专属语法） |
| OpenWrt | ✓ dumb 终端兼容（`safe_clear`） |
| KVM / 独立 VPS | ✓ 完整支持 |
| LXC 容器 | ⚠ sysctl / initcwnd 功能受限，自动提示 |
| OpenVZ 容器 | ⚠ tc 限速受限，自动提示 |
| 无特权容器 | ⚠ sysctl 写入被拒，自动检测并友好提示 |

---

## 万兆 / 大内存场景实战

**10 Gbps + 8GB 内存 VPS 推荐配置：**

```
智能向导 → 自动推荐 throughput 预设
↓
缓冲区 256 MB（rmem_max / wmem_max）
↓
tcp_mem 262144 393216 786432
↓
min_free_kbytes 131072
```

**跨洋大流量（10Gbps + 200ms）：**

```
手动配置 → 选 512 MB 缓冲区
↓
配合 initcwnd 50（跨国高延迟推荐）
↓
启用 tc 限速 9Gbps（防止重传爆炸）
```

---

## 关键文件路径

| 文件 | 说明 |
|------|------|
| `/etc/sysctl.d/99-vps-bbr.conf` | sysctl 调优配置（主配置） |
| `/etc/sysctl.d/99-vps-bbr.conf.bak.*` | 历史备份文件（按时间戳） |
| `/etc/systemd/system/tc-fq.service` | tc 限速开机自启服务 |
| `/etc/systemd/system/initcwnd.service` | initcwnd 开机自启服务 |

---

## 常用查看命令

```bash
# 当前拥塞控制算法
sysctl net.ipv4.tcp_congestion_control

# 可用拥塞控制算法（确认 bbr 是否支持）
sysctl net.ipv4.tcp_available_congestion_control

# 缓冲区
sysctl net.core.rmem_max net.core.wmem_max
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem

# 队列算法
sysctl net.core.default_qdisc

# tcp_bbr 模块
lsmod | grep tcp_bbr

# 查看当前生效配置
cat /etc/sysctl.d/99-vps-bbr.conf
```

如果 `tcp_available_congestion_control` 里没有 `bbr`，说明内核不支持，需要换内核：

```bash
# Debian/Ubuntu
apt install linux-image-amd64
reboot

# Alpine
apk add linux-lts
reboot
```

---

## 开源地址

```
https://github.com/chnnic/BBR-tune
```

完整 VPS 开荒脚本（包含本工具及更多功能）：

```
https://github.com/chnnic/SSH-Hardening
```

---

## 版本沿革

| 版本 | 主要变更 |
|------|---------|
| **基于主脚本 V3.4.1** | sysctl 参数精简到 15 个，按功能分组 |
| V3.2.5 | 支持万兆 / 4G+ 内存（256/512/1024MB 缓冲区） |
| V3.2.1 | 无特权容器 sysctl 权限检测 |
| V3.2.0 | sysctl 逐行写入，跳过 Alpine 不支持的参数 |
| V3.1.9 | balanced 预设按内存动态调整 |
| V3.1.8 | 内核 BBR 支持检测（kernel ≥ 4.9） |
| V3.1.6 | Alpine ash 兼容（去除 bash 专属语法） |
| V3.0.0 | 整合 BBR 智能向导 + 三预设（balanced/latency/throughput） |
