# BrokerRPCMon portability helpers for RHEL/AIX style systems

get_hostname()
{
    hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown\n'
}

get_timestamp()
{
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'unknown-time\n'
}

check_tcp_port()
{
    _host=$1
    _port=$2
    _timeout=$3
    if [ -z "$_timeout" ]; then
        _timeout=5
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

find_process()
{
    _pattern=$1
    if [ -z "$_pattern" ]; then
        return 1
    fi
    ps -ef 2>/dev/null | grep "$_pattern" | grep -v grep >/dev/null 2>&1
}

sleep_seconds()
{
    _seconds=$1
    if ! is_number "$_seconds"; then
        _seconds=1
    fi
    sleep "$_seconds"
}
