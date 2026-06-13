#!/bin/bash

# ============================================================
#  BBR TCP 调优工具 — 银趴火山帮
#  从 VPS 开荒脚本独立提取（同步至 V3.5.7）
#  含场景化预设：中转机 / 落地机 / 线路落地机
#  V3.5.6: 新增 UDP 缓冲(QUIC/Hysteria2)、场景预设加端口范围/tw_buckets/file-max
#          防高并发端口耗尽、应用场景预设后检测代理 service LimitNOFILE
#  V3.5.5: 限速改 htb 整形+fq pacing(保 BBR)、burst 随速率缩放、
#          切换预设复位残留场景键、新增 32MB 缓冲档、修 BDP 双截断
#  用法：bash bbr-tune.sh
# ============================================================

# ── 解释器守卫：本脚本依赖 bash（数组 / [[ ]] / here-string 等）──
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "本脚本需要 bash 运行，当前 shell 不是 bash 且系统未安装 bash。"
    echo "请先安装 bash 后重试："
    echo "  Alpine:   apk add bash"
    echo "  OpenWrt:  opkg update && opkg install bash"
    echo "  Debian:   apt-get install -y bash"
    echo "  CentOS:   yum install -y bash"
    exit 1
fi

# ── 颜色定义 ──────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

# ── 提示函数 ──────────────────────────────────────────────
info()  { echo -e "  ${GREEN}✔${NC}  $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
error() { echo -e "  ${RED}✘${NC}  $1"; }

# ── 终端兼容 ──────────────────────────────────────────────
safe_clear() {
    if [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        clear 2>/dev/null || true
    fi
}

# ── 字符长度（中文按 2，英文按 1）─────────────────────────
vis_len() {
    python3 -c "
import unicodedata, sys
s = sys.argv[1]
print(sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s))
" "$1" 2>/dev/null || echo "${#1}"
}

# ── 框线绘制 ──────────────────────────────────────────────
BOX_W=42
box_top() { printf "${CYAN}"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }
box_bot() { printf "${CYAN}"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }
box_sep() { printf "${CYAN}"; printf '─%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }
box_title() {
    local TEXT="$1"
    local LEN; LEN=$(vis_len "$TEXT")
    local INNER=$((BOX_W - 2))
    local PAD_TOTAL=$(( INNER - LEN ))
    local PAD_L=$(( PAD_TOTAL / 2 ))
    local PAD_R=$(( PAD_TOTAL - PAD_L ))
    printf '%*s' "$PAD_L" ''
    printf "${BOLD}${CYAN}%s${NC}" "$TEXT"
    printf '%*s' "$PAD_R" ''
    printf "\n"
}
box_line() {
    local PLAIN="$1"
    local COLORED="${2:-$1}"
    echo -e "$COLORED"
}

# ── 标准标题栏 ────────────────────────────────────────────
print_header() {
    safe_clear
    echo ""
    box_top
    box_title "BBR TCP 调优工具"
    box_line "  ··银趴火山帮··" "  ${DIM}··银趴火山帮··${NC}"
    box_sep
    box_title "$1"
    box_bot
    echo ""
}

# ── root 检查 ─────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} 请使用 root 权限运行：sudo bash $0"
    exit 1
fi

# ── 包管理器 ──────────────────────────────────────────────
pkg_install() {
    local PKG="$1"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null && apt-get install -y "$PKG" 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add --no-cache "$PKG" 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y "$PKG" 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y "$PKG" 2>/dev/null
    else
        return 1
    fi
}

# ── 编辑器自动选择 ────────────────────────────────────────
get_editor() {
    for ed in nano vi vim; do
        command -v "$ed" &>/dev/null && echo "$ed" && return
    done
    echo "vi"
}

# ── sysctl 可用性 ─────────────────────────────────────────
ensure_sysctl() {
    command -v sysctl &>/dev/null && return 0
    warn "sysctl 未找到，正在安装..."
    if command -v apk &>/dev/null; then
        apk add --no-cache procps 2>/dev/null || true
    else
        pkg_install procps 2>/dev/null || true
    fi
    command -v sysctl &>/dev/null
}

# ── 容器检测 ──────────────────────────────────────────────
is_openvz() {
    [ -f /proc/vz/veinfo ] && return 0
    grep -qaE 'openvz|lxc' /proc/1/environ 2>/dev/null && return 0
    grep -qaE 'openvz|lxc' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

is_lxc() {
    grep -qa "lxc" /proc/1/environ 2>/dev/null \
    || [ -f /run/systemd/container ] \
    || grep -qa "container=lxc" /proc/1/environ 2>/dev/null \
    || { [ -f /proc/1/cgroup ] && grep -qa "lxc" /proc/1/cgroup 2>/dev/null; }
}

has_sysctl_write() {
    sysctl -w net.ipv4.tcp_fin_timeout=10 > /dev/null 2>&1 && return 0
    return 1
}

# ══════════════════════════════════════════════════════════
#  BBR TCP 调优模块
# ══════════════════════════════════════════════════════════

SERVICE_TC="/etc/systemd/system/tc-fq.service"
SYSCTL_FILE="/etc/sysctl.d/99-vps-bbr.conf"

# ── 状态显示 ──────────────────────────────────────────────
bbr_print_status() {
    local DEV; DEV=$(ip route | awk '/^default/{print $5}')
    local RATE; RATE=$(tc qdisc show dev "$DEV" 2>/dev/null | grep -oE '(maxrate|rate) [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$RATE" ] && RATE="未设置"
    local BBR; BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local CWND
    CWND=$(ip route show 2>/dev/null | grep "^default" | grep -oE 'initcwnd [0-9]+' | awk '{print $2}')
    [ -z "$CWND" ] && CWND="10（默认）"

    # 读取缓冲区大小
    local RMEM_MAX WMEM_MAX RMEM_MB WMEM_MB
    RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    RMEM_MB=$(( RMEM_MAX / 1048576 ))
    WMEM_MB=$(( WMEM_MAX / 1048576 ))

    # tcp_rmem / tcp_wmem 的 max 字段
    local TCP_RMEM_MAX TCP_WMEM_MAX TCP_RMEM_MB TCP_WMEM_MB
    TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    TCP_WMEM_MAX=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    TCP_RMEM_MB=$(( ${TCP_RMEM_MAX:-0} / 1048576 ))
    TCP_WMEM_MB=$(( ${TCP_WMEM_MAX:-0} / 1048576 ))

    echo -e "  ${CYAN}网卡${NC} ${BOLD}$DEV${NC}  ${CYAN}CC${NC} ${BOLD}$BBR${NC}  ${CYAN}cwnd${NC} ${BOLD}$CWND${NC}  ${CYAN}限速${NC} ${BOLD}$RATE${NC}"
    # 检测缓冲区是否超过物理内存一半（显示警告）
    local MEM_TOTAL_MB
    MEM_TOTAL_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
    local RMEM_COLOR WMEM_COLOR
    RMEM_COLOR="$BOLD"
    WMEM_COLOR="$BOLD"
    if [ "${MEM_TOTAL_MB:-0}" -gt 0 ]; then
        [ "$RMEM_MB" -gt $(( MEM_TOTAL_MB / 2 )) ] && RMEM_COLOR="${YELLOW}${BOLD}"
        [ "$WMEM_MB" -gt $(( MEM_TOTAL_MB / 2 )) ] && WMEM_COLOR="${YELLOW}${BOLD}"
    fi
    echo -e "  ${CYAN}缓冲${NC} rmem ${RMEM_COLOR}${RMEM_MB}MB${NC}  wmem ${WMEM_COLOR}${WMEM_MB}MB${NC}  tcp_r ${BOLD}${TCP_RMEM_MB}MB${NC}  tcp_w ${BOLD}${TCP_WMEM_MB}MB${NC}  ${DIM}物理内存 ${MEM_TOTAL_MB}MB${NC}"
}

# ── 备份 sysctl ───────────────────────────────────────────
bbr_backup_sysctl() {
    if [ -f "$SYSCTL_FILE" ]; then
        local BAK="${SYSCTL_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$SYSCTL_FILE" "$BAK"
        info "已备份至：$BAK"
    fi
}

# ── 还原 sysctl ───────────────────────────────────────────
bbr_restore_sysctl() {
    print_header "还原 TCP sysctl 配置"

    # 用 /tmp 临时文件列表替代 bash 数组（兼容 Alpine ash）
    local LIST_FILE="/tmp/vps_bbr_bak_$$"
    ls -t "${SYSCTL_FILE}.bak."* 2>/dev/null > "$LIST_FILE"

    if [ ! -s "$LIST_FILE" ]; then
        rm -f "$LIST_FILE"
        warn "未找到任何备份文件"
        return
    fi

    local i=1
    while IFS= read -r f; do
        # stat 兼容：BusyBox stat 用 -c '%y'，但格式有差异，改用 ls -l 更通用
        local FDATE
        FDATE=$(ls -l "$f" 2>/dev/null | awk '{print $6, $7}')
        echo -e "  ${GREEN}[$i]${NC} $(basename "$f")  ${DIM}${FDATE}${NC}"
        i=$(( i + 1 ))
    done < "$LIST_FILE"

    local TOTAL=$(( i - 1 ))
    echo -e "  ${YELLOW}[d]${NC} 清除全部备份"
    echo -e "  ${RED}[0]${NC} 返回"
    echo ""
    read -rp "  请选择: " CH

    case "$CH" in
        0) rm -f "$LIST_FILE"; return ;;
        00) rm -f "$LIST_FILE"; safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        d|D)
            read -rp "  确认清除全部 ${TOTAL} 个备份？(Y/n，默认Y): " C
            [ -z "$C" ] && C="y"
            if echo "$C" | grep -qiE '^y(es)?$'; then
                rm -f "${SYSCTL_FILE}.bak."*
                info "已清除全部备份 ✓"
            else
                warn "已取消"
            fi
            ;;
        *)
            # 纯数字且在范围内
            if echo "$CH" | grep -qE '^[0-9]+$' && [ "$CH" -ge 1 ] && [ "$CH" -le "$TOTAL" ]; then
                local T
                T=$(sed -n "${CH}p" "$LIST_FILE")
                cp "$T" "$SYSCTL_FILE"
                ensure_sysctl && sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1
                info "已还原：$(basename "$T") ✓"
            else
                error "无效选项"
            fi
            ;;
    esac
    rm -f "$LIST_FILE"
}

# ── 应用 sysctl ───────────────────────────────────────────
bbr_apply_sysctl() {
    local CONFIG="$1"
    ensure_sysctl || return 1
    mkdir -p "$(dirname "$SYSCTL_FILE")" 2>/dev/null || true

    # ── 切换预设时复位「旧配置写过、但新配置不再包含」的场景专有键 ──
    # 否则从中转/落地降级回普通预设后，ip_forward / conntrack 等会一直残留在内核里。
    # 仅复位本脚本场景预设管理的键，且新配置确实不含该键时才动；ip_forward 谨慎处理。
    if [ -f "$SYSCTL_FILE" ]; then
        local SCENE_KEYS="net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_tcp_timeout_established net.netfilter.nf_conntrack_tcp_timeout_time_wait net.ipv4.ip_local_port_range net.ipv4.tcp_max_tw_buckets fs.file-max"
        local k STALE=""
        for k in $SCENE_KEYS; do
            if grep -qE "^${k} *=" "$SYSCTL_FILE" 2>/dev/null && ! echo "$CONFIG" | grep -qE "^${k} *="; then
                STALE="$STALE $k"
            fi
        done
        if [ -n "$STALE" ]; then
            warn "检测到上次场景预设遗留参数，新预设不再需要："
            for k in $STALE; do echo -e "    ${DIM}${k}${NC}"; done
            if echo "$STALE" | grep -q 'ip_forward'; then
                warn "其中 ip_forward 复位后将关闭内核转发，若本机仍在做端口转发/中转请勿复位"
            fi
            read -rp "  是否复位这些残留参数为系统默认？(y/N，默认N): " DORST
            [ -z "$DORST" ] && DORST="n"
            if echo "$DORST" | grep -qiE '^y(es)?$'; then
                for k in $STALE; do
                    # 端口范围 / tw_buckets / file-max 复位成 0 非法或有害，给内核安全默认
                    case "$k" in
                        net.ipv4.ip_forward|net.ipv6.conf.all.forwarding) sysctl -w "${k}=0" >/dev/null 2>&1 ;;
                        net.ipv4.ip_local_port_range) sysctl -w "${k}=32768 60999" >/dev/null 2>&1 || true ;;
                        net.ipv4.tcp_max_tw_buckets)  sysctl -w "${k}=131072" >/dev/null 2>&1 || true ;;
                        fs.file-max)                  : ;;
                        *) sysctl -w "${k}=0" >/dev/null 2>&1 || true ;;
                    esac
                done
                info "残留场景参数已复位"
            else
                warn "保留残留参数（仍生效于当前内核，直到下次手动复位或重启）"
            fi
        fi
    fi

    echo "$CONFIG" > "$SYSCTL_FILE"

    # 逐行应用，跳过不支持的参数（Alpine 部分内核不支持 default_qdisc 等）
    local FAILED=0 SKIPPED=0
    while IFS= read -r line; do
        # 跳过注释和空行
        echo "$line" | grep -qE '^\s*#|^\s*$' && continue
        local KEY VAL
        KEY=$(echo "$line" | cut -d= -f1 | tr -d ' ')
        VAL=$(echo "$line" | cut -d= -f2- | sed 's/^ //')
        if ! sysctl -w "${KEY}=${VAL}" > /dev/null 2>&1; then
            warn "跳过不支持的参数：${KEY}"
            SKIPPED=$(( SKIPPED + 1 ))
        fi
    done < "$SYSCTL_FILE"

    if [ "$SKIPPED" -gt 0 ]; then
        warn "共跳过 ${SKIPPED} 个不支持的参数（已记录在配置文件，重启后不影响）"
    fi
    info "sysctl 配置已应用到 ${SYSCTL_FILE} ✓"
}

