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
