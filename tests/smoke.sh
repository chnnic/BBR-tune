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
    bbr_bdp_mb bbr_buffer_target_mb bbr_recommend_profile bbr_tc_qdisc_safe_to_replace \
    bbr_tc_snapshot_foreign bbr_tc_force_confirm bbr_tc_topology_matches bbr_tc_managed_artifact \
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
    CONFIG=$(bbr_generate_config 12582912 12582912 '32768 49152 98304' 131072 2 32768 10 1048576 relay)
    grep -qx 'net.ipv6.conf.eth0.accept_ra = 2' <<< "$CONFIG" || { echo "IPv6 forwarding profile is missing accept_ra=2" >&2; exit 1; }
)

bbr_tc_qdisc_safe_to_replace fq || { echo "Safe default qdisc was rejected" >&2; exit 1; }
! bbr_tc_qdisc_safe_to_replace cake || { echo "Foreign CAKE qdisc would be overwritten" >&2; exit 1; }
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
    TC_TEST_LOG="$TMP/foreign-tc.log"
    export TC_TEST_LOG
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

    APPLY_RC=0
    bbr_tc_apply_runtime eth0 500 500 "$FAKE_TC" >/dev/null 2>&1 || APPLY_RC=$?
    [ "$APPLY_RC" -eq 2 ] || { echo "Foreign tbf did not require force confirmation" >&2; exit 1; }
    [ ! -s "$TC_TEST_LOG" ] || { echo "Foreign tbf was modified without confirmation" >&2; exit 1; }
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

echo "BBR-tune smoke test passed."