# ── 应用 tc 限速 ──────────────────────────────────────────
bbr_apply_tc() {
    local RATE="$1"
    local DEV; DEV=$(ip route | awk '/^default/{print $5}')
    [ -z "$DEV" ] && { error "无法确定默认出口网卡"; return 1; }

    # burst/cburst 随速率缩放（约 8ms 量级，≈ RATE KB），下限 32KB。
    # 固定 burst 会在高速率下令牌饥饿，导致跑不满设定速率。
    local BURST_KB=$RATE
    [ "$BURST_KB" -lt 32 ] && BURST_KB=32

    # 关键：用 htb 做「聚合」整形（真正硬上限），叶子挂 fq 保留 BBR pacing。
    # 旧版多队列网卡用 root tbf 会顶掉 fq、废掉 BBR pacing，且单纯 fq maxrate
    # 只能限「每流」不能限聚合。htb(整形) + fq(pacing) 才同时满足两者。
    tc qdisc del dev "$DEV" root 2>/dev/null
    if ! tc qdisc add dev "$DEV" root handle 1: htb default 10 2>/dev/null \
        || ! tc class add dev "$DEV" parent 1: classid 1:10 htb \
                rate "${RATE}mbit" ceil "${RATE}mbit" burst "${BURST_KB}kb" cburst "${BURST_KB}kb" 2>/dev/null \
        || ! tc qdisc add dev "$DEV" parent 1:10 handle 100: fq maxrate "${RATE}mbit" 2>/dev/null; then
        error "tc 规则应用失败（内核可能缺 sch_htb / sch_fq 模块）"
        tc qdisc del dev "$DEV" root 2>/dev/null
        return 1
    fi

    cat > "$SERVICE_TC" << EOF
[Unit]
Description=TC egress shaping ${RATE}Mbps (htb shape + fq pacing for BBR)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c '/sbin/tc qdisc del dev ${DEV} root 2>/dev/null; /sbin/tc qdisc add dev ${DEV} root handle 1: htb default 10 && /sbin/tc class add dev ${DEV} parent 1: classid 1:10 htb rate ${RATE}mbit ceil ${RATE}mbit burst ${BURST_KB}kb cburst ${BURST_KB}kb && /sbin/tc qdisc add dev ${DEV} parent 1:10 handle 100: fq maxrate ${RATE}mbit'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    svc_daemon_reload
    svc_enable tc-fq
    rc-service tc-fq restart 2>/dev/null || systemctl restart tc-fq 2>/dev/null || true
    info "tc 限速已应用：${RATE}Mbps（htb 聚合整形 + fq pacing，burst ${BURST_KB}KB）✓"
}

