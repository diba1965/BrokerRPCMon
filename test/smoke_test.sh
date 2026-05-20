#!/bin/sh

BASE_DIR=`cd "\`dirname "$0"\`/.." 2>/dev/null && pwd`
PATH="$BASE_DIR/test/mock_commands:$PATH"
export PATH

fail()
{
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass()
{
    printf 'OK: %s\n' "$1"
}

assert_executable()
{
    [ -x "$1" ] || fail "$1 is not executable"
    pass "$1 is executable"
}

assert_success()
{
    "$@" >/tmp/brokerrpcmon_smoke.out 2>/tmp/brokerrpcmon_smoke.err
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        printf 'Command failed: %s\n' "$*" >&2
        cat /tmp/brokerrpcmon_smoke.out >&2
        cat /tmp/brokerrpcmon_smoke.err >&2
        exit 1
    fi
    pass "$*"
}

assert_failure()
{
    "$@" >/tmp/brokerrpcmon_smoke.out 2>/tmp/brokerrpcmon_smoke.err
    _rc=$?
    [ "$_rc" -ne 0 ] || fail "$* unexpectedly succeeded"
    pass "$* failed cleanly"
}

TMP_ROOT=${TMPDIR:-/tmp}/brokerrpcmon_smoke.$$
mkdir -p "$TMP_ROOT" || fail "cannot create temp directory"

HV_CONF="$TMP_ROOT/hv_broker.conf"
NL_CONF="$TMP_ROOT/nl_rpc.conf"
INV_CONF="$TMP_ROOT/nl_inventory.conf"
RUN_DIR="$TMP_ROOT/run"
LOG_DIR="$TMP_ROOT/log"
mkdir -p "$RUN_DIR" "$LOG_DIR" || fail "cannot create temp run/log dirs"

sed "s|NL_INVENTORY_FILE=.*|NL_INVENTORY_FILE=\"$INV_CONF\"|; s|LOG_DIR=.*|LOG_DIR=\"$LOG_DIR\"|; s|RUN_DIR=.*|RUN_DIR=\"$RUN_DIR\"|" "$BASE_DIR/conf/hv_broker.conf.example" > "$HV_CONF"
sed "s|BROKER_HOST=.*|BROKER_HOST=\"localhost\"|; s|LOG_DIR=.*|LOG_DIR=\"$LOG_DIR\"|; s|RUN_DIR=.*|RUN_DIR=\"$RUN_DIR\"|; s|MAINTENANCE_LOCK=.*|MAINTENANCE_LOCK=\"$RUN_DIR/maintenance.lock\"|" "$BASE_DIR/conf/nl_rpc.conf.example" > "$NL_CONF"
cp "$BASE_DIR/conf/nl_inventory.conf.example" "$INV_CONF" || fail "cannot copy inventory"

assert_executable "$BASE_DIR/bin/hv_broker_ctl.sh"
assert_executable "$BASE_DIR/bin/nl_rpc_ctl.sh"
assert_executable "$BASE_DIR/test/smoke_test.sh"
assert_executable "$BASE_DIR/test/mock_commands/etbinfo"
assert_executable "$BASE_DIR/test/mock_commands/etbcmd"
assert_executable "$BASE_DIR/test/mock_commands/natural"

assert_success "$BASE_DIR/bin/hv_broker_ctl.sh" help
assert_success "$BASE_DIR/bin/nl_rpc_ctl.sh" help

. "$BASE_DIR/lib/status_codes.sh" || fail "cannot source status_codes"
. "$BASE_DIR/lib/logging.sh" || fail "cannot source logging"
. "$BASE_DIR/lib/common.sh" || fail "cannot source common"
. "$BASE_DIR/lib/compat.sh" || fail "cannot source compat"
pass "libraries can be sourced"

load_config "$BASE_DIR/conf/hv_broker.conf.example" || fail "cannot load HV example"
load_config "$BASE_DIR/conf/nl_rpc.conf.example" || fail "cannot load NL example"
pass "example configurations can be loaded"

assert_success "$BASE_DIR/bin/hv_broker_ctl.sh" -c "$HV_CONF" config-check
assert_success "$BASE_DIR/bin/nl_rpc_ctl.sh" -c "$NL_CONF" config-check
assert_failure "$BASE_DIR/bin/nl_rpc_ctl.sh" -c "$TMP_ROOT/missing.conf" status

"$BASE_DIR/bin/nl_rpc_ctl.sh" -c "$NL_CONF" maintenance-on >/tmp/brokerrpcmon_smoke.out 2>/tmp/brokerrpcmon_smoke.err || fail "maintenance-on failed"
"$BASE_DIR/bin/nl_rpc_ctl.sh" -c "$NL_CONF" watchdog >/tmp/brokerrpcmon_smoke.out 2>/tmp/brokerrpcmon_smoke.err
_rc=$?
[ "$_rc" -eq "$STATUS_MAINTENANCE" ] || fail "watchdog did not return maintenance status"
grep 'action:.*none' /tmp/brokerrpcmon_smoke.out >/dev/null 2>&1 || fail "watchdog did not suppress actions in maintenance"
pass "maintenance prevents watchdog actions"

rm -f /tmp/brokerrpcmon_smoke.out /tmp/brokerrpcmon_smoke.err
rm -rf "$TMP_ROOT"
printf 'Smoke test completed successfully.\n'
