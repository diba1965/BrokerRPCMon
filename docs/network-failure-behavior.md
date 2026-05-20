# Verhalten bei Netzwerkausfall

BrokerRPCMon unterscheidet zwischen fehlender Registrierung, nicht erreichbarem Broker und fehlgeschlagenem RPC-Ping.

Wenn der Broker von der NL aus nicht erreichbar ist, fuehrt der Watchdog keinen aggressiven Restart aus. Laeuft der Naturalprozess weiter, lautet der Zustand `WAITING_FOR_BROKER`; die NL wartet auf Wiederkehr der Verbindung.

Wenn die Registrierung fehlt und der Broker erreichbar ist, darf die NL lokal einen Restart bzw. ein Re-Register anstossen. Wenn die Registrierung fehlt und der Broker nicht erreichbar ist, wird gewartet.

Nach Wiederkehr des Netzwerks prueft die NL zuerst die Broker-Erreichbarkeit, danach die Registrierung. Fehlt die Registrierung, wird lokal neu gestartet bzw. re-registriert. Ist die Registrierung vorhanden, folgt der funktionale RPC-Ping.

Ein Netzwerkfehler ist damit kein RPC-Fehler. Erst wenn Broker-Erreichbarkeit und Registrierung vorhanden sind, aber der Ping fehlschlaegt, wird von einem RPC-Problem ausgegangen.
