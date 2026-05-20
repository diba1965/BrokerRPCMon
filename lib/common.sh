# BrokerRPCMon common helpers

load_config()
{
    _file=$1
    if [ -z "$_file" ]; then
        die "configuration file not specified" "$STATUS_CONFIG_ERROR"
    fi
    check_readable_file "$_file" || die "configuration file not readable: $_file" "$STATUS_CONFIG_ERROR"
    . "$_file"
}

require_command()
{
    _cmd=$1
    if [ -z "$_cmd" ]; then
        return 1
    fi
    command -v "$_cmd" >/dev/null 2>&1
}

check_readable_file()
{
    _file=$1
    [ -n "$_file" ] && [ -f "$_file" ] && [ -r "$_file" ]
}

check_writable_dir()
{
    _dir=$1
    [ -n "$_dir" ] && [ -d "$_dir" ] && [ -w "$_dir" ]
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

print_kv()
{
    printf '%-28s %s\n' "$1:" "$2"
}

die()
{
    _message=$1
    _code=$2
    if [ -z "$_code" ]; then
        _code=1
    fi
    if command -v log_error >/dev/null 2>&1; then
        log_error "$_message"
    else
        printf '%s\n' "$_message" >&2
    fi
    exit "$_code"
}

usage_common()
{
    printf 'Usage: %s [-c config-file] command\n' "$1"
    printf 'Use "%s help" for command details.\n' "$1"
}
