#!/bin/bash
# ============================================================
# BBR TCP 调优 + 限速设置 一体化脚本
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SERVICE_TC="/etc/systemd/system/tc-fq.service"
SYSCTL_FILE="/etc/sysctl.d/99-tuning.conf"

# ============================================================
# 工具函数
# ============================================================

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}   BBR TCP 调优 + 限速设置脚本${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo ""
}

print_current_status() {
    DEV=$(ip route | awk '/^default/{print $5}')
    CURRENT_RATE=$(tc qdisc show dev "$DEV" 2>/dev/null | grep -oP 'maxrate \K\S+' || echo "未设置")
    CURRENT_BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    CURRENT_RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "未知")
    echo -e "${YELLOW}当前状态：${NC}"
    echo -e "  网卡：${DEV}"
    echo -e "  拥塞控制：${CURRENT_BBR}"
    echo -e "  rmem_max：${CURRENT_RMEM}"
    echo -e "  tc 限速：${CURRENT_RATE}"
    echo ""
}

apply_sysctl() {
    local config="$1"
    echo "$config" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1
    echo -e "${GREEN}✓ sysctl 配置已应用${NC}"
}

apply_tc() {
    local rate="$1"
    local DEV=$(ip route | awk '/^default/{print $5}')
    tc qdisc replace dev "$DEV" root fq maxrate "${rate}mbit"
    cat > "$SERVICE_TC" << EOF
[Unit]
Description=FQ rate limit
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${DEV} root fq maxrate ${rate}mbit
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tc-fq &>/dev/null
    systemctl restart tc-fq
    echo -e "${GREEN}✓ tc 限速已应用：${rate}Mbps${NC}"
}

# ============================================================
# BBR 配置生成函数
# ============================================================

# 参数：$1=内存(mb) $2=rmem_max $3=wmem_max $4=tcp_mem $5=tcp_notsent_lowat $6=adv_win_scale $7=min_free_kbytes $8=swappiness
generate_config() {
    local RMEM_MAX=$1
    local WMEM_MAX=$2
    local TCP_MEM=$3
    local NOTSENT=$4
    local ADV_WIN=$5
    local MIN_FREE=$6
    local SWAPPINESS=$7

    cat << EOF
# BBR TCP 调优配置
# 生成时间：$(date)
# ============================================================
# Kernel
# ============================================================
kernel.pid_max = 65535
kernel.panic = 1
kernel.sysrq = 176
kernel.core_pattern = core_%e
kernel.printk = 3 4 1 3
kernel.numa_balancing = 0
kernel.sched_autogroup_enabled = 0
# ============================================================
# VM
# ============================================================
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.panic_on_oom = 0
vm.overcommit_memory = 1
vm.min_free_kbytes = ${MIN_FREE}
# ============================================================
# Net core
# ============================================================
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 8192
net.core.optmem_max = 1048576
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
# ============================================================
# TCP 缓冲区
# ============================================================
net.ipv4.tcp_rmem = 32768 1048576 ${RMEM_MAX}
net.ipv4.tcp_wmem = 32768 1048576 ${WMEM_MAX}
net.ipv4.tcp_mem = ${TCP_MEM}
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = ${ADV_WIN}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = ${NOTSENT}
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_ecn = 2
# ============================================================
# TCP 连接管理
# ============================================================
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_stdurg = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
# ============================================================
# IPv4 路由 & 邻居
# ============================================================
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.route.gc_timeout = 100
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.neigh.default.gc_thresh3 = 4096
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh1 = 512
# ============================================================
# 安全加固
# ============================================================
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.ping_group_range = 0 2147483647
EOF
}

# ============================================================
# BBR 调优菜单
# ============================================================

