# BBR TCP 调优工具

> **银趴火山帮** 出品 · 从 [VPS 开荒脚本](https://github.com/chnnic/SSH-Hardening) 独立提取

专注 TCP 性能调优的交互式工具，支持智能向导、自动计算、手动配置、tc 限速、initcwnd 调整，适用于跨境代理、游戏、大文件传输等不同场景。

---

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chnnic/BBR-tune/refs/heads/main/bbr-tcp.sh)
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
  网卡 eth0  CC bbr  cwnd 10  限速 未设置
  缓冲 rmem 64MB  wmem 64MB  tcp_r 64MB  tcp_w 64MB
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

状态栏实时显示网卡、拥塞控制算法、initcwnd、限速、缓冲区大小。

---

## 功能详解

### 1. 智能向导（推荐）

启动时自动检测当前内存、内核版本、拥塞控制算法，给出推荐预设，也可手动选择。

| 选项 | 预设 | 适用场景 | 缓冲区 |
|------|------|---------|--------|
| 1 | `balanced` 均衡跨境 | 网页 / 代理 / 日常综合（**默认推荐**） | 64 MB |
| 2 | `latency` 低延迟交互 | SSH / 游戏 / 远程桌面 / 小包优先 | 32 MB |
| 3 | `throughput` 高吞吐传输 | 大带宽 / 高延迟 / 下载上传优先 | 128 MB |
| 4 | 自动推荐 | 根据当前内存智能选择 | — |

**自动推荐逻辑：**

| 内存 | 推荐预设 |
|------|---------|
| < 768 MB | `latency`（小内存轻量） |
| 768 MB ~ 1.5 GB | `balanced`（均衡） |
| > 1.5 GB | `balanced`（大流量可手动切 `throughput`） |

应用前自动提示备份旧配置（默认 Y），备份后再确认应用（默认 Y）。

---

### 2. 自动配置（BDP 三维计算）

根据**内存 × 延迟 × 带宽**三个维度自动计算 BDP（带宽时延积），推导最优缓冲区。

**内存选项：** 512 MB / 1 GB / 2 GB

**延迟选项：**

| 选项 | 适用场景 |
|------|---------|
| 100ms 以内 | 国内 / 亚洲近距离 |
| 100 ~ 200ms | 跨国（如美西→中国） |
| 200ms 以上 | 欧洲→中国 / 长距离 |

**带宽选项：** 100 Mbps / 200 Mbps / 500 Mbps / 1 Gbps / 2 Gbps

BDP 估算公式：`BDP = 带宽(MB/s) × 延迟(s) × 1.5`，结果自动映射到最近档缓冲区。

---

### 3. 手动选择缓冲区

自动检测系统内存，内存相关参数（tcp_mem / min_free / swappiness）自动匹配，只需选择缓冲区大小。

| 选项 | 缓冲区 | 适用场景 |
|------|--------|---------|
| 1 | 12 MB | 低带宽 / 低延迟 |
| 2 | 16 MB | 小内存保守 |
| 3 | 20 MB | 中低带宽 |
| 4 | 40 MB | 中等带宽 |
| 5 | 64 MB | 高带宽推荐 |
| 6 | 128 MB | 超高带宽 / 高延迟 |

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
/etc/sysctl.d/99-vps-bbr.conf.bak.20260509_163000
```

---

## 写入的 sysctl 参数

配置写入 `/etc/sysctl.d/99-vps-bbr.conf`，不修改 `/etc/sysctl.conf`。

| 参数 | 说明 |
|------|------|
| `net.core.default_qdisc = fq` | 配合 BBR 使用 fq 队列 |
| `net.ipv4.tcp_congestion_control = bbr` | 启用 BBR 拥塞控制 |
| `net.core.rmem_max / wmem_max` | Socket 读写缓冲区上限 |
| `net.ipv4.tcp_rmem / tcp_wmem` | TCP 读写缓冲区范围 |
| `net.ipv4.tcp_fastopen = 3` | 客户端+服务端均启用 TFO |
| `net.ipv4.tcp_adv_win_scale` | 接收窗口缩放系数 |
| `net.ipv4.tcp_notsent_lowat` | 发送队列低水位，配合 BBR 减少延迟 |
| `net.ipv4.tcp_mtu_probing = 1` | 路径 MTU 探测，改善跨境链路 |
| `net.ipv4.tcp_ecn = 2` | ECN 显式拥塞通知 |
| `net.ipv4.tcp_tw_reuse = 1` | TIME_WAIT 复用 |
| `net.ipv4.tcp_fin_timeout = 10` | 缩短 FIN_WAIT 超时 |
| `net.ipv4.tcp_slow_start_after_idle = 0` | 空闲后不重置拥塞窗口 |
| `net.ipv4.tcp_keepalive_time = 60` | keepalive 探测间隔 |
| `net.ipv4.conf.all.arp_announce = 2` | 多 IP VPS 防 ARP 泄露 |
| `vm.swappiness` | 内存交换倾向（按预设自动设置） |
| `vm.min_free_kbytes` | 内核保留内存下限 |

**有意删除的参数（VPS 无意义或有害）：**

| 参数 | 原因 |
|------|------|
| `kernel.numa_balancing` | NUMA 是物理多路服务器特性，VPS 无效 |
| `kernel.panic / sysrq / pid_max` | 与 TCP 调优无关 |
| `vm.overcommit_memory` | Redis 专用配置，不应默认写入 |
| `net.ipv4.conf.all.rp_filter` | 新内核默认已是严格模式，强行设 1 反而宽松 |
| `tcp_timestamps / tcp_window_scaling / tcp_sack` | 内核默认开启，重复设置无意义 |

---

## 兼容性

| 环境 | 支持情况 |
|------|---------|
| Debian / Ubuntu | ✓ 完整支持 |
| CentOS / Rocky / AlmaLinux | ✓ 完整支持 |
| Alpine Linux | ✓ BusyBox 兼容（mktemp 用 PID 替代） |
| OpenWrt | ✓ dumb 终端兼容（safe_clear） |
| KVM / 独立 VPS | ✓ 完整支持 |
| LXC 容器 | ⚠ sysctl / initcwnd 功能受限，自动提示 |
| OpenVZ 容器 | ⚠ tc 限速受限，自动提示 |

---

## 关键文件路径

| 文件 | 说明 |
|------|------|
| `/etc/sysctl.d/99-vps-bbr.conf` | sysctl 调优配置（主配置） |
| `/etc/sysctl.d/99-vps-bbr.conf.bak.*` | 历史备份文件 |
| `/etc/systemd/system/tc-fq.service` | tc 限速开机自启服务 |
| `/etc/systemd/system/initcwnd.service` | initcwnd 开机自启服务 |

---

## 开源地址

```
https://github.com/chnnic/BBR-tune
```

VPS 开荒脚本（包含本工具及更多功能）：

```
https://github.com/chnnic/SSH-Hardening
```
