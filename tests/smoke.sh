#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export BBR_TUNE_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/bbr-tune.sh"

for fn in bbr_standalone_menu bbr_preflight bbr_runtime_snapshot bbr_ensure_baseline \
    bbr_restore_runtime_snapshot bbr_baseline_value bbr_apply_sysctl bbr_generate_config \
    bbr_physical_memory_mb bbr_effective_memory_mb bbr_buffer_cap_bytes bbr_conntrack_max_for_memory \
    bbr_bdp_mb bbr_buffer_target_mb bbr_recommend_profile bbr_tc_qdisc_safe_to_replace \
    bbr_tc_current_rate bbr_tc_rate_display bbr_tc_snapshot_foreign bbr_tc_force_confirm bbr_tc_remove_confirm \
    bbr_tc_topology_matches bbr_tc_managed_artifact \
    bbr_tc_is_legacy_owned bbr_tc_apply_runtime \
    bbr_route_token bbr_route_strip_cwnd bbr_apply_initcwnd_route; do
    declare -F "$fn" >/dev/null || { echo "Missing function: $fn" >&2; exit 1; }
done

MODULE="$TMP/bbr-module.sh"
awk '
    /^# BEGIN SYNCED BBR MODULE - DO NOT EDIT BY HAND$/ { inside=1; next }
    /^# END SYNCED BBR MODULE$/ { exit }
    inside { print }
' "$ROOT/bbr-tune.sh" > "$MODULE"
EXPECTED_HASH=$(awk -F= '$1 == "UPSTREAM_MODULE_SHA256" { print $2 }' "$ROOT/UPSTREAM.env")
ACTUAL_HASH=$(sha256sum "$MODULE" | awk '{print $1}')
[[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ]] || { echo "Embedded BBR module hash mismatch" >&2; exit 1; }

BBR_BASELINE_FILE="$TMP/baseline.conf"
cat > "$BBR_BASELINE_FILE" <<'EOF'
netXipv4Xip_forward = 9
net.ipv4.ip_forward = 1
EOF
[[ "$(bbr_baseline_value net.ipv4.ip_forward)" = 1 ]] || { echo "Baseline key matching is not exact" >&2; exit 1; }

(
    # shellcheck disable=SC2329 # invoked indirectly by bbr_generate_config
    bbr_default_ipv6_iface() { echo eth0; }
    bbr_physical_memory_mb() { echo 512; }
    CONFIG=$(bbr_generate_config 12582912 12582912 131072 10 relay 0)
    grep -qx 'net.ipv4.tcp_rmem = 4096 131072 12582912' <<< "$CONFIG" || { echo "Unsafe receive defaults were generated" >&2; exit 1; }
    grep -qx 'net.ipv4.tcp_wmem = 4096 16384 12582912' <<< "$CONFIG" || { echo "Unsafe send defaults were generated" >&2; exit 1; }
    ! grep -qE '^(vm\.min_free_kbytes|net\.ipv4\.(tcp_mem|tcp_adv_win_scale|tcp_tw_reuse|tcp_fin_timeout|tcp_keepalive_time))[[:space:]]*=' <<< "$CONFIG" \
        || { echo "Retired or risky TCP settings were generated" >&2; exit 1; }
    ! grep -qE '^net\.ipv4\.ip_forward[[:space:]]*=' <<< "$CONFIG" || { echo "Forwarding was enabled without consent" >&2; exit 1; }
    ! grep -qE '^net\.netfilter\.nf_conntrack_max[[:space:]]*=' <<< "$CONFIG" || { echo "Conntrack was tuned without forwarding" >&2; exit 1; }

    CONFIG=$(bbr_generate_config 12582912 12582912 131072 10 relay 1)
    grep -qx 'net.ipv6.conf.default.accept_ra = 2' <<< "$CONFIG" || { echo "IPv6 forwarding profile is missing default accept_ra=2" >&2; exit 1; }
    grep -qx 'net.ipv6.conf.eth0.accept_ra = 2' <<< "$CONFIG" || { echo "IPv6 forwarding profile is missing interface accept_ra=2" >&2; exit 1; }
    grep -qx 'net.netfilter.nf_conntrack_max = 131072' <<< "$CONFIG" || { echo "Conntrack was not scaled for 512MB" >&2; exit 1; }
)