# ── 生成 sysctl 配置内容 ──────────────────────────────────
bbr_generate_config() {
    local RMEM=$1 WMEM=$2 TCP_MEM=$3 NOTSENT=$4 ADV_WIN=$5 \
          MIN_FREE=$6 SWAPPINESS=$7 TCP_RMEM_DEFAULT=$8 PROFILE_NAME="${9:-default}"
    cat << EOF
# BBR TCP 调优配置 — 生成时间：$(date)
# 预设：${PROFILE_NAME}
# ── 内存管理 ──
vm.swappiness = ${SWAPPINESS}
vm.min_free_kbytes = ${MIN_FREE}

# ── BBR 核心 ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── 缓冲区 ──
net.core.rmem_max = ${RMEM}
net.core.wmem_max = ${WMEM}
net.ipv4.tcp_rmem = 32768 ${TCP_RMEM_DEFAULT} ${RMEM}
net.ipv4.tcp_wmem = 32768 ${TCP_RMEM_DEFAULT} ${WMEM}
net.ipv4.tcp_mem = ${TCP_MEM}
net.ipv4.tcp_adv_win_scale = ${ADV_WIN}
net.ipv4.tcp_notsent_lowat = ${NOTSENT}

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
EOF

    # 中转机 / 落地机 / 线路落地机 共同需要的转发与 conntrack
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            cat << EOF

# ── 转发与并发（中转/落地必备）──
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_max_tw_buckets = 500000
fs.file-max = 1048576
EOF
            ;;
    esac

    # 中转机额外的 conntrack 调优（大并发场景必需）
    if [ "$PROFILE_NAME" = "relay" ]; then
        cat << EOF

# ── conntrack（中转大并发必备）──
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF
    fi
}

# ── 确认并应用参数 ────────────────────────────────────────
# ── 检测常见代理 service 的 LimitNOFILE，偏低则提示写 drop-in ──
# fs.file-max 只是系统总上限，单进程 fd 上限由 systemd 的 LimitNOFILE 决定。
bbr_check_limitnofile() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local SVCS="xray sing-box hysteria hysteria-server tuic v2ray trojan trojan-go mihomo clash"
    local svc found=0
    for svc in $SVCS; do
        systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service" || continue
        found=1
        local CUR
        CUR=$(systemctl show -p LimitNOFILE --value "${svc}.service" 2>/dev/null)
        if [ -n "$CUR" ] && [ "$CUR" -lt 1048576 ] 2>/dev/null; then
            echo ""
            warn "检测到代理服务 ${svc}.service 的 LimitNOFILE=${CUR} 偏低"
            echo -e "  ${DIM}fs.file-max 已抬高，但单进程 fd 上限受 systemd LimitNOFILE 限制${NC}"
            read -rp "  是否为 ${svc} 写入 LimitNOFILE=1048576 的 drop-in？(y/N，默认N): " DOLN
            [ -z "$DOLN" ] && DOLN="n"
            if echo "$DOLN" | grep -qiE '^y(es)?$'; then
                local DROPDIR="/etc/systemd/system/${svc}.service.d"
                mkdir -p "$DROPDIR" 2>/dev/null
                printf '[Service]\nLimitNOFILE=1048576\n' > "${DROPDIR}/99-nofile.conf"
                systemctl daemon-reload 2>/dev/null
                info "已写入 ${DROPDIR}/99-nofile.conf，重启 ${svc} 后生效：systemctl restart ${svc}"
            fi
        fi
    done
    [ "$found" -eq 0 ] && return 0
}

bbr_confirm_apply() {
    local RMEM=$1 WMEM=$2 TCP_MEM=$3 NOTSENT=$4 ADV_WIN=$5 \
          MIN_FREE=$6 SWAP=$7 TCP_RMEM_DEFAULT=$8 \
          LABEL_MODE=$9 LABEL_BUF=${10} PROFILE_NAME="${11:-default}"

    local BUF_MB=$(( RMEM / 1048576 ))
    echo ""
    echo -e "  ${YELLOW}── 配置摘要 ──────────────────────────────${NC}"
    echo -e "  模式         : ${BOLD}$LABEL_MODE${NC}"
    echo -e "  缓冲区       : ${BOLD}${LABEL_BUF}MB${NC}  (rmem/wmem max)"
    echo -e "  tcp_rmem default : ${BOLD}$(( TCP_RMEM_DEFAULT / 1048576 ))MB${NC}"
    echo -e "  min_free_kbytes  : ${BOLD}${MIN_FREE}${NC}"
    echo -e "  tcp_mem      : ${BOLD}${TCP_MEM}${NC}"
    echo -e "  adv_win_scale: ${BOLD}${ADV_WIN}${NC}"
    echo -e "  swappiness   : ${BOLD}${SWAP}${NC}"
    echo -e "  ${YELLOW}──────────────────────────────────────────${NC}"
    echo ""
    # 先检测 sysctl 写入权限
    if ! has_sysctl_write; then
        error "当前容器无 sysctl 写入权限，无法应用配置"
        echo -e "  ${DIM}需要宿主机开启 privileged 模式或 sysctl 白名单${NC}"
        return
    fi

    # 再检测内核是否支持 BBR
    if ! bbr_check_kernel; then
        echo ""
        read -rp "  内核不支持 BBR，仍要继续写入配置？(y/N，默认N): " FORCE
        [ -z "$FORCE" ] && FORCE="n"
        if ! echo "$FORCE" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    fi

    # 先提示备份（默认Y）
    if [ -f "$SYSCTL_FILE" ]; then
        read -rp "  备份当前 sysctl 配置？(Y/n，默认Y): " DO_BAK
        [ -z "$DO_BAK" ] && DO_BAK="y"
        echo "$DO_BAK" | grep -qiE '^y(es)?$' && bbr_backup_sysctl
        echo ""
    fi
    read -rp "  确认应用以上配置？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    local CONFIG
    CONFIG=$(bbr_generate_config "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT" "$PROFILE_NAME")
    [ "$PROFILE_NAME" = "relay" ] || [ "$PROFILE_NAME" = "landing" ] || [ "$PROFILE_NAME" = "line_landing" ] && ensure_conntrack_module
    bbr_apply_sysctl "$CONFIG"
    case "$PROFILE_NAME" in
        relay|landing|line_landing) bbr_check_limitnofile ;;
    esac
    echo ""
    info "BBR TCP 调优配置完成 ✓"
    warn "建议配合限速设置使用，避免 Retr 爆炸"
}

