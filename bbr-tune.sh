#!/bin/bash

# ============================================================
#  BBR TCP 调优工具 — 银趴火山帮
#  从 VPS 开荒脚本 V3.0.0 独立提取
#  用法：bash bbr-tcp.sh
# ============================================================

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

info()  { echo -e "  ${GREEN}✔${NC}  $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
error() { echo -e "  ${RED}✘${NC}  $1"; }

safe_clear() {
    if [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        clear 2>/dev/null || true
    fi
}

vis_len() {
    python3 -c "
import unicodedata, sys
s = sys.argv[1]
print(sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s))
" "$1" 2>/dev/null || echo "${#1}"
}

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

# 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} 请使用 root 权限运行：sudo bash $0"
    exit 1
fi

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

svc_enable() {
    local SVC="$1"
    if command -v systemctl &>/dev/null && pidof systemd &>/dev/null; then
        systemctl unmask "$SVC" 2>/dev/null || true
        systemctl enable "$SVC" --quiet 2>/dev/null || true
    elif command -v rc-update &>/dev/null; then
        rc-update add "$SVC" default 2>/dev/null
    fi
}

svc_disable() {
    local SVC="$1"
    if command -v systemctl &>/dev/null; then
        systemctl disable "$SVC" --quiet 2>/dev/null
    elif command -v rc-update &>/dev/null; then
        rc-update del "$SVC" 2>/dev/null
    fi
}

svc_daemon_reload() {
    command -v systemctl &>/dev/null && systemctl daemon-reload 2>/dev/null || true
}

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
    local CWND; CWND=$(ip route show | grep "^default" | grep -oE 'initcwnd [0-9]+' | awk '{print $2}' || echo "10")

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

    echo -e "  网卡 ${BOLD}$DEV${NC}  |  拥塞控制 ${BOLD}$BBR${NC}  |  限速 ${BOLD}$RATE${NC}  |  initcwnd ${BOLD}$CWND${NC}"
    echo -e "  rmem_max ${BOLD}${RMEM_MB}MB${NC}  |  wmem_max ${BOLD}${WMEM_MB}MB${NC}  |  tcp_rmem max ${BOLD}${TCP_RMEM_MB}MB${NC}  |  tcp_wmem max ${BOLD}${TCP_WMEM_MB}MB${NC}"
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
    print_header "还原 sysctl.conf"
    local BACKUPS=()
    local BACKUPS=()
    while IFS= read -r _bline; do BACKUPS+=("$_bline"); done < <(ls -t "${SYSCTL_FILE}.bak."* 2>/dev/null)
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        warn "未找到任何备份文件"
        return
    fi
    local i=1
    for f in "${BACKUPS[@]}"; do
        echo -e "  ${GREEN}[$i]${NC} $(basename "$f")  $(stat -c '%y' "$f" | cut -d'.' -f1)"
        (( i++ ))
    done
    echo -e "  ${YELLOW}[d]${NC} 清除全部备份"
    echo -e "  ${RED}[0]${NC} 返回"
    echo ""
    read -rp "  请选择: " CH
    case "$CH" in
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        d|D)
            read -rp "  确认清除全部 ${#BACKUPS[@]} 个备份？(Y/n，默认Y): " C
            [ "$C" = "yes" ] && rm -f "${SYSCTL_FILE}.bak."* && info "已清除全部备份" || warn "已取消"
            ;;
        *)
            if [[ "$CH" =~ ^[0-9]+$ ]] && [ "$CH" -ge 1 ] && [ "$CH" -le ${#BACKUPS[@]} ]; then
                local T="${BACKUPS[$((CH-1))]}"
                cp "$T" "$SYSCTL_FILE"
                sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1
                info "已还原：$(basename "$T") ✓"
            else
                error "无效选项"
            fi
            ;;
    esac
}

# ── 应用 sysctl ───────────────────────────────────────────
bbr_apply_sysctl() {
    local CONFIG="$1"
    mkdir -p "$(dirname "$SYSCTL_FILE")" 2>/dev/null || true
    echo "$CONFIG" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1
    info "sysctl 配置已应用到 ${SYSCTL_FILE} ✓"
}

# ── 应用 tc 限速 ──────────────────────────────────────────
bbr_apply_tc() {
    local RATE="$1"
    local DEV; DEV=$(ip route | awk '/^default/{print $5}')
    local TX_Q; TX_Q=$(ls /sys/class/net/"$DEV"/queues/ 2>/dev/null | grep "^tx-" | wc -l)
    local IS_MQ=0
    { tc qdisc show dev "$DEV" 2>/dev/null | grep -q "qdisc mq" || [ "$TX_Q" -gt 1 ]; } && IS_MQ=1

    if [ "$IS_MQ" -eq 1 ]; then
        tc qdisc replace dev "$DEV" root tbf rate "${RATE}mbit" burst 10mbit latency 50ms
        cat > "$SERVICE_TC" << EOF
[Unit]
Description=FQ rate limit
After=network.target
[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${DEV} root tbf rate ${RATE}mbit burst 10mbit latency 50ms
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    else
        tc qdisc replace dev "$DEV" root fq maxrate "${RATE}mbit"
        cat > "$SERVICE_TC" << EOF
[Unit]
Description=FQ rate limit
After=network.target
[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${DEV} root fq maxrate ${RATE}mbit
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    fi
    svc_daemon_reload
    svc_enable tc-fq
    rc-service tc-fq restart 2>/dev/null || systemctl restart tc-fq 2>/dev/null || true
    info "tc 限速已应用：${RATE}Mbps ✓"
}

# ── 生成 sysctl 配置内容 ──────────────────────────────────
bbr_generate_config() {
    local RMEM=$1 WMEM=$2 TCP_MEM=$3 NOTSENT=$4 ADV_WIN=$5 \
          MIN_FREE=$6 SWAPPINESS=$7 TCP_RMEM_DEFAULT=$8
    cat << EOF
# BBR TCP 调优配置 — 生成时间：$(date)
vm.swappiness = ${SWAPPINESS}
vm.dirty_background_ratio = 5
vm.min_free_kbytes = ${MIN_FREE}
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 8192
net.core.rmem_max = ${RMEM}
net.core.wmem_max = ${WMEM}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 32768 ${TCP_RMEM_DEFAULT} ${RMEM}
net.ipv4.tcp_wmem = 32768 ${TCP_RMEM_DEFAULT} ${WMEM}
net.ipv4.tcp_mem = ${TCP_MEM}
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_adv_win_scale = ${ADV_WIN}
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = ${NOTSENT}
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
EOF
}

# ── 确认并应用参数 ────────────────────────────────────────
bbr_confirm_apply() {
    local RMEM=$1 WMEM=$2 TCP_MEM=$3 NOTSENT=$4 ADV_WIN=$5 \
          MIN_FREE=$6 SWAP=$7 TCP_RMEM_DEFAULT=$8 \
          LABEL_MODE=$9 LABEL_BUF=${10}

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
    CONFIG=$(bbr_generate_config "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT")
    bbr_apply_sysctl "$CONFIG"
    echo ""
    info "BBR TCP 调优配置完成 ✓"
    warn "建议配合限速设置使用，避免 Retr 爆炸"
}

# ── 自动计算模式：根据 BDP 推导缓冲区 ───────────────────
bbr_auto_calc() {
    local MEM_MB=$1 LAT_MS=$2 BW_MBPS=$3 MEM_LBL=$4 LAT_LBL=$5 BW_LBL=$6

    local BW_MBS=$(( BW_MBPS / 8 ))
    local BDP_MB=$(( BW_MBS * LAT_MS / 1000 ))
    local BUF_CALC=$(( BDP_MB * 3 / 2 ))

    local RMEM WMEM ADV_WIN NOTSENT TCP_RMEM_DEFAULT
    if   [ "$BUF_CALC" -le 10 ];  then RMEM=12582912;  WMEM=12582912;  ADV_WIN=2; NOTSENT=131072; TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 20 ];  then RMEM=20971520;  WMEM=20971520;  ADV_WIN=2; NOTSENT=131072; TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 40 ];  then RMEM=41943040;  WMEM=41943040;  ADV_WIN=3; NOTSENT=262144; TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 64 ];  then RMEM=67108864;  WMEM=67108864;  ADV_WIN=3; NOTSENT=524288; TCP_RMEM_DEFAULT=1048576
    else                                RMEM=134217728; WMEM=134217728; ADV_WIN=3; NOTSENT=524288; TCP_RMEM_DEFAULT=1048576
    fi

    local MIN_FREE SWAP TCP_MEM
    if   [ "$MEM_MB" -eq 512  ]; then MIN_FREE=32768; SWAP=10; TCP_MEM="32768 49152 98304"
    elif [ "$MEM_MB" -eq 1024 ]; then MIN_FREE=65536; SWAP=10; TCP_MEM="49152 65536 131072"
    else                               MIN_FREE=65536; SWAP=5;  TCP_MEM="131072 196608 393216"
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
    echo -e "  ${GREEN}4${NC}) 1 Gbps  (1024 Mbps)"
    echo -e "  ${GREEN}5${NC}) 2 Gbps  (2048 Mbps)"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-5]: " CH
    case "$CH" in
        1) bbr_auto_calc "$MEM_MB" "$LAT_MS" 100  "$MEM_LBL" "$LAT_LBL" "100Mbps" ;;
        2) bbr_auto_calc "$MEM_MB" "$LAT_MS" 200  "$MEM_LBL" "$LAT_LBL" "200Mbps" ;;
        3) bbr_auto_calc "$MEM_MB" "$LAT_MS" 500  "$MEM_LBL" "$LAT_LBL" "500Mbps" ;;
        4) bbr_auto_calc "$MEM_MB" "$LAT_MS" 1024 "$MEM_LBL" "$LAT_LBL" "1Gbps" ;;
        5) bbr_auto_calc "$MEM_MB" "$LAT_MS" 2048 "$MEM_LBL" "$LAT_LBL" "2Gbps" ;;
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
    print_header "BBR 自动配置 — 选择内存"
    echo -e "  ${GREEN}1${NC}) 512 MB"
    echo -e "  ${GREEN}2${NC}) 1 GB"
    echo -e "  ${GREEN}3${NC}) 2 GB"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-3]: " CH
    case "$CH" in
        1) bbr_menu_latency 512  "512MB" ;;
        2) bbr_menu_latency 1024 "1GB" ;;
        3) bbr_menu_latency 2048 "2GB" ;;
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
    local MEM_LBL
    if   [ "$MEM_MB" -le 768  ]; then MEM_LBL="512MB"
    elif [ "$MEM_MB" -le 1536 ]; then MEM_LBL="1GB"
    else                               MEM_LBL="2GB+"
    fi

    print_header "BBR 手动缓冲区配置"
    echo -e "  检测到系统内存：${BOLD}${MEM_MB}MB${NC}（内存参数将自动匹配）"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${GREEN}1${NC}) 12 MB   — 低带宽 / 低延迟"
    echo -e "  ${GREEN}2${NC}) 16 MB   — 小内存保守"
    echo -e "  ${GREEN}3${NC}) 20 MB   — 中低带宽"
    echo -e "  ${GREEN}4${NC}) 40 MB   — 中等带宽"
    echo -e "  ${GREEN}5${NC}) 64 MB   — 高带宽推荐"
    echo -e "  ${GREEN}6${NC}) 128 MB  — 超高带宽 / 高延迟"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-6]: " CH

    local RMEM WMEM ADV_WIN NOTSENT TCP_RMEM_DEFAULT BUF_LBL
    case "$CH" in
        1) RMEM=12582912;  WMEM=12582912;  ADV_WIN=2; NOTSENT=131072; TCP_RMEM_DEFAULT=1048576; BUF_LBL=12 ;;
        2) RMEM=16777216;  WMEM=16777216;  ADV_WIN=2; NOTSENT=131072; TCP_RMEM_DEFAULT=1048576; BUF_LBL=16 ;;
        3) RMEM=20971520;  WMEM=20971520;  ADV_WIN=2; NOTSENT=131072; TCP_RMEM_DEFAULT=1048576; BUF_LBL=20 ;;
        4) RMEM=41943040;  WMEM=41943040;  ADV_WIN=3; NOTSENT=262144; TCP_RMEM_DEFAULT=1048576; BUF_LBL=40 ;;
        5) RMEM=67108864;  WMEM=67108864;  ADV_WIN=3; NOTSENT=524288; TCP_RMEM_DEFAULT=1048576; BUF_LBL=64 ;;
        6) RMEM=134217728; WMEM=134217728; ADV_WIN=3; NOTSENT=524288; TCP_RMEM_DEFAULT=1048576; BUF_LBL=128 ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    local MIN_FREE SWAP TCP_MEM
    if   [ "$MEM_MB" -le 768  ]; then MIN_FREE=32768; SWAP=10; TCP_MEM="32768 49152 98304"
    elif [ "$MEM_MB" -le 1536 ]; then MIN_FREE=65536; SWAP=10; TCP_MEM="49152 65536 131072"
    else                               MIN_FREE=65536; SWAP=5;  TCP_MEM="131072 196608 393216"
    fi

    bbr_confirm_apply "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN"         "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT"         "手动选择（内存 ${MEM_MB}MB）" "$BUF_LBL"
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
    local TX_Q; TX_Q=$(ls /sys/class/net/"$DEV"/queues/ 2>/dev/null | grep "^tx-" | wc -l)
    local IS_MQ=0
    { tc qdisc show dev "$DEV" 2>/dev/null | grep -q "qdisc mq" || [ "$TX_Q" -gt 1 ]; } && IS_MQ=1
    local CUR; CUR=$(tc qdisc show dev "$DEV" 2>/dev/null | grep -oE '(maxrate|rate) [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$CUR" ] && CUR="未设置"

    echo -e "  网卡：${BOLD}${DEV}${NC}  类型：${BOLD}$([ "$IS_MQ" -eq 1 ] && echo "mq多队列" || echo "单队列")${NC}  当前限速：${BOLD}${CUR}${NC}"
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
            if ! [[ "$RATE" =~ ^[0-9]+$ ]] || [ "$RATE" -lt 1 ]; then
                error "无效数值"; return
            fi
            ;;
        7) RATE=0 ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    if [ "$RATE" -eq 0 ]; then
        if [ "$IS_MQ" -eq 1 ]; then
            tc qdisc del dev "$DEV" root 2>/dev/null
            tc qdisc add dev "$DEV" root mq 2>/dev/null
        else
            tc qdisc del dev "$DEV" root 2>/dev/null
        fi
        svc_disable tc-fq
        rm -f "$SERVICE_TC"
        svc_daemon_reload
        info "已取消限速 ✓"
    else
        bbr_apply_tc "$RATE"
    fi
}

