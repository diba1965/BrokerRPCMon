#!/bin/sh

SCRIPT_DIR=`dirname "$0"`
BASE_DIR=`cd "$SCRIPT_DIR/.." 2>/dev/null && pwd`
COMPONENT=nl_rpc

. "$BASE_DIR/lib/status_codes.sh"
. "$BASE_DIR/lib/logging.sh"
. "$BASE_DIR/lib/common.sh"
. "$BASE_DIR/lib/compat.sh"

CONFIG_FILE=${BROKERRPCMON_NL_CONFIG:-"$BASE_DIR/conf/nl_rpc.conf"}

usage()
{
    cat <<EOF
Usage: nl_rpc_ctl.sh [-c config-file] command

Commands:
  status           Check local process, broker reachability, registration and RPC ping
  start            Start local Natural RPC server
  stop             Stop local Natural RPC server
  restart          Restart local Natural RPC server
  watchdog         Run one watchdog decision cycle
  sync             Placeholder for configuration/state synchronization
  test             Run local connectivity and placeholder RPC tests
  config-check     Validate configuration
  maintenance-on   Enable maintenance mode
  maintenance-off  Disable maintenance mode
  help             Show this help
EOF
}

parse_args()
{
    while [ $# -gt 0 ]; do
        case "$1" in
            -c)
                shift
                CONFIG_FILE=$1
                ;;
            --config=*)
                CONFIG_FILE=`printf '%s\n' "$1" | sed 's/^--config=//'`
                ;;
            help|-h|--help)
                COMMAND=help
                ;;
            *)
                COMMAND=$1
                ;;
        esac
        shift
    done
    if [ -z "$COMMAND" ]; then
        COMMAND=help
    fi
}

config_check()
{
    load_config "$CONFIG_FILE"
    _ok=Y
    for _name in NL_ID BROKER_NAME BROKER_HOST BROKER_PORT RPC_SERVER_NAME RPC_SERVER_CLASS RPC_SERVICE LOG_DIR RUN_DIR MAINTENANCE_LOCK; do
        eval "_value=\${$_name}"
        if [ -z "$_value" ]; then
            log_error "missing configuration value: $_name"
            _ok=N
        fi
    done
    is_number "$BROKER_PORT" || { log_error "BROKER_PORT is not numeric"; _ok=N; }
    is_number "$WATCHDOG_INTERVAL" || { log_error "WATCHDOG_INTERVAL is not numeric"; _ok=N; }
    is_number "$RESTART_LIMIT_COUNT" || { log_error "RESTART_LIMIT_COUNT is not numeric"; _ok=N; }
    is_number "$RESTART_LIMIT_WINDOW" || { log_error "RESTART_LIMIT_WINDOW is not numeric"; _ok=N; }
    is_number "$BROKER_CHECK_TIMEOUT" || { log_error "BROKER_CHECK_TIMEOUT is not numeric"; _ok=N; }
    is_number "$REGISTRATION_TIMEOUT" || { log_error "REGISTRATION_TIMEOUT is not numeric"; _ok=N; }
    if [ "$_ok" = Y ]; then
        print_kv "config" "OK"
        return "$STATUS_OK"
    fi
    return "$STATUS_CONFIG_ERROR"
}

ensure_run_dir()
{
    if [ ! -d "$RUN_DIR" ]; then
        mkdir -p "$RUN_DIR" 2>/dev/null || return 1
    fi
    return 0
}

maintenance_active()
{
    [ -f "$MAINTENANCE_LOCK" ]
}

local_process_running()
{
    if [ -n "$NATURAL_BIN" ]; then
        find_process "$NATURAL_BIN"
        return $?
    fi
    find_process "$RPC_SERVER_NAME"
}

broker_reachable()
{
    check_tcp_port "$BROKER_HOST" "$BROKER_PORT" "$BROKER_CHECK_TIMEOUT"
}

resolve_etbinfo()
{
    command -v etbinfo 2>/dev/null
}

