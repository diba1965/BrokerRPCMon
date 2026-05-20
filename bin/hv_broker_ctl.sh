#!/bin/sh

SCRIPT_DIR=`dirname "$0"`
BASE_DIR=`cd "$SCRIPT_DIR/.." 2>/dev/null && pwd`
COMPONENT=hv_broker

. "$BASE_DIR/lib/status_codes.sh"
. "$BASE_DIR/lib/logging.sh"
. "$BASE_DIR/lib/common.sh"
. "$BASE_DIR/lib/compat.sh"

CONFIG_FILE=${BROKERRPCMON_HV_CONFIG:-"$BASE_DIR/conf/hv_broker.conf"}

usage()
{
    cat <<EOF
Usage: hv_broker_ctl.sh [-c config-file] command

Commands:
  status        Check broker process, ports, broker info and NL inventory
  start         Start broker using START_BROKER_CMD
  stop          Stop broker using STOP_BROKER_CMD
  restart      Stop and start broker, then observe NL registrations
  broker-info   Show broker information through etbinfo when available
  nl-status     Compare registered NL services with inventory
  config-check  Validate configuration
  help          Show this help
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

    for _name in BROKER_NAME BROKER_HOST BROKER_PORT_CLEAR BROKER_PORT_SSL LOG_DIR RUN_DIR NL_INVENTORY_FILE; do
        eval "_value=\${$_name}"
        if [ -z "$_value" ]; then
            log_error "missing configuration value: $_name"
            _ok=N
        fi
    done

    is_number "$BROKER_PORT_CLEAR" || { log_error "BROKER_PORT_CLEAR is not numeric"; _ok=N; }
    is_number "$BROKER_PORT_SSL" || { log_error "BROKER_PORT_SSL is not numeric"; _ok=N; }
    is_number "$BROKER_START_TIMEOUT" || { log_error "BROKER_START_TIMEOUT is not numeric"; _ok=N; }
    is_number "$BROKER_STOP_TIMEOUT" || { log_error "BROKER_STOP_TIMEOUT is not numeric"; _ok=N; }
    is_number "$PORT_CHECK_TIMEOUT" || { log_error "PORT_CHECK_TIMEOUT is not numeric"; _ok=N; }
    is_number "$NL_REGISTRATION_OBSERVE_TIMEOUT" || { log_error "NL_REGISTRATION_OBSERVE_TIMEOUT is not numeric"; _ok=N; }

    if [ -n "$NL_INVENTORY_FILE" ] && ! check_readable_file "$NL_INVENTORY_FILE"; then
        log_warn "NL inventory is not readable: $NL_INVENTORY_FILE"
    fi

    if [ "$_ok" = Y ]; then
        print_kv "config" "OK"
        return "$STATUS_OK"
    fi
    return "$STATUS_CONFIG_ERROR"
}

broker_process_running()
{
    find_process "$BROKER_NAME"
}

resolve_etbinfo()
{
    if [ -n "$ETBINFO_BIN" ]; then
        printf '%s\n' "$ETBINFO_BIN"
        return 0
    fi
    command -v etbinfo 2>/dev/null
}

broker_info()
{
    _etbinfo=`resolve_etbinfo`
    if [ -z "$_etbinfo" ]; then
        print_kv "broker-info" "UNKNOWN (etbinfo not configured)"
        return "$STATUS_UNKNOWN"
    fi
    "$_etbinfo" "$BROKER_NAME" 2>/dev/null
}

list_registered_services()
{
    _etbinfo=`resolve_etbinfo`
    if [ -n "$_etbinfo" ]; then
        "$_etbinfo" "$BROKER_NAME" 2>/dev/null | awk -F'|' '/^[A-Za-z0-9_.-]+\|/ { print }'
        return 0
    fi
    return 0
}

compare_inventory()
{
    _registered_file=$1
    _missing=0

    if ! check_readable_file "$NL_INVENTORY_FILE"; then
        print_kv "nl-inventory" "UNKNOWN ($NL_INVENTORY_FILE not readable)"
        return "$STATUS_WARNING"
    fi

    while IFS='|' read _nl_id _host _class _server _service _enabled; do
        case "$_nl_id" in
            ''|\#*) continue ;;
        esac
        if [ "$_enabled" != Y ]; then
            continue
        fi
        if grep "^$_nl_id|$_host|$_class|$_server|$_service|" "$_registered_file" >/dev/null 2>&1; then
            print_kv "$_nl_id" "REGISTERED $_server/$_service"
        else
            print_kv "$_nl_id" "MISSING $_server/$_service"
            _missing=`expr "$_missing" + 1`
        fi
    done < "$NL_INVENTORY_FILE"

    if [ "$_missing" -gt 0 ]; then
        return "$STATUS_NOT_REGISTERED"
    fi
    return "$STATUS_OK"
}