# ── 自动计算模式：根据 BDP 推导缓冲区 ───────────────────
bbr_auto_calc() {
    local MEM_MB=$1 LAT_MS=$2 BW_MBPS=$3 MEM_LBL=$4 LAT_LBL=$5 BW_LBL=$6

    # 合并为单表达式避免双重整数截断：
    # 旧写法 BW/8 再 ×LAT/1000 两次取整，低带宽×低延迟会被归零（显示 BDP 0MB）
    local BDP_MB=$(( BW_MBPS * LAT_MS / 8000 ))
    local BUF_CALC=$(( BDP_MB * 3 / 2 ))

    local RMEM WMEM ADV_WIN NOTSENT TCP_RMEM_DEFAULT
    if   [ "$BUF_CALC" -le 10 ];  then RMEM=12582912;   WMEM=12582912;   ADV_WIN=2; NOTSENT=131072;  TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 20 ];  then RMEM=20971520;   WMEM=20971520;   ADV_WIN=2; NOTSENT=131072;  TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 32 ];  then RMEM=33554432;   WMEM=33554432;   ADV_WIN=2; NOTSENT=262144;  TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 40 ];  then RMEM=41943040;   WMEM=41943040;   ADV_WIN=3; NOTSENT=262144;  TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 64 ];  then RMEM=67108864;   WMEM=67108864;   ADV_WIN=3; NOTSENT=524288;  TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 128 ]; then RMEM=134217728;  WMEM=134217728;  ADV_WIN=3; NOTSENT=524288;  TCP_RMEM_DEFAULT=2097152
    elif [ "$BUF_CALC" -le 256 ]; then RMEM=268435456;  WMEM=268435456;  ADV_WIN=3; NOTSENT=1048576; TCP_RMEM_DEFAULT=2097152
    elif [ "$BUF_CALC" -le 512 ]; then RMEM=536870912;  WMEM=536870912;  ADV_WIN=3; NOTSENT=2097152; TCP_RMEM_DEFAULT=4194304
    else                                RMEM=1073741824; WMEM=1073741824; ADV_WIN=3; NOTSENT=2097152; TCP_RMEM_DEFAULT=4194304
    fi

    # 限制：缓冲区不超过物理内存一半
    local HALF_MEM=$(( MEM_MB * 1048576 / 2 ))
    if [ "$RMEM" -gt "$HALF_MEM" ]; then
        warn "缓冲区 $(( RMEM / 1048576 ))MB 超过物理内存 ${MEM_MB}MB 的一半，自动降级"
        RMEM=$HALF_MEM
        WMEM=$HALF_MEM
    fi

    local MIN_FREE SWAP TCP_MEM
    if   [ "$MEM_MB" -le 768  ]; then MIN_FREE=32768;  SWAP=10; TCP_MEM="32768 49152 98304"
    elif [ "$MEM_MB" -le 1536 ]; then MIN_FREE=65536;  SWAP=10; TCP_MEM="49152 65536 131072"
    elif [ "$MEM_MB" -le 4096 ]; then MIN_FREE=65536;  SWAP=5;  TCP_MEM="131072 196608 393216"
    elif [ "$MEM_MB" -le 8192 ]; then MIN_FREE=131072; SWAP=5;  TCP_MEM="262144 393216 786432"
    else                               MIN_FREE=262144; SWAP=5;  TCP_MEM="524288 786432 1572864"
    fi

    local BUF_MB=$(( RMEM / 1048576 ))
    echo ""
    echo -e "  BDP 估算：${BOLD}${BDP_MB}MB${NC}  →  推荐缓冲区：${BOLD}${BUF_MB}MB${NC}"
    echo -e "  内存：${MEM_LBL}  延迟：${LAT_LBL}  带宽：${BW_LBL}"

    bbr_confirm_apply "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" \
        "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT" \
        "自动计算（${MEM_LBL} / ${LAT_LBL} / ${BW_LBL}）" "$BUF_MB"
}

# ── 手动选择缓冲区模式 ────────────────────────────────────
# ── 自动模式：带宽子菜单 ─────────────────────────────────
bbr_menu_bandwidth() {
    local MEM_MB=$1 LAT_MS=$2 MEM_LBL=$3 LAT_LBL=$4
    print_header "BBR 自动配置 — 选择带宽"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}  延迟：${BOLD}${LAT_LBL}${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 100 Mbps"
    echo -e "  ${GREEN}2${NC}) 200 Mbps"
    echo -e "  ${GREEN}3${NC}) 500 Mbps"
    echo -e "  ${GREEN}4${NC}) 1 Gbps   (1024 Mbps)"
    echo -e "  ${GREEN}5${NC}) 2 Gbps   (2048 Mbps)"
    echo -e "  ${GREEN}6${NC}) 5 Gbps   (5120 Mbps)"
    echo -e "  ${GREEN}7${NC}) 10 Gbps  (10240 Mbps)"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-7]: " CH
    case "$CH" in
        1) bbr_auto_calc "$MEM_MB" "$LAT_MS" 100   "$MEM_LBL" "$LAT_LBL" "100Mbps" ;;
        2) bbr_auto_calc "$MEM_MB" "$LAT_MS" 200   "$MEM_LBL" "$LAT_LBL" "200Mbps" ;;
        3) bbr_auto_calc "$MEM_MB" "$LAT_MS" 500   "$MEM_LBL" "$LAT_LBL" "500Mbps" ;;
        4) bbr_auto_calc "$MEM_MB" "$LAT_MS" 1024  "$MEM_LBL" "$LAT_LBL" "1Gbps" ;;
        5) bbr_auto_calc "$MEM_MB" "$LAT_MS" 2048  "$MEM_LBL" "$LAT_LBL" "2Gbps" ;;
        6) bbr_auto_calc "$MEM_MB" "$LAT_MS" 5120  "$MEM_LBL" "$LAT_LBL" "5Gbps" ;;
        7) bbr_auto_calc "$MEM_MB" "$LAT_MS" 10240 "$MEM_LBL" "$LAT_LBL" "10Gbps" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 自动模式：延迟子菜单 ─────────────────────────────────
