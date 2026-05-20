# Statusmodell

## Exit-Codes

```text
0 STATUS_OK
1 STATUS_WARNING
2 STATUS_CRITICAL
3 STATUS_CONFIG_ERROR
4 STATUS_BROKER_UNREACHABLE
5 STATUS_NOT_REGISTERED
6 STATUS_PING_FAILED
7 STATUS_PROCESS_DOWN
8 STATUS_MAINTENANCE
9 STATUS_UNKNOWN
```

## Bewertungsmatrix NL

```text
Process  Broker  Registration  Ping  Status
up       up      yes           ok    OK
up       down    unknown       n/a   WAITING_FOR_BROKER
down     down    unknown       n/a   PROCESS_DOWN + BROKER_UNREACHABLE
down     up      no/unknown    n/a   PROCESS_DOWN
up       up      no            n/a   NOT_REGISTERED
up       up      yes           fail  PING_FAILED
any      any     any           any   MAINTENANCE, wenn Wartungslock aktiv
```

Die zentrale Regel lautet: Nur die Kombination aus lokalem Prozess, Broker-Erreichbarkeit, Broker-Registrierung und funktionalem RPC-Ping ergibt einen OK-Status.
