# BrokerRPCMon logging helpers

: ${LOG_LEVEL:=INFO}
: ${COMPONENT:=brokerrpcmon}

log_line()
{
    _level=$1
    shift
    _message=$*
    _ts=`date '+%Y-%m-%d %H:%M:%S' 2>/dev/null`
    if [ -z "$_ts" ]; then
        _ts=unknown-time
    fi
    printf '%s %s %s %s\n' "$_ts" "$_level" "$COMPONENT" "$_message"
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

log_debug()
{
    case "$LOG_LEVEL" in
        DEBUG|debug)
            log_line DEBUG "$@"
            ;;
    esac
}
