# BrokerRPCMon

BrokerRPCMon stellt portable Steuer- und Ueberwachungsgerueste fuer ein EntireX Broker / Natural RPC Server Umfeld bereit.

Die Entwicklung erfolgt auf RHEL 9.6, der Betrieb ist fuer AIX vorgesehen. Die Shell-Skripte sind deshalb bewusst POSIX-/ksh-nah gehalten: keine Bash-Arrays, kein `[[ ... ]]`, keine Prozesssubstitution und keine Abhaengigkeit von `systemctl`.

## Rollen

Die HV ueberwacht und koordiniert den EntireX Broker `ETBSAPSSL` sowie die dort registrierten NL-RPC-Services. Sie startet in Version 1 keine NL-RPC-Server remote.

Die NL ueberwacht lokal den Natural-RPC-Prozess, die Broker-Erreichbarkeit, die eigene Broker-Registrierung und einen funktionalen RPC-Ping. Lokale Selbstheilung erfolgt nur auf der NL-Seite.

## Struktur

```text
bin/      Steuer-Skripte fuer HV und NL
conf/     Beispielkonfigurationen
lib/      Gemeinsame portable Hilfsfunktionen
docs/     Architektur- und Betriebshinweise
test/     Smoke-Test und Mock-Kommandos
```

## Grundkommandos

```sh
bin/hv_broker_ctl.sh help
bin/hv_broker_ctl.sh -c /path/to/hv_broker.conf status

bin/nl_rpc_ctl.sh help
bin/nl_rpc_ctl.sh -c /path/to/nl_rpc.conf watchdog
```

Die Beispielkonfigurationen unter `conf/*.example` muessen fuer die Zielumgebung kopiert und angepasst werden. Pfade, Start-/Stop-Kommandos und Tool-Binaries bleiben konfigurierbar.
