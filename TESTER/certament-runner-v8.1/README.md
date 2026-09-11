# CERTAMENT Scenario Runner V8.1

Runner leggero per Windows PowerShell 5.1 che esegue il vero `C:\CERTAMENT\_MAINCertManager.ps1` sulla VM BC, preparando uno scenario isolato e ripristinando la baseline in modo fail-closed.

## Cosa fa

- Non usa né modifica `C:\_install` per i PFX di scenario.
- Salva il `config.json` reale in un backup DPAPI legato all'utente Windows che avvia il run e lo ripristina byte-per-byte.
- Usa una directory PFX isolata per ogni scenario e il vero meccanismo CERTAMENT `password.txt`.
- Acquisisce baseline di BC, IIS, HTTP.sys, URLACL, certificate store, PFX e Scheduled Task.
- Anche lo scenario `NoOp` usa una preparazione LAB isolata, esegue il vero CERTAMENT su quello stato e non modifica lo stato reale della VM.
- Prepara BC target, IIS 443 e i binding HTTP.sys pertinenti in modo coerente prima del rinnovo.
- Esegue il vero `_MAINCertManager.ps1` come processo Windows PowerShell 5.1 separato, con timeout e log stdout/stderr.
- Verifica post-condizioni reali, non solo l'exit code.
- Ripristina BC, IIS, HTTP.sys, URLACL, certificate store e config; poi confronta il post-restore con la baseline.
- Se il restore non è esatto, il run è `FAIL` e la suite si interrompe.
- Supporta `Recover` per un run interrotto.

## Prerequisiti

Eseguire in **Windows PowerShell 5.1 come amministratore**, su una VM di test isolata. Il target predefinito è `MicrosoftDynamicsNavServer$PROD_NUP2` con binding IIS `*:443:`.

Gate iniziali:

```powershell
.\CertamentScenarioRunner.ps1 -Action Doctor
.\CertamentScenarioRunner.ps1 -Action Preflight
.\CertamentScenarioRunner.ps1 -Action SelfTest
```

Suite:

```powershell
.\CertamentScenarioRunner.ps1 -Action RunSuite -Suite Core
.\CertamentScenarioRunner.ps1 -Action RunSuite -Suite Renewal
.\CertamentScenarioRunner.ps1 -Action RunSuite -Suite All
```

Per eseguire l'intera suite con un solo click dalla root del progetto usare `Run-Certament-Tests.cmd`. Il launcher richiede l'elevazione, avvia Windows PowerShell 5.1 e lascia al runner la preparazione e il ripristino automatico di ogni scenario. Non serve ripristinare manualmente la situazione iniziale tra gli scenari.

Controllo rapido locale o in CI, senza BC/IIS:

```powershell
.\CertamentScenarioRunner.ps1 -Action FastTest
```

`FastTest` verifica helper, catalogo, suite e selezione del PFX in pochi secondi. Le azioni `SelfTest`, `Run` e `RunSuite` restano test di integrazione e richiedono la VM BC.

`SleepScale` vale `1.0` per default. Valori inferiori riducono le attese interne del manager durante i test E2E; usarli solo su una VM stabile.

Singolo scenario:

```powershell
.\CertamentScenarioRunner.ps1 -Action Run -Scenario HappyPath
.\CertamentScenarioRunner.ps1 -Action Run -Scenario HappyPath -SleepScale 0.25
```

Provisioning automatico e reversibile di uno scenario, senza eseguire CERTAMENT:

```powershell
.\CertamentScenarioRunner.ps1 -Action Provision -Scenario HappyPath
```

`Provision` crea certificati e PFX LAB nella directory del run, prepara temporaneamente BC, IIS e HTTP.sys, salva gli snapshot e ripristina subito la baseline. `Run` esegue lo stesso provisioning automaticamente prima del vero CERTAMENT. Il runner non installa Business Central o IIS da zero: questi componenti devono esistere nella VM, mentre la preparazione dei dati e dello stato necessari agli scenari e' automatica.

La validazione SAN usa `IIS.ExpectedDnsNames` se configurato, altrimenti l'hostname del binding HTTPS IIS. Se entrambi sono assenti, CERTAMENT rifiuta il PFX in modo fail-closed invece di usare il certificato precedente come autorita' DNS.