# ── initcwnd 菜单 ─────────────────────────────────────────

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
            if ! [[ "$VAL" =~ ^[0-9]+$ ]] || [ "$VAL" -lt 1 ] || [ "$VAL" -gt 1000 ]; then
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
            RMEM=67108864; WMEM=67108864; TCP_MEM="65536 131072 262144"
            NOTSENT=262144; ADV_WIN=2; MIN_FREE=65536; SWAP=10
            TCP_RMEM_DEFAULT=1048576; BUF_MB=64
            LABEL="均衡跨境  — 网页/代理/日常综合（推荐）" ;;
        latency)
            RMEM=33554432; WMEM=33554432; TCP_MEM="49152 98304 196608"
            NOTSENT=131072; ADV_WIN=1; MIN_FREE=65536; SWAP=10
            TCP_RMEM_DEFAULT=524288; BUF_MB=32
            LABEL="低延迟交互 — SSH/游戏/远程桌面/小包优先" ;;
        throughput)
            RMEM=134217728; WMEM=134217728; TCP_MEM="131072 262144 524288"
            NOTSENT=524288; ADV_WIN=3; MIN_FREE=131072; SWAP=5
            TCP_RMEM_DEFAULT=1048576; BUF_MB=128
            LABEL="高吞吐传输 — 大带宽/高延迟/下载上传优先" ;;
        *) error "未知预设：$PROFILE"; return 1 ;;
    esac

    echo -e "  预设：${BOLD}${LABEL}${NC}"
    echo -e "  缓冲：${BOLD}${BUF_MB}MB${NC}  拥塞控制：${BOLD}BBR + fq${NC}"
    echo ""
    bbr_backup_sysctl
    local CONFIG
    CONFIG=$(bbr_generate_config "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT")
    bbr_apply_sysctl "$CONFIG"
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
    echo -e "  ${GREEN}1${NC}) 均衡跨境   — 默认推荐，适合大多数 VPS"
    echo -e "  ${GREEN}2${NC}) 低延迟交互  — SSH/游戏/远程桌面"
    echo -e "  ${GREEN}3${NC}) 高吞吐传输  — 大带宽/下载上传优先"
    echo -e "  ${GREEN}4${NC}) 自动推荐   — 根据当前内存智能选择"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-4]: " CH

    local PROFILE=""
    case "$CH" in
        1) PROFILE="balanced" ;;
        2) PROFILE="latency" ;;
        3) PROFILE="throughput" ;;
        4)
            if [ "$MEM_MB" -lt 768 ]; then
                PROFILE="latency"
                warn "小内存机器，推荐低延迟/轻量参数"
            elif [ "$MEM_MB" -lt 1536 ]; then
                PROFILE="balanced"
                info "1GB 左右机器，推荐均衡模式"
            else
                PROFILE="balanced"
                info "2GB+ 机器，推荐均衡；大流量场景可选高吞吐"
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

bbr_menu() {
    while true; do
        print_header "BBR TCP 调优"
        bbr_print_status
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
