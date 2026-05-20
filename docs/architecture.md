# Architektur

## HV Broker

In der Hauptverwaltung laeuft der EntireX Broker `ETBSAPSSL` auf einem AIX-Server. Vorgesehen sind ein unverschluesselter Port `10001` und ein SSL-Port `10052`.

Das HV-Skript `bin/hv_broker_ctl.sh` prueft Broker-Prozess, Ports, Broker-Info und die am Broker sichtbaren NL-Registrierungen. Die erwarteten NL-Services werden ueber eine Inventardatei beschrieben.

## NL Natural RPC Server

Jede Niederlassung betreibt lokal einen Natural RPC Server. Das NL-Skript `bin/nl_rpc_ctl.sh` prueft den lokalen Naturalprozess, die Broker-Erreichbarkeit, die eigene Registrierung und einen funktionalen RPC-Ping.

## Broker-Sicht und NL-Sicht

Ein laufender Naturalprozess bedeutet nicht automatisch, dass der RPC-Service am Broker registriert ist. Ebenso beweist eine Broker-Registrierung nicht, dass der lokale Prozess gesund ist oder fachliche RPC-Aufrufe funktionieren.

Der Gesamtstatus eines NL-RPC-Services ist nur OK, wenn alle folgenden Bedingungen erfuellt sind:

1. Der lokale Natural-RPC-Prozess laeuft.
2. Der Broker ist erreichbar.
3. Die passende RPC-Server-Registrierung ist am Broker vorhanden.
4. Ein funktionaler RPC-Ping ist erfolgreich.

## Keine Remote-Starts durch die HV

Version 1 sieht bewusst keinen Remote-Start von NL-RPC-Servern durch die HV vor. Die HV meldet fehlende Registrierungen, die lokale Selbstheilung bleibt Aufgabe der NL.
