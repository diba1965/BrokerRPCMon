#!/bin/sh

COMPONENT=nl_rpc

# ===== Default configuration - may be overridden by -c/--config =====

NL_ID="NL41"

BROKER_NAME="ETBSAPSSL"
BROKER_HOST="srv00037"
BROKER_PORT="10052"
BROKER_SSL="Y"

RPC_SERVER_CLASS="RPC"
RPC_SERVER_NAME="SAPNL141"
RPC_SERVICE="CALLNAT"
NATURAL_PARM="SAPNL141"

ETBINFO_BIN=""

RPC_PING_ENABLED="Y"
RPC_PING_BROKER_HOST=""
RPC_PING_BROKER_PORT="10001"
RPC_PING_TIMEOUT="30"

RPC_START_CMD=""
RPC_STOP_CMD=""

MAINTENANCE_LOCK="/tmp/brokerrpcmon_maintenance.lock"

BROKER_CHECK_TIMEOUT="30"

LOG_FILE=""

STATUS_OK=0
STATUS_WARNING=1
STATUS_CRITICAL=2
STATUS_CONFIG_ERROR=3
STATUS_BROKER_UNREACHABLE=4
STATUS_NOT_REGISTERED=5
STATUS_PING_FAILED=6
STATUS_PROCESS_DOWN=7
STATUS_MAINTENANCE=8
STATUS_UNKNOWN=9

CONFIG_FILE=""
CONFIG_SOURCE="builtin"
COMMAND=""
COMMAND_ARGS=""
RPC_PING_STATUS=""

usage()
{
    cat <<EOF
Usage:
  nl_rpc_ctl.sh [-c CONFIG_FILE] <command>

Options:
  -c, --config FILE    Path to NL configuration file
  -h, --help           Show this help

Commands:
  status
  start
  stop
  restart
  config-check
  help
EOF
}

print_kv()
{
    printf '%-28s %s\n' "$1:" "$2"
}

is_number()
{
    _value=$1
    case "$_value" in
        ''|*[!0123456789]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

check_readable_file()
{
    _file=$1
    [ -n "$_file" ] && [ -f "$_file" ] && [ -r "$_file" ]
}

log_line()
{
    _level=$1
    shift
    _message=$*
    _ts=`date '+%Y-%m-%d %H:%M:%S' 2>/dev/null`
    [ -z "$_ts" ] && _ts=unknown-time
    _line="$_ts $_level $COMPONENT $_message"
    printf '%s\n' "$_line" >&2
    if [ -n "$LOG_FILE" ]; then
        printf '%s\n' "$_line" >> "$LOG_FILE" 2>/dev/null
    fi
}

log_info()
{
    log_line INFO "$@"
}

log_warn()
{
    log_line WARN "$@"
}

log_error()
{
    log_line ERROR "$@"
}

check_tcp_port()
{
    _host=$1
    _port=$2
    _timeout=$3
    [ -z "$_timeout" ] && _timeout=5

    if [ -n "$BROKERRPCMON_TCP_STATUS" ]; then
        return "$BROKERRPCMON_TCP_STATUS"
    fi

    if command -v nc >/dev/null 2>&1; then
        nc -z -w "$_timeout" "$_host" "$_port" >/dev/null 2>&1
        return $?
    fi

    if command -v perl >/dev/null 2>&1; then
        perl -MIO::Socket::INET -e 'exit(IO::Socket::INET->new(PeerAddr=>$ARGV[0],PeerPort=>$ARGV[1],Proto=>"tcp",Timeout=>$ARGV[2]) ? 0 : 1)' "$_host" "$_port" "$_timeout" >/dev/null 2>&1
        return $?
    fi

    if command -v telnet >/dev/null 2>&1; then
        (sleep 1; printf '\035quit\n') | telnet "$_host" "$_port" >/dev/null 2>&1
        return $?
    fi

    return 9
}

parse_args()
{
    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--config)
                shift
                if [ $# -eq 0 ]; then
                    printf '%s\n' 'ERROR: missing argument for -c/--config' >&2
                    exit "$STATUS_CONFIG_ERROR"
                fi
                CONFIG_FILE=$1
                shift
                ;;
            --config=*)
                CONFIG_FILE=`printf '%s\n' "$1" | sed 's/^--config=//'`
                if [ -z "$CONFIG_FILE" ]; then
                    printf '%s\n' 'ERROR: missing argument for -c/--config' >&2
                    exit "$STATUS_CONFIG_ERROR"
                fi
                shift
                ;;
            help|-h|--help)
                COMMAND=help
                shift
                ;;
            *)
                COMMAND=$1
                shift
                COMMAND_ARGS=$*
                break
                ;;
        esac
    done

    [ -z "$COMMAND" ] && COMMAND=help

    if [ -n "$CONFIG_FILE" ]; then
        CONFIG_SOURCE=$CONFIG_FILE
    elif [ -n "$BROKERRPCMON_NL_CONFIG" ]; then
        CONFIG_FILE=$BROKERRPCMON_NL_CONFIG
        CONFIG_SOURCE=$CONFIG_FILE
    else
        CONFIG_SOURCE=builtin
    fi
}

