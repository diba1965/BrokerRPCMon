# Betrieb

## Broker starten

`hv_broker_ctl.sh start` nutzt `START_BROKER_CMD` aus der HV-Konfiguration. Danach wartet das Skript auf die Broker-Ports und prueft Broker-Info.

## Broker stoppen

`hv_broker_ctl.sh stop` nutzt `STOP_BROKER_CMD` und wartet auf das Schliessen des Broker-Ports. NL-RPC-Server werden nicht remote gestoppt.

## Broker neu starten

`hv_broker_ctl.sh restart` protokolliert den Restart, stoppt und startet den Broker und vergleicht anschliessend die sichtbaren NL-Registrierungen mit der Inventardatei. Fehlende NLs werden gemeldet.

## NL Watchdog

`nl_rpc_ctl.sh watchdog` fuehrt einen Entscheidungszyklus aus. Bei nicht erreichbarem Broker wird kein Restart erzwungen. Bei erreichbarem Broker und fehlender Registrierung darf lokal neu gestartet bzw. re-registriert werden.

## Wartungsmodus

`nl_rpc_ctl.sh maintenance-on` setzt die Wartungsdatei. Solange sie existiert, fuehrt der Watchdog keine Restart-Aktionen aus und meldet `MAINTENANCE`.

`nl_rpc_ctl.sh maintenance-off` entfernt die Wartungsdatei.

## Typische Fehlerbilder

```text
Naturalprozess laeuft, Broker nicht erreichbar:
  WAITING_FOR_BROKER, keine Restart-Aktion.

Naturalprozess laeuft, Registrierung fehlt, Broker erreichbar:
  lokaler Restart/Re-Register innerhalb des Restart-Limits.

Registrierung vorhanden, Ping schlaegt fehl:
  lokales RPC-Problem, Restart-Limit beachten.

HV sieht NL-Registrierung nicht:
  HV meldet fehlende NL, startet aber keine NL remote.
```