[[ "$(bbr_effective_memory_mb 16384 512)" = 512 ]] || { echo "Selected memory was not clamped to physical RAM" >&2; exit 1; }
[[ "$(bbr_buffer_cap_bytes 512)" = 134217728 ]] || { echo "Buffer cap is not 25 percent of RAM" >&2; exit 1; }
! bbr_managed_keys | grep -qx 'vm.min_free_kbytes' || { echo "Retired settings could be captured as a new baseline" >&2; exit 1; }
[[ "$(bbr_conntrack_max_for_memory 512)" = 131072 ]] || { echo "512MB conntrack tier is wrong" >&2; exit 1; }
[[ "$(bbr_conntrack_max_for_memory 2048)" = 524288 ]] || { echo "2GB conntrack tier is wrong" >&2; exit 1; }

(
    bbr_physical_memory_mb() { echo 512; }
    bbr_confirm_apply() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4"; }
    AUTO_RESULT=$(bbr_auto_calc 16384 250 10240 16GB+ 200ms以上 10Gbps)
    AUTO_PARAMS=$(tail -n 1 <<< "$AUTO_RESULT")
    [[ "$AUTO_PARAMS" = '134217728 134217728 2097152 10' ]] \
        || { echo "512MB auto calculation trusted a 16GB selection: $AUTO_PARAMS" >&2; exit 1; }
)