do_status()
{
    config_check || return $?
    _status=$STATUS_OK
    print_kv "broker" "$BROKER_NAME"

    if broker_process_running; then
        print_kv "process" "RUNNING"
    else
        print_kv "process" "UNKNOWN_OR_DOWN"
        _status=$STATUS_WARNING
    fi

    check_tcp_port "$BROKER_HOST" "$BROKER_PORT_CLEAR" "$PORT_CHECK_TIMEOUT"
    _clear_rc=$?
    check_tcp_port "$BROKER_HOST" "$BROKER_PORT_SSL" "$PORT_CHECK_TIMEOUT"
    _ssl_rc=$?

    [ "$_clear_rc" -eq 0 ] && print_kv "port-clear" "OPEN $BROKER_PORT_CLEAR" || { print_kv "port-clear" "NOT_OPEN $BROKER_PORT_CLEAR"; _status=$STATUS_BROKER_UNREACHABLE; }
    [ "$_ssl_rc" -eq 0 ] && print_kv "port-ssl" "OPEN $BROKER_PORT_SSL" || { print_kv "port-ssl" "NOT_OPEN $BROKER_PORT_SSL"; _status=$STATUS_BROKER_UNREACHABLE; }

    broker_info >/dev/null 2>&1 || print_kv "broker-info" "UNKNOWN"

    _tmp=${TMPDIR:-/tmp}/brokerrpcmon_hv_registered.$$
    list_registered_services > "$_tmp"
    compare_inventory "$_tmp"
    _inv_rc=$?
    rm -f "$_tmp"
    if [ "$_inv_rc" -ne 0 ] && [ "$_status" -eq "$STATUS_OK" ]; then
        _status=$_inv_rc
    fi
    return "$_status"
}

wait_for_port_state()
{
    _host=$1
    _port=$2
    _want=$3
    _timeout=$4
    _elapsed=0
    while [ "$_elapsed" -lt "$_timeout" ]; do
        check_tcp_port "$_host" "$_port" 2
        _rc=$?
        if [ "$_want" = open ] && [ "$_rc" -eq 0 ]; then
            return 0
        fi
        if [ "$_want" = closed ] && [ "$_rc" -ne 0 ]; then
            return 0
        fi
        sleep_seconds 1
        _elapsed=`expr "$_elapsed" + 1`
    done
    return 1
}

do_start()
{
    config_check || return $?
    if check_tcp_port "$BROKER_HOST" "$BROKER_PORT_SSL" 2 || check_tcp_port "$BROKER_HOST" "$BROKER_PORT_CLEAR" 2; then
        print_kv "broker" "already reachable"
        return "$STATUS_OK"
    fi
    [ -n "$START_BROKER_CMD" ] || die "START_BROKER_CMD is not configured" "$STATUS_CONFIG_ERROR"
    log_info "starting broker $BROKER_NAME"
    sh -c "$START_BROKER_CMD" || return "$STATUS_CRITICAL"
    wait_for_port_state "$BROKER_HOST" "$BROKER_PORT_CLEAR" open "$BROKER_START_TIMEOUT" || return "$STATUS_BROKER_UNREACHABLE"
    broker_info >/dev/null 2>&1 || return "$STATUS_WARNING"
    print_kv "broker" "started"
    return "$STATUS_OK"
}

do_stop()
{
    config_check || return $?
    [ -n "$STOP_BROKER_CMD" ] || die "STOP_BROKER_CMD is not configured" "$STATUS_CONFIG_ERROR"
    log_info "stopping broker $BROKER_NAME"
    sh -c "$STOP_BROKER_CMD" || return "$STATUS_CRITICAL"
    wait_for_port_state "$BROKER_HOST" "$BROKER_PORT_CLEAR" closed "$BROKER_STOP_TIMEOUT" || return "$STATUS_WARNING"
    print_kv "broker" "stopped"
    print_kv "nl-rpc" "not stopped remotely"
    return "$STATUS_OK"
}

do_restart()
{
    config_check || return $?
    log_info "broker restart requested; NL RPC servers will not be remotely started"
    do_stop
    _stop_rc=$?
    if [ "$_stop_rc" -ne 0 ] && [ "$_stop_rc" -ne "$STATUS_WARNING" ]; then
        return "$_stop_rc"
    fi
    do_start || return $?
    observe_nl_registrations
}

observe_nl_registrations()
{
    _elapsed=0
    print_kv "nl-observe-window" "$NL_REGISTRATION_OBSERVE_TIMEOUT"
    while [ "$_elapsed" -lt "$NL_REGISTRATION_OBSERVE_TIMEOUT" ]; do
        do_nl_status
        _rc=$?
        if [ "$_rc" -eq "$STATUS_OK" ]; then
            return "$STATUS_OK"
        fi
        sleep_seconds 5
        _elapsed=`expr "$_elapsed" + 5`
    done
    return "$STATUS_NOT_REGISTERED"
}

do_broker_info()
{
    load_config "$CONFIG_FILE"
    broker_info
}

do_nl_status()
{
    load_config "$CONFIG_FILE"
    _tmp=${TMPDIR:-/tmp}/brokerrpcmon_hv_registered.$$
    list_registered_services > "$_tmp"
    compare_inventory "$_tmp"
    _rc=$?
    rm -f "$_tmp"
    return "$_rc"
}

parse_args "$@"

case "$COMMAND" in
    help) usage; exit "$STATUS_OK" ;;
    status) do_status; exit $? ;;
    start) do_start; exit $? ;;
    stop) do_stop; exit $? ;;
    restart) do_restart; exit $? ;;
    broker-info) do_broker_info; exit $? ;;
    nl-status) do_nl_status; exit $? ;;
    config-check) config_check; exit $? ;;
    *) usage_common "$0"; exit "$STATUS_CONFIG_ERROR" ;;
esac