menu_bbr_bandwidth() {
    local MEM_MB=$1
    local MEM_LABEL=$2

    while true; do
        echo ""
        echo -e "${BOLD}内存：${MEM_LABEL} — 请选择带宽配置${NC}"
        echo ""
        echo -e "  ${BOLD}1.${NC} 500 Mbps"
        echo -e "  ${BOLD}2.${NC} 1 Gbps  (1024 Mbps)"
        echo -e "  ${BOLD}3.${NC} 2 Gbps  (2048 Mbps)"
        echo -e "  ${BOLD}0.${NC} 返回上级"
        echo ""
        read -rp "请选择 [0-3]：" BW_CHOICE

        case $BW_CHOICE in
            1)
                # 500Mbps — BDP=6.25MB，缓冲20MB
                # 512MB: min_free=32768 swappiness=10 tcp_mem=16384/21845/32768
                # 1GB:   min_free=65536 swappiness=10 tcp_mem=49152/65536/98304
                # 2GB:   min_free=65536 swappiness=5  tcp_mem=49152/65536/131072
                local RMEM=20971520
                local WMEM=20971520
                local NOTSENT=131072
                local ADV_WIN=2
                if   [ "$MEM_MB" -eq 512 ];  then MIN_FREE=32768;  SWAP=10; TCP_MEM="16384 21845 32768"
                elif [ "$MEM_MB" -eq 1024 ]; then MIN_FREE=65536;  SWAP=10; TCP_MEM="49152 65536 98304"
                else                              MIN_FREE=65536;  SWAP=5;  TCP_MEM="49152 65536 131072"
                fi
                ;;
            2)
                # 1Gbps — BDP=12.5MB，缓冲40MB
                local RMEM=41943040
                local WMEM=41943040
                local NOTSENT=262144
                local ADV_WIN=3
                if   [ "$MEM_MB" -eq 512 ];  then MIN_FREE=32768;  SWAP=10; TCP_MEM="16384 21845 49152"
                elif [ "$MEM_MB" -eq 1024 ]; then MIN_FREE=65536;  SWAP=10; TCP_MEM="49152 65536 131072"
                else                              MIN_FREE=65536;  SWAP=5;  TCP_MEM="131072 196608 262144"
                fi
                ;;
            3)
                # 2Gbps — BDP=25MB，缓冲64MB
                local RMEM=67108864
                local WMEM=67108864
                local NOTSENT=524288
                local ADV_WIN=3
                if   [ "$MEM_MB" -eq 512 ];  then MIN_FREE=32768;  SWAP=10; TCP_MEM="16384 32768 65536"
                elif [ "$MEM_MB" -eq 1024 ]; then MIN_FREE=65536;  SWAP=10; TCP_MEM="49152 65536 131072"
                else                              MIN_FREE=65536;  SWAP=5;  TCP_MEM="131072 196608 393216"
                fi
                ;;
            0) return ;;
            *)
                echo -e "${RED}无效选项${NC}"
                continue
                ;;
        esac

        local CONFIG
        CONFIG=$(generate_config "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" "$MIN_FREE" "$SWAP")

        echo ""
        echo -e "${YELLOW}即将应用配置：${NC}"
        echo -e "  内存：${MEM_LABEL}"
        echo -e "  带宽：$([ "$BW_CHOICE" = "1" ] && echo "500Mbps" || [ "$BW_CHOICE" = "2" ] && echo "1Gbps" || echo "2Gbps")"
        echo -e "  rmem/wmem max：$((RMEM/1024/1024))MB"
        echo -e "  min_free_kbytes：${MIN_FREE}"
        echo -e "  tcp_mem：${TCP_MEM}"
        echo ""
        read -rp "确认应用？[y/N]：" CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            apply_sysctl "$CONFIG"
            echo ""
            echo -e "${GREEN}✓ BBR TCP 调优配置完成${NC}"
            echo -e "${YELLOW}提示：建议配合限速设置使用，避免 Retr 爆炸${NC}"
        else
            echo -e "${YELLOW}已取消${NC}"
        fi
        break
    done
}

menu_bbr() {
    while true; do
        echo ""
        echo -e "${BOLD}BBR TCP 调优 — 请选择内存容量${NC}"
        echo ""
        echo -e "  ${BOLD}1.${NC} 512 MB"
        echo -e "  ${BOLD}2.${NC} 1 GB"
        echo -e "  ${BOLD}3.${NC} 2 GB"
        echo -e "  ${BOLD}0.${NC} 返回主菜单"
        echo ""
        read -rp "请选择 [0-3]：" MEM_CHOICE

        case $MEM_CHOICE in
            1) menu_bbr_bandwidth 512  "512 MB"; break ;;
            2) menu_bbr_bandwidth 1024 "1 GB";   break ;;
            3) menu_bbr_bandwidth 2048 "2 GB";   break ;;
            0) return ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

# ============================================================
# 限速菜单
# ============================================================

menu_tc() {
    local DEV=$(ip route | awk '/^default/{print $5}')
    local CURRENT=$(tc qdisc show dev "$DEV" 2>/dev/null | grep -oP 'maxrate \K\S+' || echo "未设置")

    echo ""
    echo -e "${BOLD}限速设置${NC}"
    echo -e "网卡：${DEV}　当前限速：${CURRENT}"
    echo ""
    echo -e "  请输入限速值（单位 Mbps，输入 0 取消限速）"
    echo -e "  常用参考：500  780  1024=1Gbps  2048=2Gbps"
    echo ""
    read -rp "请输入数字：" NEW_VAL

    if ! [[ "$NEW_VAL" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：请输入纯数字${NC}"
        return
    fi

    if [ "$NEW_VAL" = "0" ]; then
        tc qdisc del dev "$DEV" root 2>/dev/null
        systemctl disable tc-fq &>/dev/null
        rm -f "$SERVICE_TC"
        systemctl daemon-reload
        echo -e "${GREEN}✓ 已取消限速，tc 规则已删除${NC}"
    else
        apply_tc "$NEW_VAL"
    fi

    echo ""
    echo -e "tc qdisc show dev ${DEV}:"
    tc qdisc show dev "$DEV"
}

# ============================================================
# 主菜单
# ============================================================

main() {
    print_header
    print_current_status

    while true; do
        echo -e "${BOLD}请选择操作：${NC}"
        echo ""
        echo -e "  ${BOLD}1.${NC} BBR TCP 调优"
        echo -e "  ${BOLD}2.${NC} 限速设置"
        echo -e "  ${BOLD}0.${NC} 退出"
        echo ""
        read -rp "请选择 [0-2]：" MAIN_CHOICE

        case $MAIN_CHOICE in
            1)
                menu_bbr
                echo ""
                print_current_status
                ;;
            2)
                menu_tc
                echo ""
                print_current_status
                ;;
            0)
                echo ""
                echo -e "${GREEN}已退出${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入${NC}"
                ;;
        esac
    done
}

# 检查 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行${NC}"
    echo "sudo bash $0"
    exit 1
fi

main