bbr_tc_qdisc_safe_to_replace fq || { echo "Safe default qdisc was rejected" >&2; exit 1; }
! bbr_tc_qdisc_safe_to_replace cake || { echo "Foreign CAKE qdisc would be overwritten" >&2; exit 1; }
(
    TC_STATE_FILE="$TMP/mq-no-state"
    SERVICE_TC="$TMP/mq-tc.service"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact
    SERVICE_TC_INIT="$TMP/mq-tc.init"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact/bbr_tc_restore_owned
    TC_HELPER="$TMP/mq-tc-helper"
    TC_TEST_LOG="$TMP/mq-tc.log"
    export TC_TEST_LOG
    FAKE_TC="$TMP/fake-mq-tc"
    cat > "$FAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    printf '%s\n' 'qdisc mq 0: root' 'qdisc fq 0: parent :1 limit 10000p flow_limit 100p'
    exit 0
fi
if [ "$1 $2" = "class show" ]; then exit 0; fi
printf '%s\n' "$*" >> "$TC_TEST_LOG"
[ "$1 $2" != "qdisc del" ]
EOF
    chmod +x "$FAKE_TC"
    [ "$(bbr_tc_rate_display eth0 "$FAKE_TC")" = "未设置" ] \
        || { echo "Default mq/fq topology reported a rate" >&2; exit 1; }
    bbr_tc_apply_runtime eth0 2200 2200 "$FAKE_TC" >/dev/null \
        || { echo "Undeletable mq root could not be replaced" >&2; exit 1; }
    grep -qx 'qdisc replace dev eth0 root handle 1: htb default 10' "$TC_TEST_LOG" \
        || { echo "mq root was not replaced atomically" >&2; exit 1; }
    ! grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" \
        || { echo "mq root was incorrectly deleted" >&2; exit 1; }
)
(
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_is_owned
    TC_STATE_FILE="$TMP/legacy-tc-no-state"
    SERVICE_TC="$TMP/legacy-tc-fq.service"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact
    SERVICE_TC_INIT="$TMP/legacy-tc-fq.init"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact/bbr_tc_restore_owned
    TC_HELPER="$TMP/legacy-tc-helper"
    TC_TEST_LOG="$TMP/legacy-tc.log"
    export TC_TEST_LOG
    cat > "$SERVICE_TC" <<'EOF'
[Unit]
Description=TC egress shaping 1024Mbps (htb shape + fq pacing for BBR)
EOF
    FAKE_TC="$TMP/fake-legacy-tc"
    cat > "$FAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then
    cat <<'OUT'
qdisc htb 1: root refcnt 3 r2q 10 default 0x10 direct_packets_stat 0 direct_qlen 1000
qdisc fq 100: parent 1:10 limit 10000p flow_limit 100p buckets 1024 maxrate 1024Mbit
OUT
elif [ "$1 $2" = "class show" ]; then
    echo 'class htb 1:10 root rate 1024Mbit ceil 1024Mbit burst 1024Kb cburst 1024Kb'
else
    printf '%s\n' "$*" >> "$TC_TEST_LOG"
fi
EOF
    chmod +x "$FAKE_TC"
    bbr_tc_is_legacy_owned eth0 "$FAKE_TC" || { echo "Legacy tc topology was not recognized" >&2; exit 1; }
    bbr_tc_apply_runtime eth0 780 780 "$FAKE_TC" >/dev/null || { echo "Legacy tc topology could not be migrated" >&2; exit 1; }
    grep -qx 'qdisc add dev eth0 parent 1:10 handle 100: fq maxrate 780mbit' "$TC_TEST_LOG" \
        || { echo "Legacy tc migration did not apply the requested rate" >&2; exit 1; }
    rm -f "$SERVICE_TC"
    ! bbr_tc_is_legacy_owned eth0 "$FAKE_TC" || { echo "Legacy tc topology was claimed without a managed artifact" >&2; exit 1; }
    cat > "$SERVICE_TC" <<'EOF'
[Unit]
Description=TC egress shaping 1024Mbps (htb shape + fq pacing for BBR)
EOF
    TC_BIN_DIR="$TMP/legacy-tc-bin"
    mkdir -p "$TC_BIN_DIR"
    cp "$FAKE_TC" "$TC_BIN_DIR/tc"
    PATH="$TC_BIN_DIR:$PATH"
    # shellcheck disable=SC2329 # test stubs consumed indirectly by bbr_remove_tc
    default_iface() { echo eth0; }
    # shellcheck disable=SC2329 # keep the removal test away from the host service manager
    systemd_available() { return 1; }
    # shellcheck disable=SC2329 # test stubs consumed through command -v
    rc-update() { return 0; }
    # shellcheck disable=SC2329 # test stub consumed indirectly by bbr_remove_tc
    rc-service() { return 0; }
    : > "$TC_TEST_LOG"
    bbr_remove_tc >/dev/null || { echo "Legacy tc topology could not be removed" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" || { echo "Legacy tc removal left the root qdisc active" >&2; exit 1; }
)
(
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_is_owned
    TC_STATE_FILE="$TMP/no-tc-state"
    TC_BACKUP_DIR="$TMP/tc-backups"
    SERVICE_TC="$TMP/foreign-tc.service"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact/bbr_remove_tc
    SERVICE_TC_INIT="$TMP/foreign-tc.init"
    # shellcheck disable=SC2034 # consumed indirectly by bbr_tc_managed_artifact/bbr_remove_tc
    TC_HELPER="$TMP/foreign-tc-helper"
    TC_TEST_LOG="$TMP/foreign-tc.log"
    export TC_TEST_LOG
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_remove_tc
    systemd_available() { return 1; }
    # shellcheck disable=SC2329 # test stubs consumed through command -v by bbr_remove_tc
    rc-update() { return 0; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_remove_tc
    rc-service() { return 0; }
    # shellcheck disable=SC2329 # test stub used indirectly by bbr_remove_tc
    default_iface() { echo eth0; }
    FAKE_TC="$TMP/fake-foreign-tc"
    cat > "$FAKE_TC" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then echo 'qdisc tbf 8001: root rate 1024Mbit burst 1Mb lat 50ms'; exit 0; fi
if [ "$1 $2" = "class show" ]; then echo 'class tbf 8001:1 root'; exit 0; fi
if [ "$1 $2" = "filter show" ]; then echo 'filter parent 8001: protocol ip pref 1 u32'; exit 0; fi
if [ "$1 $2 $3" = "-j qdisc show" ]; then echo '[{"kind":"tbf","root":true}]'; exit 0; fi
if [ "$1 $2 $3" = "-j class show" ]; then echo '[{"kind":"tbf","classid":"8001:1"}]'; exit 0; fi
if [ "$1 $2 $3" = "-j filter show" ]; then echo '[{"kind":"u32","parent":"8001:"}]'; exit 0; fi
printf '%s\n' "$*" >> "$TC_TEST_LOG"
EOF
    chmod +x "$FAKE_TC"
    TC_BIN_DIR="$TMP/foreign-tc-bin"
    mkdir -p "$TC_BIN_DIR"
    cp "$FAKE_TC" "$TC_BIN_DIR/tc"
    PATH="$TC_BIN_DIR:$PATH"

    [ "$(bbr_tc_rate_display eth0 "$FAKE_TC")" = "1024Mbit（外部 tbf）" ] \
        || { echo "Foreign tbf rate was not labelled" >&2; exit 1; }
    APPLY_RC=0
    bbr_tc_apply_runtime eth0 500 500 "$FAKE_TC" >/dev/null 2>&1 || APPLY_RC=$?
    [ "$APPLY_RC" -eq 2 ] || { echo "Foreign tbf did not require force confirmation" >&2; exit 1; }
    [ ! -s "$TC_TEST_LOG" ] || { echo "Foreign tbf was modified without confirmation" >&2; exit 1; }
    REMOVE_RC=0
    bbr_remove_tc >/dev/null 2>&1 || REMOVE_RC=$?
    [ "$REMOVE_RC" -eq 2 ] || { echo "Cancel did not identify the foreign tbf" >&2; exit 1; }
    [ ! -s "$TC_TEST_LOG" ] || { echo "Cancel deleted foreign tbf without confirmation" >&2; exit 1; }
    if bbr_tc_remove_confirm eth0 "$FAKE_TC" >/dev/null 2>&1 <<'EOF'
DELETE eth1
EOF
    then
        echo "Incorrect deletion confirmation was accepted" >&2
        exit 1
    fi
    bbr_tc_remove_confirm eth0 "$FAKE_TC" >/dev/null <<'EOF'
DELETE eth0
EOF
    bbr_remove_tc 1 >/dev/null || { echo "Confirmed foreign tbf deletion failed" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" \
        || { echo "Confirmed foreign tbf was not deleted" >&2; exit 1; }
    : > "$TC_TEST_LOG"
    rm -rf "$TC_BACKUP_DIR"
    if bbr_tc_force_confirm eth0 500 "$FAKE_TC" >/dev/null 2>&1 <<'EOF'
FORCE eth1
EOF
    then
        echo "Incorrect tc force confirmation was accepted" >&2
        exit 1
    fi
    bbr_tc_force_confirm eth0 500 "$FAKE_TC" >/dev/null <<'EOF'
FORCE eth0
EOF
    bbr_tc_apply_runtime eth0 500 500 "$FAKE_TC" 1 >/dev/null \
        || { echo "Authorized foreign tbf takeover failed" >&2; exit 1; }
    grep -qx 'qdisc del dev eth0 root' "$TC_TEST_LOG" \
        || { echo "Authorized takeover did not delete foreign tbf" >&2; exit 1; }
    grep -qx 'qdisc add dev eth0 root handle 1: htb default 10' "$TC_TEST_LOG" \
        || { echo "Authorized takeover did not install htb" >&2; exit 1; }
    SNAPSHOT=$(find "$TC_BACKUP_DIR" -type f -name 'eth0_*.txt' -print -quit)
    [ -n "$SNAPSHOT" ] && grep -qF 'qdisc tbf 8001: root' "$SNAPSHOT" \
        && grep -qF 'class tbf 8001:1 root' "$SNAPSHOT" \
        && grep -qF 'filter parent 8001:' "$SNAPSHOT" \
        && grep -qF '"kind":"tbf"' "$SNAPSHOT" \
        || { echo "Foreign tc snapshot is incomplete" >&2; exit 1; }
)
[[ "$(bbr_route_token 'default dev eth0 proto static metric 100' dev)" = eth0 ]] || { echo "Direct route device parsing failed" >&2; exit 1; }
[[ -z "$(bbr_route_token 'default dev eth0 proto static metric 100' via)" ]] || { echo "Direct route invented a gateway" >&2; exit 1; }
[[ "$(bbr_route_strip_cwnd 'default via 192.0.2.1 dev eth0 initcwnd 50 initrwnd 50')" = 'default via 192.0.2.1 dev eth0' ]] || { echo "Route cwnd cleanup failed" >&2; exit 1; }
[[ "$(bbr_bdp_mb 100 50)" != 0.00 ]] || { echo "BDP estimate was truncated to zero" >&2; exit 1; }
[[ "$(bbr_buffer_target_mb 100 50)" = 1 ]] || { echo "BDP buffer rounding failed" >&2; exit 1; }
[[ "$(bbr_recommend_profile 4095)" = balanced ]] || { echo "Sub-4GB recommendation changed" >&2; exit 1; }
[[ "$(bbr_recommend_profile 4096)" = throughput ]] || { echo "4GB recommendation is not throughput" >&2; exit 1; }

TC_HELPER="$TMP/tc-helper.sh"
CWND_HELPER="$TMP/cwnd-helper.sh"
awk 'p && /^TC_HELPER_EOF$/{exit} /<< '\''TC_HELPER_EOF'\''/{p=1; next} p{print}' "$MODULE" > "$TC_HELPER"
awk 'p && /^CWND_HELPER_EOF$/{exit} /<< '\''CWND_HELPER_EOF'\''/{p=1; next} p{print}' "$MODULE" > "$CWND_HELPER"
sh -n "$TC_HELPER"
sh -n "$CWND_HELPER"

(
    HELPER_STATE="$TMP/tc-helper-mq.state"
    HELPER_RUN="$TMP/tc-helper-mq.sh"
    HELPER_BIN="$TMP/tc-helper-bin"
    HELPER_LOG="$TMP/tc-helper-mq.log"
    export HELPER_LOG
    sed "s|^STATE=.*|STATE=$HELPER_STATE|" "$TC_HELPER" > "$HELPER_RUN"
    chmod +x "$HELPER_RUN"
    printf 'DEV=eth0\nRATE=2200\nBURST_KB=2200\nFORCE=0\n' > "$HELPER_STATE"
    mkdir -p "$HELPER_BIN"
    cat > "$HELPER_BIN/tc" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "qdisc show" ]; then echo 'qdisc mq 0: root'; exit 0; fi
if [ "$1 $2" = "class show" ]; then exit 0; fi
printf '%s\n' "$*" >> "$HELPER_LOG"
[ "$1 $2" != "qdisc del" ]
EOF
    chmod +x "$HELPER_BIN/tc"
    PATH="$HELPER_BIN:$PATH" "$HELPER_RUN" apply \
        || { echo "Generated helper could not replace mq after reboot" >&2; exit 1; }
    grep -qx 'qdisc replace dev eth0 root handle 1: htb default 10' "$HELPER_LOG" \
        || { echo "Generated helper did not replace mq after reboot" >&2; exit 1; }
)

echo "BBR-tune smoke test passed."
