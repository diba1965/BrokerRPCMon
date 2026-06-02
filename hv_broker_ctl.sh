#!/bin/sh

BROKER_NAME="ETBSAPSSL"
BROKER_HOST="localhost"
BROKER_PORT_CLEAR="10001"
BROKER_PORT_SSL="10052"

EXXDIR="/usr/SAG/exx/v107/EntireX"
ETBSRV_BIN=""
ETBINFO_BIN=""
ETBCMD_BIN=""

BROKER_PING_HOST=""
BROKER_PING_PORT=""

START_BROKER_CMD=""
STOP_BROKER_CMD=""

NL_INVENTORY_FILE=""
NL_INVENTORY_INLINE="
NL41|SRV00041|RPC|SAPNL141|CALLNAT|Y
"

CONFIG_FILE=""
CONFIG_SOURCE="builtin"
COMMAND=""

STATUS_OK=0
STATUS_WARNING=1
STATUS_CRITICAL=2
STATUS_CONFIG_ERROR=3
STATUS_BROKER_UNREACHABLE=4
STATUS_NOT_REGISTERED=5
STATUS_PING_FAILED=6
STATUS_UNKNOWN=9

print_kv() {
    printf '%-28s %s\n' "$1:" "$2"
}

usage() {
    printf '%s\n' "Usage:"
    printf '%s\n' "  hv_broker_ctl.sh [-c CONFIG_FILE] <command>"
    printf '%s\n' ""
    printf '%s\n' "Options:"
    printf '%s\n' "  -c, --config FILE    Path to HV configuration file"
    printf '%s\n' "  -h, --help           Show this help"
    printf '%s\n' ""
    printf '%s\n' "Commands:"
    printf '%s\n' "  help                 Show this help"
    printf '%s\n' "  config-check         Validate and display effective HV configuration"
    printf '%s\n' "  status               Show complete broker and NL registration status"
    printf '%s\n' "  start                Start broker if broker ping is not already OK"
    printf '%s\n' "  stop                 Stop broker using STOP_BROKER_CMD"
    printf '%s\n' "  restart              Stop and start broker using configured commands"
    printf '%s\n' "  broker-info          Show raw etbinfo service information"
    printf '%s\n' "  nl-status            Show expected NL service registration status"
}

