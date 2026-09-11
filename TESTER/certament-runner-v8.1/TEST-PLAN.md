# Test plan V8.1

1. `FastTest` e' il gate rapido locale/CI; non richiede BC, IIS o privilegi amministrativi.
2. `Doctor`, `Preflight`, `SelfTest` sono gate della VM di integrazione.
3. Gli scenari E2E possono usare `-SleepScale 0.25` sulla VM stabile; il default `1.0` mantiene le attese normali.
4. Ogni scenario E2E acquisisce una baseline prima di qualunque mutazione.
5. Il runner prepara uno stato coerente, quindi esegue il vero `_MAINCertManager.ps1`.
6. Acquisisce uno snapshot post-run e controlla le post-condizioni dello scenario.
7. Il restore avviene sempre in `finally`.
8. Dopo il restore viene acquisito un secondo snapshot e confrontato con la baseline; qualunque drift = `FAIL`.
9. I casi negativi richiedono errore CERTAMENT e assenza di drift runtime. I casi che dimostrano gap noti sono `EXPECTED-GAP`.
10. I rinnovi richiedono esplicitamente thumbprint finale BC, stato Running, IIS 443, HTTP.sys e private key del nuovo certificato.
11. `MultiGroup` controlla anche esplicitamente `PROD_NUP` oltre al target `PROD_NUP2`.
12. `RestartPolicy` verifica che l'output non contenga il riavvio IIS quando la policy e' disabilitata.

## Failure injection fuori scope V8.1

Sono pianificati scenari dedicati per BC aggiornato + IIS failure, IIS aggiornato + HTTP.sys failure, snapshot failure, archive failure e conflitti di binding/permessi. Non sono ancora implementati; quando verranno aggiunti dovranno verificare rollback e `RestoreDrift` prima di classificare il risultato.

## Limite dichiarato

La sandbox corrente non può eseguire realmente Windows PowerShell 5.1, IIS e Business Central. Il runtime finale deve essere eseguito sulla VM; il runner è progettato affinché eventuali errori siano osservabili nei log e, soprattutto, affinché il restore fallito porti a `FAIL` invece di mascherare il problema.