bbr_menu_latency() {
    local MEM_MB=$1 MEM_LBL=$2
    print_header "BBR 自动配置 — 选择延迟"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 100ms 以内     （国内 / 亚洲近距离）"
    echo -e "  ${GREEN}2${NC}) 100ms - 200ms  （跨国，如美西→中国）"
    echo -e "  ${GREEN}3${NC}) 200ms 以上     （欧洲→中国 / 长距离）"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-3]: " CH
    case "$CH" in
        1) bbr_menu_bandwidth "$MEM_MB" 50  "$MEM_LBL" "100ms以内" ;;
        2) bbr_menu_bandwidth "$MEM_MB" 150 "$MEM_LBL" "100-200ms" ;;
        3) bbr_menu_bandwidth "$MEM_MB" 250 "$MEM_LBL" "200ms以上" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 自动模式：内存子菜单 ─────────────────────────────────
bbr_menu_auto() {
    # 自动检测系统内存并标注推荐档位
    local MEM_KB; MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    local SYS_MEM_MB=$(( ${MEM_KB:-0} / 1024 ))

    print_header "BBR 自动配置 — 选择内存"
    echo -e "  系统检测内存：${BOLD}${SYS_MEM_MB}MB${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 512 MB"
    echo -e "  ${GREEN}2${NC}) 1 GB"
    echo -e "  ${GREEN}3${NC}) 2 GB"
    echo -e "  ${GREEN}4${NC}) 4 GB"
    echo -e "  ${GREEN}5${NC}) 8 GB"
    echo -e "  ${GREEN}6${NC}) 16 GB+"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-6]: " CH
    case "$CH" in
        1) bbr_menu_latency 512   "512MB" ;;
        2) bbr_menu_latency 1024  "1GB" ;;
        3) bbr_menu_latency 2048  "2GB" ;;
        4) bbr_menu_latency 4096  "4GB" ;;
        5) bbr_menu_latency 8192  "8GB" ;;
        6) bbr_menu_latency 16384 "16GB+" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 手动模式：内存子菜单 ─────────────────────────────────
bbr_menu_manual() {
    # 自动检测系统内存
    local MEM_KB; MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local MEM_MB=$(( MEM_KB / 1024 ))

    # ── 第一层：选择用途 ──
    print_header "BBR 手动配置 — 选择用途"
    echo -e "  检测到系统内存：${BOLD}${MEM_MB}MB${NC}"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${BOLD}请选择 VPS 用途（决定转发/conntrack/窗口参数）${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 中转机      — 双向转发/大并发（如 sing-box 中转）"
    echo -e "  ${GREEN}2${NC}) 落地机      — 跨境上行/大缓冲（落地代理出口）"
    echo -e "  ${GREEN}3${NC}) 线路落地机  — CN2/IPLC/直连用户/低延迟优先"
    echo -e "  ${GREEN}4${NC}) 通用 / 单机 — 普通 VPS（网页/SSH/服务）"
    echo -e "  ${RED}0${NC}) 返回   ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-4]: " SCENE
    local PROFILE SCENE_LABEL
    case "$SCENE" in
        1) PROFILE="relay";        SCENE_LABEL="中转机" ;;
        2) PROFILE="landing";      SCENE_LABEL="落地机" ;;
        3) PROFILE="line_landing"; SCENE_LABEL="线路落地机" ;;
        4) PROFILE="default";      SCENE_LABEL="通用单机" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    # ── 第二层：根据场景给出推荐档位提示 + 缓冲区选择 ──
    local RECOMMEND
    case "$PROFILE" in
        relay)
            # 中转机：中等缓冲足够，并发为主
            if   [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 4 (32MB) 或 5 (40MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 6 (64MB) 或 7 (128MB)"
            elif [ "$MEM_MB" -le 4096 ]; then RECOMMEND="推荐 7 (128MB)"
            else                              RECOMMEND="推荐 8 (256MB)"
            fi ;;
        landing)
            # 落地机：大缓冲吃满带宽
            if   [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 6 (64MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 7 (128MB)"
            elif [ "$MEM_MB" -le 4096 ]; then RECOMMEND="推荐 8 (256MB)"
            elif [ "$MEM_MB" -le 8192 ]; then RECOMMEND="推荐 9 (512MB)"
            else                              RECOMMEND="推荐 9 (512MB) 或 10 (1024MB)"
            fi ;;
        line_landing)
            # 线路落地机：低延迟优先，缓冲不用大
            if   [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 3 (20MB) 或 4 (32MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 4 (32MB) 或 6 (64MB)"
            else                              RECOMMEND="推荐 6 (64MB) 或 7 (128MB)"
            fi ;;
        default)
            if   [ "$MEM_MB" -le 768 ];  then RECOMMEND="推荐 2 (16MB) 或 3 (20MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 4 (32MB) 或 6 (64MB)"
            else                              RECOMMEND="推荐 6 (64MB) 或 7 (128MB)"
            fi ;;
    esac

    print_header "BBR 手动配置 — ${SCENE_LABEL} · 选择缓冲区"
    echo -e "  场景：${BOLD}${SCENE_LABEL}${NC}    内存：${BOLD}${MEM_MB}MB${NC}"
    echo -e "  ${YELLOW}${RECOMMEND}${NC}"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${GREEN}1${NC}) 12 MB    — 低带宽 / 低延迟"
    echo -e "  ${GREEN}2${NC}) 16 MB    — 小内存保守"
    echo -e "  ${GREEN}3${NC}) 20 MB    — 中低带宽"
    echo -e "  ${GREEN}4${NC}) 32 MB    — 1G 跨境甜点区（~150ms BDP，推荐）"
    echo -e "  ${GREEN}5${NC}) 40 MB    — 中等带宽（1G）"
    echo -e "  ${GREEN}6${NC}) 64 MB    — 高带宽（1G+ 跨境）"
    echo -e "  ${GREEN}7${NC}) 128 MB   — 超高带宽（2G/高延迟）"
    echo -e "  ${GREEN}8${NC}) 256 MB   — 万兆 / 跨洋（5G/100ms）"
    echo -e "  ${GREEN}9${NC}) 512 MB   — 万兆 / 长距离（10G/100ms）"
    echo -e "  ${GREEN}10${NC}) 1024 MB — 极限（10G+/200ms+，需 8G+ 内存）"
    echo -e "  ${RED}0${NC}) 返回   ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-10]: " CH

    local RMEM WMEM BUF_LBL
    case "$CH" in
        1)  RMEM=12582912;   BUF_LBL=12   ;;
        2)  RMEM=16777216;   BUF_LBL=16   ;;
        3)  RMEM=20971520;   BUF_LBL=20   ;;
        4)  RMEM=33554432;   BUF_LBL=32   ;;
        5)  RMEM=41943040;   BUF_LBL=40   ;;
        6)  RMEM=67108864;   BUF_LBL=64   ;;
        7)  RMEM=134217728;  BUF_LBL=128  ;;
        8)  RMEM=268435456;  BUF_LBL=256  ;;
        9)  RMEM=536870912;  BUF_LBL=512  ;;
        10) RMEM=1073741824; BUF_LBL=1024 ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac
    WMEM=$RMEM

    # 缓冲区不超过物理内存一半
    local HALF_MEM=$(( MEM_MB * 1048576 / 2 ))
    if [ "$RMEM" -gt "$HALF_MEM" ]; then
        warn "缓冲区 ${BUF_LBL}MB 超过物理内存 ${MEM_MB}MB 的一半"
        read -rp "  是否继续？(y/N，默认N): " GO
        [ -z "$GO" ] && GO="n"
        echo "$GO" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    fi

    # ── 根据场景调整窗口/队列参数 ──
    local ADV_WIN NOTSENT TCP_RMEM_DEFAULT
    case "$PROFILE" in
        relay)
            # 中转机：窗口标准、NOTSENT 小（降低单连接延迟）
            ADV_WIN=2; NOTSENT=262144
            [ "$BUF_LBL" -le 64 ] && TCP_RMEM_DEFAULT=1048576 || TCP_RMEM_DEFAULT=2097152
            ;;
        landing)
            # 落地机：窗口激进、NOTSENT 大（高吞吐）
            ADV_WIN=3; NOTSENT=2097152
            [ "$BUF_LBL" -le 64 ] && TCP_RMEM_DEFAULT=1048576 \
            || { [ "$BUF_LBL" -le 256 ] && TCP_RMEM_DEFAULT=2097152 || TCP_RMEM_DEFAULT=4194304; }
            ;;
        line_landing)
            # 线路落地机：NOTSENT 极小（响应优先），adv_win=2 保证源站→落地高 BDP 接收
            ADV_WIN=2; NOTSENT=131072
            [ "$BUF_LBL" -le 64 ] && TCP_RMEM_DEFAULT=1048576 || TCP_RMEM_DEFAULT=2097152
            ;;
        default)
            # 通用：跟着缓冲区档位走
            if   [ "$BUF_LBL" -le 32 ];  then ADV_WIN=2; NOTSENT=262144;  TCP_RMEM_DEFAULT=1048576
            elif [ "$BUF_LBL" -le 64 ];  then ADV_WIN=3; NOTSENT=524288;  TCP_RMEM_DEFAULT=1048576
            elif [ "$BUF_LBL" -le 256 ]; then ADV_WIN=3; NOTSENT=1048576; TCP_RMEM_DEFAULT=2097152
            else                              ADV_WIN=3; NOTSENT=2097152; TCP_RMEM_DEFAULT=4194304
            fi ;;
    esac

    # ── 内存相关参数按物理内存匹配 ──
    local MIN_FREE SWAP TCP_MEM
    if   [ "$MEM_MB" -le 768  ]; then MIN_FREE=32768;  SWAP=10; TCP_MEM="32768 49152 98304"
    elif [ "$MEM_MB" -le 1536 ]; then MIN_FREE=65536;  SWAP=10; TCP_MEM="49152 65536 131072"
    elif [ "$MEM_MB" -le 4096 ]; then MIN_FREE=65536;  SWAP=5;  TCP_MEM="131072 196608 393216"
    elif [ "$MEM_MB" -le 8192 ]; then MIN_FREE=131072; SWAP=5;  TCP_MEM="262144 393216 786432"
    else                               MIN_FREE=262144; SWAP=5;  TCP_MEM="524288 786432 1572864"
    fi
    # 中转机额外抬高 swappiness（容忍多进程）
    [ "$PROFILE" = "relay" ] && SWAP=10

    bbr_confirm_apply "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" \
        "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT" \
        "${SCENE_LABEL}（内存 ${MEM_MB}MB）" "$BUF_LBL" "$PROFILE"
}