registration_present()
{
    _etbinfo=`resolve_etbinfo`
    if [ -z "$_etbinfo" ]; then
        return "$STATUS_UNKNOWN"
    fi
    "$_etbinfo" "$BROKER_NAME" 2>/dev/null | grep "|$RPC_SERVER_CLASS|$RPC_SERVER_NAME|$RPC_SERVICE|" >/dev/null 2>&1
}

rpc_ping()
{
    _natural=$NATURAL_BIN
    if [ -z "$_natural" ]; then
        _natural=`command -v natural 2>/dev/null`
    fi
    if [ -z "$_natural" ]; then
        return "$STATUS_UNKNOWN"
    fi
    "$_natural" --brokerrpcmon-ping "$RPC_SERVER_CLASS" "$RPC_SERVER_NAME" "$RPC_SERVICE" >/dev/null 2>&1
}

do_start()
{
    load_config "$CONFIG_FILE"
    [ -n "$RPC_START_CMD" ] || die "RPC_START_CMD is not configured" "$STATUS_CONFIG_ERROR"
    log_info "starting local RPC server $RPC_SERVER_NAME"
    sh -c "$RPC_START_CMD"
}

do_stop()
{
    load_config "$CONFIG_FILE"
    [ -n "$RPC_STOP_CMD" ] || die "RPC_STOP_CMD is not configured" "$STATUS_CONFIG_ERROR"
    log_info "stopping local RPC server $RPC_SERVER_NAME"
    sh -c "$RPC_STOP_CMD"
}

do_restart()
{
    load_config "$CONFIG_FILE"
    do_stop
    _stop_rc=$?
    if [ "$_stop_rc" -ne 0 ]; then
        return "$_stop_rc"
    fi
    do_start
}

current_epoch()
{
    _now=`date '+%s' 2>/dev/null`
    if is_number "$_now"; then
        printf '%s\n' "$_now"
        return 0
    fi
    return 1
}

restart_state_file()
{
    printf '%s/restart.state\n' "$RUN_DIR"
}

restart_allowed()
{
    ensure_run_dir || return 1
    _state=`restart_state_file`
    _now=`current_epoch`
    if [ -z "$_now" ]; then
        _count=`wc -l < "$_state" 2>/dev/null`
        [ -z "$_count" ] && _count=0
        [ "$_count" -lt "$RESTART_LIMIT_COUNT" ]
        return $?
    fi
    _min=`expr "$_now" - "$RESTART_LIMIT_WINDOW"`
    _tmp="$RUN_DIR/restart.state.$$"
    if [ -f "$_state" ]; then
        awk -v min="$_min" '$1 >= min { print $1 }' "$_state" > "$_tmp" 2>/dev/null
        mv "$_tmp" "$_state" 2>/dev/null
    fi
    _count=`wc -l < "$_state" 2>/dev/null`
    [ -z "$_count" ] && _count=0
    [ "$_count" -lt "$RESTART_LIMIT_COUNT" ]
}

record_restart()
{
    ensure_run_dir || return 1
    _state=`restart_state_file`
    _now=`current_epoch`
    [ -z "$_now" ] && _now=unknown
    printf '%s\n' "$_now" >> "$_state"
}

restart_with_limit()
{
    if ! restart_allowed; then
        log_warn "restart limit reached for $RPC_SERVER_NAME"
        return "$STATUS_CRITICAL"
    fi
    record_restart
    do_restart
}

wait_for_registration()
{
    _elapsed=0
    while [ "$_elapsed" -lt "$REGISTRATION_TIMEOUT" ]; do
        registration_present
        _rc=$?
        if [ "$_rc" -eq 0 ]; then
            return 0
        fi
        sleep_seconds 1
        _elapsed=`expr "$_elapsed" + 1`
    done
    return "$STATUS_NOT_REGISTERED"
}