parse_args() {
    while [ $# -gt 0 ]
    do
        if [ "$1" = "-c" ]; then
            shift
            if [ $# -eq 0 ]; then
                printf '%s\n' "ERROR: missing argument for -c" >&2
                exit "$STATUS_CONFIG_ERROR"
            fi
            CONFIG_FILE=$1
            CONFIG_SOURCE=$1
            shift
        elif [ "$1" = "--config" ]; then
            shift
            if [ $# -eq 0 ]; then
                printf '%s\n' "ERROR: missing argument for --config" >&2
                exit "$STATUS_CONFIG_ERROR"
            fi
            CONFIG_FILE=$1
            CONFIG_SOURCE=$1
            shift
        elif [ "$1" = "-h" ]; then
            COMMAND="help"
            shift
        elif [ "$1" = "--help" ]; then
            COMMAND="help"
            shift
        else
            COMMAND=$1
            shift
        fi
    done

    if [ -z "$COMMAND" ]; then
        COMMAND="help"
    fi
}

load_config() {
    if [ "$COMMAND" = "help" ]; then
        return 0
    fi

    if [ -z "$CONFIG_FILE" ]; then
        CONFIG_SOURCE="builtin"
        return 0
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        print_kv "config-source" "$CONFIG_FILE"
        print_kv "config" "ERROR file_not_readable $CONFIG_FILE"
        return "$STATUS_CONFIG_ERROR"
    fi

    if [ ! -r "$CONFIG_FILE" ]; then
        print_kv "config-source" "$CONFIG_FILE"
        print_kv "config" "ERROR file_not_readable $CONFIG_FILE"
        return "$STATUS_CONFIG_ERROR"
    fi

    . "$CONFIG_FILE"
    return 0
}

find_cmd() {
    command -v "$1" 2>/dev/null
}

get_etbsrv() {
    if [ -n "$ETBSRV_BIN" ]; then
        if [ -x "$ETBSRV_BIN" ]; then
            printf '%s\n' "$ETBSRV_BIN"
            return 0
        fi
    fi

    if [ -x "$EXXDIR/bin/etbsrv" ]; then
        printf '%s\n' "$EXXDIR/bin/etbsrv"
        return 0
    fi

    find_cmd etbsrv
}

get_etbinfo() {
    if [ -n "$ETBINFO_BIN" ]; then
        if [ -x "$ETBINFO_BIN" ]; then
            printf '%s\n' "$ETBINFO_BIN"
            return 0
        fi
    fi

    if [ -x "$EXXDIR/bin/etbinfo" ]; then
        printf '%s\n' "$EXXDIR/bin/etbinfo"
        return 0
    fi

    find_cmd etbinfo
}

get_etbcmd() {
    if [ -n "$ETBCMD_BIN" ]; then
        if [ -x "$ETBCMD_BIN" ]; then
            printf '%s\n' "$ETBCMD_BIN"
            return 0
        fi
    fi

    if [ -x "$EXXDIR/bin/etbcmd" ]; then
        printf '%s\n' "$EXXDIR/bin/etbcmd"
        return 0
    fi

    find_cmd etbcmd
}

broker_runtime() {
    _etbsrv=`get_etbsrv`
    if [ -z "$_etbsrv" ]; then
        print_kv "broker-runtime" "UNKNOWN_OR_DOWN etbsrv_not_found"
        return "$STATUS_WARNING"
    fi

    _tmp=${TMPDIR:-/tmp}/hv_broker_etbsrv.$$
    "$_etbsrv" broker status > "$_tmp" 2>/dev/null
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        rm -f "$_tmp"
        print_kv "broker-runtime" "FAILED source=etbsrv rc=$_rc"
        return "$STATUS_WARNING"
    fi

    grep "$BROKER_NAME" "$_tmp" | grep "Running" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        _pid=`grep "$BROKER_NAME" "$_tmp" | grep "Running" | awk '{ print $(NF - 1) }' | head -1`
        rm -f "$_tmp"
        if [ -n "$_pid" ]; then
            print_kv "broker-runtime" "RUNNING pid=$_pid source=etbsrv"
        else
            print_kv "broker-runtime" "RUNNING source=etbsrv"
        fi
        return "$STATUS_OK"
    fi

    rm -f "$_tmp"
    print_kv "broker-runtime" "NOT_RUNNING source=etbsrv"
    return "$STATUS_WARNING"
}

broker_ping() {
    _label=$1
    if [ -z "$_label" ]; then
        _label="broker-ping"
    fi

    _etbcmd=`get_etbcmd`
    if [ -z "$_etbcmd" ]; then
        print_kv "$_label" "NOT_CONFIGURED etbcmd_not_found"
        return "$STATUS_UNKNOWN"
    fi

    _host=$BROKER_HOST
    if [ -n "$BROKER_PING_HOST" ]; then
        _host=$BROKER_PING_HOST
    fi

    _port=$BROKER_PORT_CLEAR
    if [ -n "$BROKER_PING_PORT" ]; then
        _port=$BROKER_PING_PORT
    fi

    _broker="$_host:$_port"
    "$_etbcmd" -b "$_broker" -d BROKER -c PING >/dev/null 2>&1
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        print_kv "$_label" "OK source=etbcmd broker=$_broker"
        return "$STATUS_OK"
    fi

    print_kv "$_label" "FAILED source=etbcmd broker=$_broker rc=$_rc"
    return "$STATUS_PING_FAILED"
}

broker_info() {
    _etbinfo=`get_etbinfo`
    if [ -z "$_etbinfo" ]; then
        print_kv "broker-info" "NOT_CONFIGURED etbinfo_not_found"
        return "$STATUS_WARNING"
    fi

    _tmp=${TMPDIR:-/tmp}/hv_broker_etbinfo.$$
    "$_etbinfo" -b "$BROKER_HOST:$BROKER_PORT_CLEAR" -d SERVICE -l FULL > "$_tmp" 2>/dev/null
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        rm -f "$_tmp"
        print_kv "broker-info" "FAILED source=etbinfo rc=$_rc"
        return "$STATUS_WARNING"
    fi

    if [ -s "$_tmp" ]; then
        rm -f "$_tmp"
        print_kv "broker-info" "OK source=etbinfo"
        return "$STATUS_OK"
    fi

    rm -f "$_tmp"
    print_kv "broker-info" "FAILED source=etbinfo rc=empty"
    return "$STATUS_WARNING"
}

list_services() {
    _etbinfo=`get_etbinfo`
    if [ -z "$_etbinfo" ]; then
        return "$STATUS_WARNING"
    fi

    "$_etbinfo" -b "$BROKER_HOST:$BROKER_PORT_CLEAR" -d SERVICE -l FULL 2>/dev/null | awk '
        index($0, "..") > 0 {
            print substr($0, 1, index($0, "..") - 1)
        }
    '
}

inventory_status() {
    _etbinfo=`get_etbinfo`
    if [ -z "$_etbinfo" ]; then
        print_kv "nl-inventory" "SKIPPED etbinfo_not_found"
        return "$STATUS_OK"
    fi

    _services=${TMPDIR:-/tmp}/hv_broker_services.$$
    list_services > "$_services"
    if [ $? -ne 0 ]; then
        rm -f "$_services"
        print_kv "nl-inventory" "SKIPPED etbinfo_failed"
        return "$STATUS_WARNING"
    fi

    _inventory=${TMPDIR:-/tmp}/hv_broker_inventory.$$
    if [ -n "$NL_INVENTORY_FILE" ]; then
        if [ -r "$NL_INVENTORY_FILE" ]; then
            _inventory=$NL_INVENTORY_FILE
        else
            rm -f "$_services"
            print_kv "nl-inventory" "WARNING file_not_readable $NL_INVENTORY_FILE"
            return "$STATUS_WARNING"
        fi
    else
        printf '%s\n' "$NL_INVENTORY_INLINE" > "$_inventory"
    fi

    _missing=0
    while IFS='|' read _nl_id _host _class _server _service _enabled
    do
        if [ -z "$_nl_id" ]; then
            continue
        fi
        case "$_nl_id" in
            \#*)
                continue
                ;;
        esac
        if [ "$_enabled" != "Y" ]; then
            continue
        fi

        _key="$_class.$_server.$_service"
        grep "$_key" "$_services" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            print_kv "$_nl_id" "REGISTERED $_server/$_service source=etbinfo"
        else
            print_kv "$_nl_id" "MISSING $_server/$_service status=NOT_REGISTERED"
            _missing=`expr "$_missing" + 1`
        fi
    done < "$_inventory"

    rm -f "$_services"
    if [ -z "$NL_INVENTORY_FILE" ]; then
        rm -f "$_inventory"
    fi

    if [ "$_missing" -eq 0 ]; then
        return "$STATUS_OK"
    fi

    return "$STATUS_NOT_REGISTERED"
}

check_listen_port() {
    _port=$1

    command -v netstat >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        return "$STATUS_UNKNOWN"
    fi

    netstat -an 2>/dev/null | awk -v p=".$_port" '
        $0 ~ p && $0 ~ /LISTEN/ {
            found = 1
        }
        END {
            if (found == 1) {
                exit 0
            }
            exit 1
        }
    '
}

print_port_status() {
    _label=$1
    _port=$2

    command -v netstat >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        print_kv "$_label" "UNKNOWN $_port reason=netstat_not_found"
        return "$STATUS_UNKNOWN"
    fi

    check_listen_port "$_port"
    if [ $? -eq 0 ]; then
        print_kv "$_label" "OPEN $_port"
        return "$STATUS_OK"
    fi

    print_kv "$_label" "CLOSED $_port"
    return "$STATUS_BROKER_UNREACHABLE"
}

cmd_config_check() {
    load_config
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        return "$_rc"
    fi

    print_kv "config-source" "$CONFIG_SOURCE"
    print_kv "config" "OK"
    print_kv "broker" "$BROKER_NAME"
    print_kv "broker-host" "$BROKER_HOST"
    print_kv "broker-port-clear" "$BROKER_PORT_CLEAR"
    print_kv "broker-port-ssl" "$BROKER_PORT_SSL"
    print_kv "exxdir" "$EXXDIR"

    _etbsrv=`get_etbsrv`
    if [ -n "$_etbsrv" ]; then
        print_kv "etbsrv" "$_etbsrv"
    else
        print_kv "etbsrv" "NOT_FOUND"
    fi

    _etbcmd=`get_etbcmd`
    if [ -n "$_etbcmd" ]; then
        print_kv "etbcmd" "$_etbcmd"
    else
        print_kv "etbcmd" "NOT_FOUND"
    fi

    _etbinfo=`get_etbinfo`
    if [ -n "$_etbinfo" ]; then
        print_kv "etbinfo" "$_etbinfo"
    else
        print_kv "etbinfo" "NOT_FOUND"
    fi

    _host=$BROKER_HOST
    if [ -n "$BROKER_PING_HOST" ]; then
        _host=$BROKER_PING_HOST
    fi
    _port=$BROKER_PORT_CLEAR
    if [ -n "$BROKER_PING_PORT" ]; then
        _port=$BROKER_PING_PORT
    fi
    print_kv "broker-ping-target" "$_host:$_port"

    if [ -n "$START_BROKER_CMD" ]; then
        print_kv "start-command" "$START_BROKER_CMD"
    else
        print_kv "start-command" "NOT_CONFIGURED"
    fi

    if [ -n "$STOP_BROKER_CMD" ]; then
        print_kv "stop-command" "$STOP_BROKER_CMD"
    else
        print_kv "stop-command" "NOT_CONFIGURED"
    fi

    if [ -n "$NL_INVENTORY_FILE" ]; then
        print_kv "inventory-source" "file=$NL_INVENTORY_FILE"
    else
        print_kv "inventory-source" "inline"
    fi

    return "$STATUS_OK"
}

cmd_status() {
    load_config
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        return "$_rc"
    fi

    print_kv "config-source" "$CONFIG_SOURCE"
    print_kv "config" "OK"
    print_kv "broker" "$BROKER_NAME"

    _overall=$STATUS_OK

    broker_runtime
    if [ $? -ne 0 ]; then
        _overall=$STATUS_WARNING
    fi

    broker_ping
    if [ $? -eq "$STATUS_PING_FAILED" ]; then
        _overall=$STATUS_WARNING
    fi

    print_port_status "port-clear" "$BROKER_PORT_CLEAR"
    _port_clear_rc=$?
    print_port_status "port-ssl" "$BROKER_PORT_SSL"
    _port_ssl_rc=$?
    if [ "$_port_clear_rc" -eq "$STATUS_BROKER_UNREACHABLE" ]; then
        _overall=$STATUS_BROKER_UNREACHABLE
    fi
    if [ "$_port_ssl_rc" -eq "$STATUS_BROKER_UNREACHABLE" ]; then
        _overall=$STATUS_BROKER_UNREACHABLE
    fi

    broker_info
    if [ $? -ne 0 ]; then
        if [ "$_overall" -eq "$STATUS_OK" ]; then
            _overall=$STATUS_WARNING
        fi
    fi

    inventory_status
    if [ $? -ne 0 ]; then
        if [ "$_overall" -eq "$STATUS_OK" ]; then
            _overall=$STATUS_NOT_REGISTERED
        fi
    fi

    if [ "$_overall" -eq "$STATUS_OK" ]; then
        print_kv "overall" "OK"
    else
        print_kv "overall" "WARNING"
    fi

    return "$_overall"
}

cmd_broker_info() {
    load_config
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        return "$_rc"
    fi

    _etbinfo=`get_etbinfo`
    if [ -z "$_etbinfo" ]; then
        print_kv "config" "OK"
        print_kv "broker-info" "NOT_CONFIGURED etbinfo_not_found"
        return "$STATUS_CONFIG_ERROR"
    fi

    _broker="$BROKER_HOST:$BROKER_PORT_CLEAR"
    _tmp=${TMPDIR:-/tmp}/hv_broker_info.$$
    "$_etbinfo" -b "$_broker" -d SERVICE -l FULL > "$_tmp"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        rm -f "$_tmp"
        print_kv "broker-info" "FAILED source=etbinfo broker=$_broker rc=$_rc"
        return "$_rc"
    fi

    print_kv "broker-info" "OK source=etbinfo broker=$_broker"
    cat "$_tmp"
    rm -f "$_tmp"
    return "$STATUS_OK"
}

cmd_nl_status() {
    load_config
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        return "$_rc"
    fi

    print_kv "config-source" "$CONFIG_SOURCE"
    print_kv "config" "OK"
    print_kv "broker" "$BROKER_NAME"
    broker_info
    _info_rc=$?
    printf '%s\n' ""
    printf '%s\n' "NL services:"
    inventory_status
    _inv_rc=$?

    if [ "$_info_rc" -eq 0 ]; then
        if [ "$_inv_rc" -eq 0 ]; then
            print_kv "overall" "OK"
            return "$STATUS_OK"
        fi
    fi

    print_kv "overall" "WARNING"
    return "$STATUS_WARNING"
}

cmd_start() {
    load_config
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        return "$_rc"
    fi

    broker_ping
    _ping_rc=$?
    if [ "$_ping_rc" -eq "$STATUS_OK" ]; then
        print_kv "start" "SKIPPED reason=broker_already_running"
        print_kv "overall" "OK"
        return "$STATUS_OK"
    fi

    if [ -z "$START_BROKER_CMD" ]; then
        print_kv "start" "NOT_CONFIGURED START_BROKER_CMD empty"
        print_kv "overall" "CONFIG_ERROR"
        return "$STATUS_CONFIG_ERROR"
    fi

    print_kv "start" "STARTING"
    print_kv "start-command" "$START_BROKER_CMD"
    sh -c "$START_BROKER_CMD"
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        print_kv "start-result" "OK rc=0"
        broker_ping "broker-ping-after-start"
        if [ $? -eq "$STATUS_OK" ]; then
            print_kv "overall" "OK"
            return "$STATUS_OK"
        fi
        print_kv "overall" "WARNING"
        return "$STATUS_WARNING"
    fi

    print_kv "start-result" "FAILED rc=$_rc"
    print_kv "overall" "CRITICAL"
    return "$STATUS_CRITICAL"
}

cmd_stop() {
    load_config
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        return "$_rc"
    fi

    broker_ping
    _ping_rc=$?
    if [ "$_ping_rc" -ne "$STATUS_OK" ]; then
        print_kv "stop" "SKIPPED reason=broker_not_running_or_not_reachable"
        print_kv "overall" "OK"
        return "$STATUS_OK"
    fi

    if [ -z "$STOP_BROKER_CMD" ]; then
        print_kv "stop" "NOT_CONFIGURED STOP_BROKER_CMD empty"
        print_kv "overall" "CONFIG_ERROR"
        return "$STATUS_CONFIG_ERROR"
    fi

    print_kv "stop" "STOPPING"
    print_kv "stop-command" "$STOP_BROKER_CMD"
    sh -c "$STOP_BROKER_CMD"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        print_kv "stop-result" "FAILED rc=$_rc"
        print_kv "overall" "CRITICAL"
        return "$STATUS_CRITICAL"
    fi

    print_kv "stop-result" "OK rc=0"
    broker_ping "broker-ping-after-stop"
    if [ $? -eq "$STATUS_OK" ]; then
        print_kv "reason" "broker_still_reachable_after_stop"
        print_kv "overall" "WARNING"
        return "$STATUS_WARNING"
    fi

    print_kv "overall" "OK"
    return "$STATUS_OK"
}

cmd_restart() {
    load_config
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        return "$_rc"
    fi

    if [ -z "$STOP_BROKER_CMD" ]; then
        print_kv "restart" "NOT_CONFIGURED START_BROKER_CMD_or_STOP_BROKER_CMD empty"
        print_kv "overall" "CONFIG_ERROR"
        return "$STATUS_CONFIG_ERROR"
    fi
    if [ -z "$START_BROKER_CMD" ]; then
        print_kv "restart" "NOT_CONFIGURED START_BROKER_CMD_or_STOP_BROKER_CMD empty"
        print_kv "overall" "CONFIG_ERROR"
        return "$STATUS_CONFIG_ERROR"
    fi

    broker_ping "broker-ping-before-restart"
    print_kv "restart" "STOPPING"
    print_kv "stop-command" "$STOP_BROKER_CMD"
    sh -c "$STOP_BROKER_CMD"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        print_kv "stop-result" "FAILED rc=$_rc"
        print_kv "restart" "ABORTED reason=stop_failed"
        print_kv "overall" "CRITICAL"
        return "$STATUS_CRITICAL"
    fi
    print_kv "stop-result" "OK rc=0"
    sleep 2

    print_kv "restart" "STARTING"
    print_kv "start-command" "$START_BROKER_CMD"
    sh -c "$START_BROKER_CMD"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        print_kv "start-result" "FAILED rc=$_rc"
        print_kv "overall" "CRITICAL"
        return "$STATUS_CRITICAL"
    fi
    print_kv "start-result" "OK rc=0"

    broker_ping "broker-ping-after-start"
    if [ $? -eq "$STATUS_OK" ]; then
        print_kv "overall" "OK"
        return "$STATUS_OK"
    fi

    print_kv "overall" "WARNING"
    return "$STATUS_WARNING"
}

parse_args "$@"

case "$COMMAND" in
    help)
        usage
        exit "$STATUS_OK"
        ;;
    config-check)
        cmd_config_check
        exit $?
        ;;
    status)
        cmd_status
        exit $?
        ;;
    start)
        cmd_start
        exit $?
        ;;
    stop)
        cmd_stop
        exit $?
        ;;
    restart)
        cmd_restart
        exit $?
        ;;
    broker-info)
        cmd_broker_info
        exit $?
        ;;
    nl-status)
        cmd_nl_status
        exit $?
        ;;
    *)
        printf '%s\n' "ERROR: unknown command: $COMMAND" >&2
        usage
        exit "$STATUS_CONFIG_ERROR"
        ;;
esac