# ── tc 限速菜单 ───────────────────────────────────────────
bbr_menu_tc() {
    print_header "限速设置（tc）"

    if is_openvz; then
        echo ""
        warn "检测到当前运行于 ${BOLD}OpenVZ 容器${NC} 中"
        warn "OpenVZ 共享内核，tc 流量控制通常被宿主机限制，无法正常使用"
        echo ""
        echo -e "  ${DIM}如需限速，请联系 VPS 提供商在宿主机层面配置${NC}"
        echo ""
        read -rp "  按 Enter 返回..." _
        return
    fi

    local DEV; DEV=$(ip route | awk '/^default/{print $5}')
    local QTYPE; QTYPE=$(tc qdisc show dev "$DEV" 2>/dev/null | awk 'NR==1{print $2}')
    [ -z "$QTYPE" ] && QTYPE="未知"
    # 当前限速：优先取 htb class 的 rate，其次 fq maxrate
    local CUR; CUR=$(tc class show dev "$DEV" 2>/dev/null | grep -oE 'rate [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$CUR" ] && CUR=$(tc qdisc show dev "$DEV" 2>/dev/null | grep -oE 'maxrate [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$CUR" ] && CUR="未设置"

    echo -e "  网卡：${BOLD}${DEV}${NC}  当前 qdisc：${BOLD}${QTYPE}${NC}  当前限速：${BOLD}${CUR}${NC}"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${GREEN}1${NC}) 200 Mbps"
    echo -e "  ${GREEN}2${NC}) 500 Mbps"
    echo -e "  ${GREEN}3${NC}) 780 Mbps"
    echo -e "  ${GREEN}4${NC}) 1024 Mbps (1Gbps)"
    echo -e "  ${GREEN}5${NC}) 2048 Mbps (2Gbps)"
    echo -e "  ${GREEN}6${NC}) 自定义输入"
    echo -e "  ${YELLOW}7${NC}) 取消限速"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-7]: " CH

    local RATE=0
    case "$CH" in
        1) RATE=200 ;;
        2) RATE=500 ;;
        3) RATE=780 ;;
        4) RATE=1024 ;;
        5) RATE=2048 ;;
        6)
            read -rp "  请输入限速值（Mbps）: " RATE
            if ! echo "$RATE" | grep -qE '^[0-9]+$' || [ "$RATE" -lt 1 ]; then
                error "无效数值"; return
            fi
            ;;
        7) RATE=0 ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    if [ "$RATE" -eq 0 ]; then
        # 删除 root qdisc，内核会自动恢复默认（mq/fq_codel 等），无需手动重建 mq
        tc qdisc del dev "$DEV" root 2>/dev/null
        svc_disable tc-fq
        rm -f "$SERVICE_TC"
        svc_daemon_reload
        info "已取消限速 ✓"
    else
        bbr_apply_tc "$RATE"
    fi
}

# ── initcwnd 菜单 ─────────────────────────────────────────
# 检测是否在 LXC 容器内

# 检测 OpenVZ / LXC 等受限容器


bbr_menu_initcwnd() {
    print_header "initcwnd 设置"

    # ── LXC 检测 ───────────────────────────────────────────
    if is_lxc; then
        echo ""
        warn "检测到当前运行于 ${BOLD}LXC 容器${NC} 中"
        warn "LXC 容器没有独立网络命名空间权限，无法执行 ip route change"
        echo ""
        echo -e "  ${DIM}initcwnd 需要在宿主机或独立网络命名空间（如 KVM/独立VPS）中设置${NC}"
        echo -e "  ${DIM}如需设置，请在宿主机执行：${NC}"
        echo -e "  ${CYAN}  ip route change default initcwnd 50 initrwnd 50${NC}"
        echo ""
        return
    fi

    local DEV GW ONLINK
    DEV=$(ip route | awk '/^default/{print $5}')
    GW=$(ip route | awk '/^default/{print $3}')
    ONLINK=$(ip route | grep "^default" | grep -q "onlink" && echo "onlink" || echo "")
    local CUR; CUR=$(ip route show | grep "^default" | grep -oE 'initcwnd [0-9]+' | awk '{print $2}')
    CUR="${CUR:-10（默认）}"

    echo -e "  网卡：${BOLD}${DEV}${NC}  网关：${BOLD}${GW}${NC}  当前 initcwnd：${BOLD}${CUR}${NC}"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${GREEN}1${NC}) 10   — 默认保守"
    echo -e "  ${GREEN}2${NC}) 50   — 跨国高延迟推荐"
    echo -e "  ${GREEN}3${NC}) 100  — 激进（可能丢包）"
    echo -e "  ${GREEN}4${NC}) 自定义输入"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-4]: " CH

    local VAL
    case "$CH" in
        1) VAL=10 ;;
        2) VAL=50 ;;
        3) VAL=100 ;;
        4)
            read -rp "  请输入 initcwnd 值（1-1000）: " VAL
            if ! echo "$VAL" | grep -qE '^[0-9]+$' || [ "$VAL" -lt 1 ] || [ "$VAL" -gt 1000 ]; then
                error "无效数值"; return
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    ip route change default via "$GW" dev "$DEV" $ONLINK initcwnd "$VAL" initrwnd "$VAL" || {
        error "ip route change 失败"
        echo ""
        echo -e "  ${DIM}如果你在 LXC/OpenVZ 容器内，此操作会被宿主机拒绝，这是正常现象${NC}"
        return
    }

    local SERVICE_CWND="/etc/systemd/system/initcwnd.service"
    cat > "$SERVICE_CWND" << EOF