Se `IIS.ExpectedDnsNames` e `HostHeader` sono entrambi presenti ma non coerenti, CERTAMENT considera la configurazione invalida e rifiuta il rinnovo; `ExpectedDnsNames` resta la source of truth e `HostHeader` e' un controllo diagnostico. I wildcard seguono la semantica TLS a una sola label: `*.example.com` copre `bc.example.com`, non `foo.bc.example.com`.

Le prove di failure injection durante aggiornamenti parziali (BC aggiornato + IIS failure, IIS aggiornato + HTTP.sys failure, snapshot failure, archive failure e conflitti di binding/permessi) sono pianificate ma non vengono simulate artificialmente dalla V8.1 corrente. Restano criteri futuri con rollback obbligatorio.

Recovery:

```powershell
.\CertamentScenarioRunner.ps1 -Action Recover -RunPath 'C:\ProgramData\EOS\Certament\ScenarioRunnerV8\runs\<run>'
```

`Recover` richiede lo stesso account Windows che ha creato il backup DPAPI.

## Risultati

`PASS` = comportamento atteso e baseline ripristinata.

`EXPECTED-GAP` = comportamento della release corrente che il runner dimostra essere una carenza nota, per esempio selezione del PFX solo tramite `LastWriteTime` oppure accettazione di un PFX con identità non pertinente.

`FAIL` = errore del runner, restore incompleto, precondizioni errate oppure comportamento CERTAMENT non conforme allo scenario.

## V8.1 endpoint identity review

La validazione dell'identita' del certificato usa questa gerarchia:

1. `IIS.ExpectedDnsNames` configurato;
2. `HostHeader` del binding HTTPS IIS;
3. rifiuto fail-closed se nessuna identita' endpoint e' disponibile.

Il SAN del certificato precedente viene usato come confronto diagnostico, non come autorita' DNS assoluta. Gli scenari `EndpointIdentityMissing` e `EndpointIdentityConfigured` dimostrano rispettivamente il rifiuto fail-closed e l'accettazione di un nuovo certificato coerente con l'endpoint anche quando il certificato precedente ha un SAN legacy.

Ultima verifica runtime sulla VM:

- Core: 10/10 PASS, 0 EXPECTED-GAP, 0 FAIL;
- Renewal: 4/4 PASS, 0 EXPECTED-GAP, 0 FAIL;
- baseline ripristinata in ogni scenario;
- `RestoreDrift` vuoto in ogni scenario.

Revisione wildcard e conflitti endpoint:

- wildcard TLS a una sola label verificato con `EndpointWildcard` e `FastTest`;
- `*.example.com` accetta `bc.example.com` ma non `foo.bc.example.com`;
- conflitto tra `ExpectedDnsNames` e `HostHeader` rifiutato fail-closed;
- failure injection su aggiornamenti parziali e rollback forzato restano il prossimo scope di test.

La pipeline runtime ora interrompe il gruppo dopo errori BC/SSL/URLACL, richiede la persistenza dello snapshot prima dell'update BC, non archivia il PFX ne' elimina `password.txt` dopo errori e mantiene le verifiche IIS scoped ai binding del certificate-group. Il test dedicato con due binding IIS appartenenti a certificati diversi e le failure injection controllate BC/IIS/HTTP.sys/archive restano da implementare.

Revisione transazionale corrente: Core 10/10 PASS e Renewal 5/5 PASS, con baseline ripristinata e `RestoreDrift` vuoto in tutti gli scenari verificati. Il commit strutturale e' `235d399`.

## Artefatti

I run vengono salvati sotto `C:\ProgramData\EOS\Certament\ScenarioRunnerV8\runs\...` con baseline, prepared, post-run, post-restore, drift, log CERTAMENT e log netsh.

## Limite di verifica

La sandbox corrente non dispone di Windows PowerShell 5.1 + IIS + BC; quindi il pacchetto è stato sottoposto a revisione statica, confronto con il sorgente CERTAMENT release e coerenza con la VM analizzata. La verifica runtime finale deve avvenire sulla VM.