do_status()
{
    config_check || return $?
    if maintenance_active; then
        print_kv "maintenance" "ON"
        return "$STATUS_MAINTENANCE"
    fi

    local_process_running
    _proc=$?
    broker_reachable
    _broker=$?
    registration_present
    _reg=$?
    rpc_ping
    _ping=$?

    [ "$_proc" -eq 0 ] && print_kv "process" "RUNNING" || print_kv "process" "DOWN"
    [ "$_broker" -eq 0 ] && print_kv "broker" "REACHABLE" || print_kv "broker" "UNREACHABLE"
    [ "$_reg" -eq 0 ] && print_kv "registration" "PRESENT" || print_kv "registration" "MISSING_OR_UNKNOWN"
    [ "$_ping" -eq 0 ] && print_kv "rpc-ping" "OK" || print_kv "rpc-ping" "FAILED_OR_UNKNOWN"

    if [ "$_proc" -ne 0 ]; then return "$STATUS_PROCESS_DOWN"; fi
    if [ "$_broker" -ne 0 ]; then return "$STATUS_BROKER_UNREACHABLE"; fi
    if [ "$_reg" -ne 0 ]; then return "$STATUS_NOT_REGISTERED"; fi
    if [ "$_ping" -ne 0 ]; then return "$STATUS_PING_FAILED"; fi
    return "$STATUS_OK"
}

do_watchdog()
{
    config_check || return $?
    if maintenance_active; then
        print_kv "status" "MAINTENANCE"
        print_kv "action" "none"
        return "$STATUS_MAINTENANCE"
    fi

    local_process_running
    _proc=$?
    broker_reachable
    _broker=$?

    if [ "$_broker" -ne 0 ]; then
        if [ "$_proc" -eq 0 ]; then
            print_kv "status" "WAITING_FOR_BROKER"
            print_kv "action" "none"
            return "$STATUS_BROKER_UNREACHABLE"
        fi
        print_kv "status" "PROCESS_DOWN + BROKER_UNREACHABLE"
        print_kv "action" "optional local start only"
        if [ -n "$RPC_START_CMD" ]; then
            do_start
            return $?
        fi
        return "$STATUS_PROCESS_DOWN"
    fi

    if [ "$_proc" -ne 0 ]; then
        print_kv "status" "PROCESS_DOWN"
        do_start || return $?
        wait_for_registration || return "$STATUS_NOT_REGISTERED"
        rpc_ping || return "$STATUS_PING_FAILED"
        return "$STATUS_OK"
    fi

    registration_present
    _reg=$?
    if [ "$_reg" -ne 0 ]; then
        print_kv "status" "NOT_REGISTERED"
        restart_with_limit || return $?
        wait_for_registration || return "$STATUS_NOT_REGISTERED"
        rpc_ping || return "$STATUS_PING_FAILED"
        return "$STATUS_OK"
    fi

    rpc_ping
    _ping=$?
    if [ "$_ping" -ne 0 ]; then
        print_kv "status" "PING_FAILED"
        restart_with_limit
        return $?
    fi

    print_kv "status" "OK"
    print_kv "action" "none"
    return "$STATUS_OK"
}

do_sync()
{
    load_config "$CONFIG_FILE"
    print_kv "sync" "placeholder"
}

do_test()
{
    do_status
}

maintenance_on()
{
    load_config "$CONFIG_FILE"
    ensure_run_dir || die "RUN_DIR is not writable: $RUN_DIR" "$STATUS_CONFIG_ERROR"
    : > "$MAINTENANCE_LOCK" || die "cannot create maintenance lock: $MAINTENANCE_LOCK" "$STATUS_CONFIG_ERROR"
    print_kv "maintenance" "ON"
}

maintenance_off()
{
    load_config "$CONFIG_FILE"
    rm -f "$MAINTENANCE_LOCK" 2>/dev/null || die "cannot remove maintenance lock: $MAINTENANCE_LOCK" "$STATUS_CONFIG_ERROR"
    print_kv "maintenance" "OFF"
}

parse_args "$@"

case "$COMMAND" in
    help) usage; exit "$STATUS_OK" ;;
    status) do_status; exit $? ;;
    start) do_start; exit $? ;;
    stop) do_stop; exit $? ;;
    restart) do_restart; exit $? ;;
    watchdog) do_watchdog; exit $? ;;
    sync) do_sync; exit $? ;;
    test) do_test; exit $? ;;
    config-check) config_check; exit $? ;;
    maintenance-on) maintenance_on; exit $? ;;
    maintenance-off) maintenance_off; exit $? ;;
    *) usage_common "$0"; exit "$STATUS_CONFIG_ERROR" ;;
esac