[Unit]
Description=Set TCP initcwnd
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'GW=\$(ip route | awk '"'"'/^default/{print \$3}'"'"'); DEV=\$(ip route | awk '"'"'/^default/{print \$5}'"'"'); ONLINK=\$(ip route | grep "^default" | grep -q "onlink" && echo "onlink" || echo ""); ip route change default via \$GW dev \$DEV \$ONLINK initcwnd ${VAL} initrwnd ${VAL}'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    svc_daemon_reload
    svc_enable initcwnd
    rc-service initcwnd restart 2>/dev/null || systemctl restart initcwnd 2>/dev/null || true
    info "initcwnd 已设置为 ${VAL}，重启后自动生效 ✓"
}

# ── BBR 主菜单 ────────────────────────────────────────────

# ── 一键 TCP 预设（三种场景）────────────────────────────
volcano_tcp_profile() {
    local PROFILE="${1:-balanced}"
    local RMEM WMEM TCP_MEM NOTSENT ADV_WIN MIN_FREE SWAP TCP_RMEM_DEFAULT LABEL BUF_MB
    case "$PROFILE" in
        balanced)
            # 根据实际内存动态调整 balanced 缓冲区，避免超过物理内存一半
            local _MEM_MB; _MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
            if [ "${_MEM_MB:-0}" -lt 512 ]; then
                RMEM=16777216; WMEM=16777216; BUF_MB=16
            elif [ "${_MEM_MB:-0}" -lt 1024 ]; then
                RMEM=33554432; WMEM=33554432; BUF_MB=32
            else
                RMEM=67108864; WMEM=67108864; BUF_MB=64
            fi
            WMEM=$RMEM; TCP_MEM="65536 131072 262144"
            NOTSENT=262144; ADV_WIN=2; MIN_FREE=65536; SWAP=10
            TCP_RMEM_DEFAULT=1048576
            LABEL="均衡跨境  — 网页/代理/日常综合（推荐）" ;;
        latency)
            RMEM=33554432; WMEM=33554432; TCP_MEM="49152 98304 196608"
            NOTSENT=131072; ADV_WIN=1; MIN_FREE=65536; SWAP=10
            TCP_RMEM_DEFAULT=524288; BUF_MB=32
            LABEL="低延迟交互 — SSH/游戏/远程桌面/小包优先" ;;
        throughput)
            # 根据内存动态选缓冲区，万兆机器自动用大缓冲
            local _MEM_MB; _MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
            if [ "${_MEM_MB:-0}" -lt 2048 ]; then
                RMEM=67108864;   BUF_MB=64;   TCP_MEM="131072 196608 393216"; MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 4096 ]; then
                RMEM=134217728;  BUF_MB=128;  TCP_MEM="131072 262144 524288"; MIN_FREE=131072
            elif [ "${_MEM_MB:-0}" -lt 8192 ]; then
                RMEM=268435456;  BUF_MB=256;  TCP_MEM="262144 393216 786432"; MIN_FREE=131072
            else
                RMEM=536870912;  BUF_MB=512;  TCP_MEM="524288 786432 1572864"; MIN_FREE=262144
            fi
            WMEM=$RMEM
            NOTSENT=2097152; ADV_WIN=3; SWAP=5
            TCP_RMEM_DEFAULT=4194304
            LABEL="高吞吐传输 — 大带宽/万兆/下载上传优先" ;;
        relay)
            ensure_conntrack_module
            # 中转机：两进两出，需要均衡缓冲+低延迟+大并发
            local _MEM_MB; _MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
            if [ "${_MEM_MB:-0}" -lt 1024 ]; then
                RMEM=33554432;  BUF_MB=32;   TCP_MEM="49152 98304 196608";  MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 2048 ]; then
                RMEM=67108864;  BUF_MB=64;   TCP_MEM="65536 131072 262144"; MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 4096 ]; then
                RMEM=134217728; BUF_MB=128;  TCP_MEM="131072 196608 393216"; MIN_FREE=131072
            else
                RMEM=268435456; BUF_MB=256;  TCP_MEM="262144 393216 786432"; MIN_FREE=131072
            fi
            WMEM=$RMEM
            NOTSENT=262144; ADV_WIN=2; SWAP=10
            TCP_RMEM_DEFAULT=1048576
            LABEL="中转机 — 双向流量/大并发/均衡延迟与吞吐" ;;
        landing)
            ensure_conntrack_module
            # 落地机：流量主要是单向上行，跨境延迟高，需要大缓冲吃满带宽
            local _MEM_MB; _MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
            if [ "${_MEM_MB:-0}" -lt 1024 ]; then
                RMEM=67108864;   BUF_MB=64;   TCP_MEM="65536 131072 262144";   MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 2048 ]; then
                RMEM=134217728;  BUF_MB=128;  TCP_MEM="131072 262144 524288";  MIN_FREE=131072
            elif [ "${_MEM_MB:-0}" -lt 4096 ]; then
                RMEM=268435456;  BUF_MB=256;  TCP_MEM="262144 393216 786432";  MIN_FREE=131072
            else
                RMEM=536870912;  BUF_MB=512;  TCP_MEM="524288 786432 1572864"; MIN_FREE=262144
            fi
            WMEM=$RMEM
            NOTSENT=2097152; ADV_WIN=3; SWAP=5
            TCP_RMEM_DEFAULT=4194304
            LABEL="落地机 — 跨境上行/大缓冲吃满带宽" ;;
        line_landing)
            ensure_conntrack_module
            # 线路落地机：直连用户/CN2/IPLC 线路，低延迟优先+中等吞吐
            local _MEM_MB; _MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') / 1024 ))
            if [ "${_MEM_MB:-0}" -lt 1024 ]; then
                RMEM=33554432;  BUF_MB=32;   TCP_MEM="49152 98304 196608";  MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 2048 ]; then
                RMEM=67108864;  BUF_MB=64;   TCP_MEM="65536 131072 262144"; MIN_FREE=65536
            elif [ "${_MEM_MB:-0}" -lt 4096 ]; then
                RMEM=134217728; BUF_MB=128;  TCP_MEM="131072 262144 524288"; MIN_FREE=131072
            else
                RMEM=268435456; BUF_MB=256;  TCP_MEM="262144 393216 786432"; MIN_FREE=131072
            fi
            WMEM=$RMEM
            NOTSENT=131072; ADV_WIN=2; SWAP=5
            TCP_RMEM_DEFAULT=1048576
            LABEL="线路落地机 — CN2/IPLC/直连用户/低延迟优先" ;;
        *) error "未知预设：$PROFILE"; return 1 ;;
    esac

    echo -e "  预设：${BOLD}${LABEL}${NC}"
    echo -e "  缓冲：${BOLD}${BUF_MB}MB${NC}  拥塞控制：${BOLD}BBR + fq${NC}"
    echo ""
    bbr_backup_sysctl
    local CONFIG
    CONFIG=$(bbr_generate_config "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT" "$PROFILE")
    bbr_apply_sysctl "$CONFIG"
    case "$PROFILE" in
        relay|landing|line_landing) bbr_check_limitnofile ;;
    esac
    info "TCP 预设「${PROFILE}」已应用 ✓"
}