load_selected_config()
{
    if [ -z "$CONFIG_FILE" ]; then
        CONFIG_SOURCE=builtin
        return "$STATUS_OK"
    fi

    if ! check_readable_file "$CONFIG_FILE"; then
        print_kv "config-source" "$CONFIG_FILE"
        print_kv "config" "ERROR file_not_readable $CONFIG_FILE"
        return "$STATUS_CONFIG_ERROR"
    fi

    . "$CONFIG_FILE"
    return "$STATUS_OK"
}

apply_config_defaults()
{
    if [ -z "$NATURAL_PARM" ]; then
        NATURAL_PARM=$RPC_SERVER_NAME
    fi
    if [ -z "$RPC_PING_ENABLED" ]; then
        RPC_PING_ENABLED=Y
    fi
    if [ -z "$RPC_PING_BROKER_HOST" ]; then
        RPC_PING_BROKER_HOST=$BROKER_HOST
    fi
    if [ -z "$RPC_PING_BROKER_PORT" ]; then
        RPC_PING_BROKER_PORT=$BROKER_PORT
    fi
    if [ -z "$RPC_PING_TIMEOUT" ]; then
        RPC_PING_TIMEOUT=30
    fi
}

config_check()
{
    load_selected_config || return $?
    apply_config_defaults
    print_kv "config-source" "$CONFIG_SOURCE"
    _ok=Y

    for _name in NL_ID BROKER_NAME BROKER_HOST BROKER_PORT RPC_SERVER_CLASS RPC_SERVER_NAME RPC_SERVICE MAINTENANCE_LOCK BROKER_CHECK_TIMEOUT RPC_PING_TIMEOUT; do
        eval "_value=\${$_name}"
        if [ -z "$_value" ]; then
            log_error "missing configuration value: $_name"
            _ok=N
        fi
    done

    is_number "$BROKER_PORT" || { log_error "BROKER_PORT is not numeric"; _ok=N; }
    is_number "$BROKER_CHECK_TIMEOUT" || { log_error "BROKER_CHECK_TIMEOUT is not numeric"; _ok=N; }
    is_number "$RPC_PING_TIMEOUT" || { log_error "RPC_PING_TIMEOUT is not numeric"; _ok=N; }

    if [ "$_ok" = Y ]; then
        print_kv "config" "OK"
        return "$STATUS_OK"
    fi
    return "$STATUS_CONFIG_ERROR"
}

effective_natural_parm()
{
    if [ -n "$NATURAL_PARM" ]; then
        printf '%s\n' "$NATURAL_PARM"
    else
        printf '%s\n' "$RPC_SERVER_NAME"
    fi
}

rpc_service_key()
{
    printf '%s.%s.%s\n' "$RPC_SERVER_CLASS" "$RPC_SERVER_NAME" "$RPC_SERVICE"
}

ps_ef()
{
    if [ -n "$BROKERRPCMON_PS_FILE" ] && [ -r "$BROKERRPCMON_PS_FILE" ]; then
        cat "$BROKERRPCMON_PS_FILE"
        return 0
    fi
    ps -ef
}

local_process_pid()
{
    _parm=`effective_natural_parm`
    ps_ef 2>/dev/null | awk -v parm="$_parm" '
        index($0, "natural") > 0 &&
        index($0, "server=on") > 0 &&
        index($0, "parm=" parm) > 0 &&
        index($0, "grep") == 0 &&
        index($0, "awk") == 0 {
            print $2
            found = 1
            exit
        }
        END {
            exit(found == 1 ? 0 : 1)
        }
    '
}

local_process_running()
{
    _pid=`local_process_pid`
    [ -n "$_pid" ]
}

broker_reachable()
{
    check_tcp_port "$BROKER_HOST" "$BROKER_PORT" "$BROKER_CHECK_TIMEOUT"
}

resolve_etbinfo()
{
    if [ -n "$ETBINFO_BIN" ] && [ -x "$ETBINFO_BIN" ]; then
        printf '%s\n' "$ETBINFO_BIN"
        return 0
    fi
    command -v etbinfo 2>/dev/null
}

registration_present()
{
    _etbinfo=`resolve_etbinfo`
    [ -n "$_etbinfo" ] || return "$STATUS_UNKNOWN"
    _service_key=`rpc_service_key`
    "$_etbinfo" -b "$BROKER_HOST:$BROKER_PORT" -d SERVICE -l FULL 2>/dev/null | awk -v key="$_service_key" '
        index($0, "..") > 0 {
            service = substr($0, 1, index($0, "..") - 1)
            if (service == key) {
                found = 1
                exit
            }
        }
        END {
            exit(found == 1 ? 0 : 1)
        }
    '
}