# ── 智能 TCP 调优向导 ────────────────────────────────────
bbr_smart_wizard() {
    print_header "智能 TCP 调优向导"
    local MEM_KB MEM_MB KERNEL CUR_CC
    MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    MEM_MB=$(( ${MEM_KB:-0} / 1024 ))
    KERNEL=$(uname -r 2>/dev/null || echo "未知")
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")

    echo -e "  ${BOLD}当前环境${NC}"
    echo -e "  内存：${GREEN}${MEM_MB}MB${NC}  内核：${GREEN}${KERNEL}${NC}  拥塞控制：${GREEN}${CUR_CC}${NC}"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${BOLD}[通用预设]${NC}"
    echo -e "  ${GREEN}1${NC}) 均衡跨境    — 默认推荐，适合大多数 VPS"
    echo -e "  ${GREEN}2${NC}) 低延迟交互  — SSH/游戏/远程桌面"
    echo -e "  ${GREEN}3${NC}) 高吞吐传输  — 大带宽/下载上传优先"
    echo ""
    echo -e "  ${BOLD}[场景化预设]${NC}"
    echo -e "  ${GREEN}4${NC}) 中转机      — 双向转发/大并发（如 sing-box 中转）"
    echo -e "  ${GREEN}5${NC}) 落地机      — 跨境上行/大缓冲（落地代理出口）"
    echo -e "  ${GREEN}6${NC}) 线路落地机  — CN2/IPLC/直连用户/低延迟优先"
    echo ""
    echo -e "  ${GREEN}7${NC}) 自动推荐    — 根据当前内存智能选择"
    echo -e "  ${RED}0${NC}) 返回         ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-7]: " CH

    local PROFILE=""
    case "$CH" in
        1) PROFILE="balanced" ;;
        2) PROFILE="latency" ;;
        3) PROFILE="throughput" ;;
        4) PROFILE="relay" ;;
        5) PROFILE="landing" ;;
        6) PROFILE="line_landing" ;;
        7)
            if [ "$MEM_MB" -lt 768 ]; then
                PROFILE="latency"
                warn "小内存机器，推荐低延迟/轻量参数"
            elif [ "$MEM_MB" -lt 1536 ]; then
                PROFILE="balanced"
                info "1GB 左右机器，推荐均衡模式"
            else
                PROFILE="balanced"
                info "2GB+ 机器，推荐均衡；大流量场景可选高吞吐或场景化预设"
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    echo ""
    read -rp "  确认应用「${PROFILE}」？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    volcano_tcp_profile "$PROFILE"
}


# ── 检测是否有 sysctl 写入权限 ───────────────────────────

# ── 检测内核是否支持 BBR ─────────────────────────────────
bbr_check_kernel() {
    # 1. 检测内核版本 >= 4.9
    local KVER KMAJ KMIN
    KVER=$(uname -r 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+')
    KMAJ=$(echo "$KVER" | cut -d. -f1)
    KMIN=$(echo "$KVER" | cut -d. -f2)
    if [ "${KMAJ:-0}" -lt 4 ] || { [ "${KMAJ:-0}" -eq 4 ] && [ "${KMIN:-0}" -lt 9 ]; }; then
        error "内核版本 $(uname -r) 低于 4.9，不支持 BBR"
        echo -e "  ${DIM}Alpine: apk add linux-lts 或升级内核${NC}"
        return 1
    fi

    # 2. 检测 tcp_bbr 模块是否可用
    if lsmod 2>/dev/null | grep -q "tcp_bbr"; then
        return 0  # 已加载
    fi

    # 尝试加载模块
    if modprobe tcp_bbr 2>/dev/null; then
        info "tcp_bbr 模块已加载 ✓"
        return 0
    fi

    # Alpine 上尝试安装内核模块包
    if command -v apk &>/dev/null; then
        warn "tcp_bbr 模块未加载，尝试安装内核模块..."
        local KFULL; KFULL=$(uname -r)
        apk add --no-cache "linux-lts-dev" 2>/dev/null             || apk add --no-cache "linux-virt" 2>/dev/null || true
        modprobe tcp_bbr 2>/dev/null && { info "tcp_bbr 模块已加载 ✓"; return 0; }
    fi

    # 检查 sysctl 是否已设置 bbr（有些内核内置不需要模块）
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        return 0
    fi

    error "当前内核不支持 BBR（tcp_bbr 模块未找到）"
    echo -e "  ${DIM}Alpine 解决方案：${NC}"
    echo -e "  ${DIM}  apk add linux-lts && reboot${NC}"
    echo -e "  ${DIM}或检查：/proc/sys/net/ipv4/tcp_available_congestion_control${NC}"
    return 1
}

bbr_menu() {
    # 进入时检测一次 sysctl 写入权限
    local _BBR_NO_SYSCTL=0
    if ! has_sysctl_write; then
        _BBR_NO_SYSCTL=1
    fi
    while true; do
        print_header "BBR TCP 调优"
        bbr_print_status
        if [ "$_BBR_NO_SYSCTL" -eq 1 ]; then
            echo ""
            echo -e "  ${RED}${BOLD}⚠ 当前环境无 sysctl 写入权限${NC}"
            echo -e "  ${DIM}检测为无特权容器（unprivileged container）${NC}"
            echo -e "  ${DIM}sysctl 参数由宿主机控制，无法在容器内修改${NC}"
            echo -e "  ${DIM}请联系 VPS 提供商开启 sysctl 权限，或使用 KVM/独立VPS${NC}"
        fi
        echo ""
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${GREEN}1${NC}) 智能向导（推荐）"
        echo -e "  ${GREEN}2${NC}) 自动配置（内存/延迟/带宽）"
        echo -e "  ${GREEN}3${NC}) 手动选择缓冲区大小"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${GREEN}4${NC}) 限速设置（tc）   ${GREEN}5${NC}) initcwnd 设置"
        echo -e "  ${GREEN}6${NC}) 备份 TCP 配置    ${GREEN}7${NC}) 还原 TCP 配置"
        echo -e "  ${RED}0${NC}) 返回主菜单        ${RED}00${NC}) 退出脚本"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo ""
        read -rp "  请选择 [0-7]: " CH

        case "$CH" in
            1) bbr_smart_wizard ;;
            2) bbr_menu_auto ;;
            3) bbr_menu_manual ;;
            4) bbr_menu_tc ;;
            5) bbr_menu_initcwnd ;;
            6) bbr_backup_sysctl ;;
            7) bbr_restore_sysctl ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}



# ── 直接进入 BBR 菜单 ─────────────────────────────────────
bbr_menu