rpc_ping_check()
{
    _broker_rc=$1
    _reg_rc=$2

    case "$RPC_PING_ENABLED" in
        N|n)
            RPC_PING_STATUS="DISABLED"
            return "$STATUS_OK"
            ;;
    esac

    if [ "$_broker_rc" -ne 0 ]; then
        RPC_PING_STATUS="SKIPPED reason=broker_unreachable"
        return "$STATUS_OK"
    fi
    if [ "$_reg_rc" -ne 0 ]; then
        RPC_PING_STATUS="SKIPPED reason=registration_missing"
        return "$STATUS_OK"
    fi

    _etbinfo=`resolve_etbinfo`
    if [ -z "$_etbinfo" ]; then
        RPC_PING_STATUS="NOT_CONFIGURED etbinfo_not_found"
        return "$STATUS_WARNING"
    fi

    "$_etbinfo" -b "$RPC_PING_BROKER_HOST:$RPC_PING_BROKER_PORT" -d SERVER -c "$RPC_SERVER_CLASS" -s "$RPC_SERVICE" -n "$RPC_SERVER_NAME" --pingrpc >/dev/null 2>&1
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        RPC_PING_STATUS="OK source=etbinfo broker=$RPC_PING_BROKER_HOST:$RPC_PING_BROKER_PORT"
        return "$STATUS_OK"
    fi
    RPC_PING_STATUS="FAILED rc=$_rc source=etbinfo broker=$RPC_PING_BROKER_HOST:$RPC_PING_BROKER_PORT"
    return "$STATUS_PING_FAILED"
}

maintenance_active()
{
    [ -f "$MAINTENANCE_LOCK" ]
}

do_start()
{
    config_check || return $?
    if [ -z "$RPC_START_CMD" ]; then
        print_kv "start" "NOT_CONFIGURED RPC_START_CMD empty"
        return "$STATUS_CONFIG_ERROR"
    fi
    log_info "starting local RPC server $RPC_SERVER_NAME"
    sh -c "$RPC_START_CMD"
}

do_stop()
{
    config_check || return $?
    if [ -z "$RPC_STOP_CMD" ]; then
        print_kv "stop" "NOT_CONFIGURED RPC_STOP_CMD empty"
        return "$STATUS_CONFIG_ERROR"
    fi
    log_info "stopping local RPC server $RPC_SERVER_NAME"
    sh -c "$RPC_STOP_CMD"
}

do_restart()
{
    config_check || return $?
    if [ -z "$RPC_STOP_CMD" ]; then
        print_kv "stop" "NOT_CONFIGURED RPC_STOP_CMD empty"
        return "$STATUS_CONFIG_ERROR"
    fi
    if [ -z "$RPC_START_CMD" ]; then
        print_kv "start" "NOT_CONFIGURED RPC_START_CMD empty"
        return "$STATUS_CONFIG_ERROR"
    fi
    log_info "restarting local RPC server $RPC_SERVER_NAME"
    sh -c "$RPC_STOP_CMD" || return "$STATUS_CRITICAL"
    sh -c "$RPC_START_CMD"
}

do_status()
{
    config_check || return $?
    _parm=`effective_natural_parm`
    _service_key=`rpc_service_key`

    if maintenance_active; then
        print_kv "maintenance" "ON"
        return "$STATUS_MAINTENANCE"
    fi

    _pid=`local_process_pid`
    [ -n "$_pid" ]
    _proc=$?
    broker_reachable
    _broker=$?
    registration_present
    _reg=$?
    rpc_ping_check "$_broker" "$_reg"
    _ping=$?

    print_kv "natural-parm" "$_parm"
    print_kv "service-key" "$_service_key"
    [ "$_proc" -eq 0 ] && print_kv "process" "RUNNING pid=$_pid parm=$_parm" || print_kv "process" "DOWN parm=$_parm"
    [ "$_broker" -eq 0 ] && print_kv "broker" "REACHABLE" || print_kv "broker" "UNREACHABLE"
    [ "$_reg" -eq 0 ] && print_kv "registration" "PRESENT" || print_kv "registration" "MISSING_OR_UNKNOWN"
    print_kv "rpc-ping" "$RPC_PING_STATUS"

    if [ "$_proc" -ne 0 ]; then print_kv "overall" "CRITICAL"; return "$STATUS_PROCESS_DOWN"; fi
    if [ "$_broker" -ne 0 ]; then print_kv "overall" "CRITICAL"; return "$STATUS_BROKER_UNREACHABLE"; fi
    if [ "$_reg" -ne 0 ]; then print_kv "overall" "CRITICAL"; return "$STATUS_NOT_REGISTERED"; fi
    if [ "$_ping" -eq "$STATUS_WARNING" ]; then print_kv "overall" "WARNING"; return "$STATUS_WARNING"; fi
    if [ "$_ping" -ne 0 ]; then print_kv "overall" "CRITICAL"; return "$STATUS_PING_FAILED"; fi
    print_kv "overall" "OK"
    return "$STATUS_OK"
}

parse_args "$@"

case "$COMMAND" in
    help) usage; exit "$STATUS_OK" ;;
    status) do_status; exit $? ;;
    start) do_start; exit $? ;;
    stop) do_stop; exit $? ;;
    restart) do_restart; exit $? ;;
    config-check) config_check; exit $? ;;
    *) usage; exit "$STATUS_CONFIG_ERROR" ;;
esac
