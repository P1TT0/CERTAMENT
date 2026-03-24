# CERTAMENT — Guida al Deployment

## Cos'è CERTAMENT

**CERTAMENT** è uno strumento automatizzato per la gestione del ciclo di vita dei certificati SSL su server **Microsoft Dynamics 365 Business Central**.

Gira come **Scheduled Task giornaliero** su ogni server cliente e si occupa di:

1. Rilevare certificati in scadenza
2. Installare automaticamente il nuovo certificato PFX
3. Aggiornare le istanze Business Central
4. Aggiornare i binding IIS
5. Riparare automaticamente i binding SSL (netsh) e le URL ACL
6. Notificare il cliente e il team interno via Microsoft Teams

> **Obiettivo**: zero intervento manuale. Il cliente deposita il file `.pfx` + `password.txt` e CERTAMENT fa il resto.

---

## Architettura

```
Server Cliente
├── C:\CERTAMENT\                    ← Installazione CERTAMENT
│   ├── _MAINCertManager.ps1        ← Script principale (orchestratore)
│   ├── Install-Certament.ps1       ← Wizard di installazione interattivo
│   ├── config.json                 ← Configurazione specifica per il cliente
│   ├── modules\                    ← Moduli PowerShell
│   │   ├── Get-BCThumbprint.psm1   (lettura thumbprint da istanze BC)
│   │   ├── Get-CertDetails.psm1    (dettagli certificato dallo store)
│   │   ├── Get-PfxFile.psm1        (cerca il PFX più recente nella cartella)
│   │   ├── Install-PfxCert.psm1    (importa PFX nello store LocalMachine\My)
│   │   ├── Update-BCServiceCert.psm1 (aggiorna thumbprint nelle istanze BC)
│   │   ├── Update-IISBinding.psm1  (aggiorna binding HTTPS in IIS)
│   │   ├── Test-BCWebServices.psm1 (verifica endpoint OData/SOAP + SSL)
│   │   └── Send-Notification.psm1  (invio notifiche via webhook Teams)
│   ├── tools\                      ← Utilità manuali
│   │   ├── Get-CertLocations.ps1   (cerca un cert in tutti gli store)
│   │   └── Remove-Cert.ps1         (rimuove un cert da tutti gli store)
│   └── logs\                       ← Log delle esecuzioni
│       └── snapshots\              ← Snapshot JSON dei binding (safety net)
│
├── C:\_install\                    ← Cartella PFX (configurabile)
│   ├── nuovo_certificato.pfx       ← PFX depositato dal cliente
│   ├── password.txt                ← Password del PFX (eliminato dopo uso)
│   └── installed\                  ← PFX archiviati dopo l'installazione
│
├── IIS                             ← Sito "Microsoft Dynamics 365 Business Central Web Client"
├── Business Central Server          ← Istanze BC (PROD, PROD_NUP, PROD_NUP2, ecc.)
└── Scheduled Task "CERTAMENT"       ← Esecuzione giornaliera alle 06:00
```

---

## Prerequisiti

| Requisito | Dettaglio |
|-----------|-----------|
| **Sistema operativo** | Windows Server 2016+ |
| **PowerShell** | 5.1 (incluso in Windows) — lo script usa `powershell.exe` |
| **Privilegi** | Amministratore locale (lo script si auto-eleva se necessario) |
| **IIS** | Installato con modulo `Microsoft.Web.Administration.dll` |
| **Business Central** | Almeno una versione installata con `Microsoft.Dynamics.Nav.Management.psm1` |
| **Rete** | Accesso HTTPS verso i webhook Power Automate (Teams) |

---

## Installazione (passo-passo)

### 1. Copiare i file sorgente sul server

Copiare l'intera cartella del progetto CERTAMENT sul server (ad es. in una cartella temporanea).

### 2. Lanciare il wizard

```powershell
# Da PowerShell come Amministratore
.\Install-Certament.ps1
```

Il wizard interattivo chiede:

| Passo | Domanda | Default | Note |
|-------|---------|---------|------|
| 1 | Percorso installazione | `C:\CERTAMENT` | Dove verranno copiati tutti i file |
| 1 | Nome cliente | hostname | Usato nelle notifiche e negli heartbeat |
| 2 | Cartella PFX | `C:\_install` | Dove il cliente depositerà i file `.pfx` |
| 2 | Password PFX fallback | (vuoto) | Alternativa a `password.txt` |
| 3 | Nome sito IIS | `Microsoft Dynamics 365 Business Central Web Client` | Case-sensitive |
| 3 | Riavvio IIS dopo update | Sì | Consigliato |
| 4 | Webhook Customer | (vuoto) | URL Power Automate per notifiche al cliente |
| 4 | Webhook Internal | (vuoto) | URL Power Automate per notifiche interne |
| 4 | Heartbeat Azure | Sì | Consigliato se endpoint disponibile |
| 4 | Soglia scadenza (giorni) | 30 | Quando iniziare ad avvisare/rinnovare |
| 5 | Scheduled Task | Sì | Registra task giornaliero |
| 5 | Orario esecuzione | 06:00 | Orario di esecuzione giornaliera |

### 3. Verifica post-installazione

Il wizard include una modalità **diagnostica** che verifica:

- File di installazione presenti
- `config.json` valido e completo
- Moduli PowerShell importabili
- Webhook raggiungibili (invio test reale)
- Heartbeat Azure raggiungibile
- Scheduled Task registrato e attivo
- Sito IIS trovato con binding HTTPS
- Istanze BC trovate con certificati configurati
- Stato scadenza certificati

```powershell
# Dalla cartella di installazione
.\Install-Certament.ps1
# Scegliere "d" per Diagnostica
```

---

## Configurazione (`config.json`)

```json
{
  "Context": {
    "CustomerName": "NomeCliente"          // Tag identificativo nelle notifiche
  },
  "Pfx": {
    "Path": "C:\\_install",                // Cartella dove depositare il PFX
    "Password": ""                         // Fallback se manca password.txt
  },
  "BusinessCentral": {
    "UseLatestModule": true                // Usa la versione BC più recente
  },
  "IIS": {
    "SiteName": "Microsoft Dynamics 365 Business Central Web Client",
    "RestartAfterUpdate": true             // iisreset dopo aggiornamento binding
  },
  "Logging": {
    "Enabled": true,
    "Path": "logs",                        // Sotto-cartella per i log
    "RetentionDays": 90                    // Pulizia automatica log vecchi
  },
  "Notifications": {
    "EnableWebhook": true,                 // Master switch notifiche
    "Webhooks": {
      "Customer": "<URL_WEBHOOK_CUSTOMER>", // Canale Teams del cliente
      "Internal": "<URL_WEBHOOK_INTERNO>"   // Canale Teams interno EOS
    },
    "CertificateExpiry": {
      "NotifyBeforeDays": 365,             // Soglia in giorni per avvio rinnovo
      "EnableCustomerNotification": true   // Abilita notifiche al cliente
    }
  },
  "Heartbeat": {
    "Enabled": true,                       // Abilita heartbeat verso Azure
    "Url": "<URL_AZURE_HEARTBEAT>",        // Endpoint Azure Function / Power Automate
    "TimeoutSec": 10,                      // Timeout chiamata heartbeat
    "NotifyInternalOnFailure": true        // Avvisa interno se heartbeat fallisce
  }
}
```

### Parametri chiave

| Parametro | Impatto | Valore tipico |
|-----------|---------|---------------|
| `NotifyBeforeDays` | Quanti giorni prima della scadenza iniziare il processo | 30–365 |
| `EnableCustomerNotification` | Se `false`, le notifiche al cliente sono soppresse | `true` |
| `EnableWebhook` | Se `false`, tutte le notifiche sono disabilitate | `true` |

---

## Come funziona il rinnovo

### Il cliente deve:

1. **Depositare il file `.pfx`** nella cartella configurata (es. `C:\_install`)
2. **Creare un file `password.txt`** nella stessa cartella con la password del PFX
3. Attendere l'esecuzione giornaliera (o chiedere un'esecuzione manuale)

### CERTAMENT farà:

1. Trovare il PFX più recente nella cartella
2. Validarlo (non scaduto, più recente del certificato attuale)
3. Installarlo nello store `LocalMachine\My`
4. Aggiornare ogni istanza BC che usava il vecchio certificato (+ restart servizio)
5. Riparare tutti i binding SSL porta-per-porta (`netsh http sslcert`)
6. Riparare le URL ACL se necessario (`netsh http urlacl`)
7. Aggiornare il binding HTTPS del sito IIS
8. Archiviare il PFX in `installed/` e cancellare `password.txt`
9. Inviare notifica di completamento

### Se il PFX non è disponibile:

CERTAMENT invia una **notifica al cliente** via Teams chiedendo di caricare il PFX, e riproverà al prossimo ciclo.

---

## Sistema di notifiche

CERTAMENT invia notifiche tramite **Adaptive Cards** su Microsoft Teams via webhook Power Automate.

### Destinatari

| Target | Quando | Cosa riceve |
|--------|--------|-------------|
| **Customer** | Certificato in scadenza, PFX mancante/scaduto/non valido, password mancante | Istruzioni su cosa fare |
| **Internal** | Errori pipeline, aggiornamento completato, fallimenti webhook, eccezioni | Dettagli tecnici per il team |

### Fallback

Se il webhook **Customer** non è configurato o fallisce, CERTAMENT:
1. Invia un heartbeat `NotificationFailed`
2. Invia una notifica **Internal** di alert ("notifica Customer non consegnata")

---

## Heartbeat Azure (opzionale)

CERTAMENT invia un payload JSON strutturato a un endpoint Azure ad ogni esecuzione:

```json
{
  "tool": "CERTAMENT",
  "customer": "NomeCliente",
  "server": "HOSTNAME",
  "status": "Started|Healthy|AwaitingPfx|Completed|Error|...",
  "stage": "MainStart|NoActionNeeded|PfxMissing|MainEnd|...",
  "detail": "Descrizione testuale",
  "timestamp": "2026-03-24T06:00:00.000+01:00"
}
```

### Stati possibili

| Status | Stage | Significato |
|--------|-------|-------------|
| `Started` | `MainStart` | Esecuzione avviata |
| `Healthy` | `NoActionNeeded` | Tutti i certificati validi, nessuna azione |
| `AwaitingPfx` | `PfxMissing` | Nessun PFX nella cartella |
| `AwaitingPfx` | `PfxNoPassword` | PFX trovato ma manca la password |
| `AwaitingPfx` | `PfxUnreadable` | PFX non leggibile (password errata?) |
| `AwaitingPfx` | `PfxExpired` | PFX contiene un certificato già scaduto |
| `AwaitingPfx` | `PfxNotNewer` | PFX non più recente del cert attuale |
| `Error` | `ReadBCThumbprint` | Nessun certificato configurato in BC |
| `Error` | `InstallPfx` | Installazione PFX fallita |
| `Error` | `UnhandledException` | Eccezione non gestita |
| `CompletedWithWarnings` | `MainEnd` | Completato ma con errori parziali |
| `Completed` | `MainEnd` | Completato con successo |

### Utilizzo lato Azure

L'heartbeat serve per:
- **Monitorare** che CERTAMENT stia girando regolarmente su ogni server
- **Rilevare** server "silenti" (nessun heartbeat = task non in esecuzione)
- **Dashboard** centralizzata stato certificati su tutti i clienti

---

## Meccanismo di self-healing SSL

CERTAMENT gestisce i certificati SSL su **tre livelli** indipendenti:

```
Livello 1: netsh http sslcert   ← Binding SSL porta-per-porta (es. 0.0.0.0:443, :7065, :7067, :7068)
Livello 2: netsh http urlacl    ← Reservations URL ACL per le istanze BC
Livello 3: IIS Bindings         ← Binding HTTPS nel sito IIS
```

### Come funziona

1. **Prima** dell'aggiornamento, CERTAMENT fotografa lo stato di tutti e tre i livelli (snapshot)
2. Lo snapshot viene salvato su disco in formato JSON (`logs/snapshots/`)
3. **Dopo** l'aggiornamento BC, verifica ogni livello
4. Se qualcosa è rotto, **ripara automaticamente** da snapshot
5. Se la riparazione fallisce, **notifica** il team interno

### Perché serve

L'aggiornamento del certificato in Business Central (`Set-NAVServerConfiguration` + restart) può causare effetti collaterali:
- I binding SSL di `netsh` possono essere rimossi o corrotti durante il restart del servizio BC
- Le URL ACL possono essere eliminate
- In rari casi il binding IIS può essere alterato

Lo snapshot + repair garantisce che tutto venga ripristinato esattamente come prima, ma con il nuovo certificato.

---

## Gestione multi-certificato

CERTAMENT supporta scenari dove diverse istanze BC usano **certificati diversi**:

- Istanza `PROD_NUP` → Certificato A (scadenza 2029)
- Istanza `PROD_NUP2` → Certificato B (scadenza 2026)

In questo caso:
- Solo il Certificato B viene rinnovato
- Le istanze con Certificato A **non vengono toccate**
- I test post-aggiornamento verificano **solo** le istanze rinnovate

---

## Sicurezza

| Aspetto | Dettaglio |
|---------|-----------|
| **Privilegi** | Richiede Amministratore (auto-elevazione) |
| **Mutex** | Un solo processo alla volta (mutex globale) |
| **Password PFX** | Letta da `password.txt`, che viene **eliminato** dopo l'uso |
| **Password config** | Fallback opzionale nel `config.json` (per automazione completa) |
| **Certificato PFX** | Archiviato in `installed/` dopo l'installazione (non eliminato) |
| **Log** | Transcript completo di ogni esecuzione con retention configurabile |

---

## Struttura file

```
C:\CERTAMENT\
│
├── _MAINCertManager.ps1       Script principale — NON MODIFICARE
├── Install-Certament.ps1      Wizard installazione/diagnostica
├── config.json                Configurazione cliente — PERSONALIZZARE
├── config.example.json        Template di riferimento
│
├── modules\
│   ├── Get-BCThumbprint.psm1      Mappa thumbprint → istanze BC
│   ├── Get-CertDetails.psm1       Dettagli certificato (scadenza, SAN, ecc.)
│   ├── Get-PfxFile.psm1           Trova il PFX più recente
│   ├── Install-PfxCert.psm1       Importa PFX nello store
│   ├── Update-BCServiceCert.psm1  Aggiorna config BC + restart
│   ├── Update-IISBinding.psm1     Aggiorna binding HTTPS IIS
│   ├── Test-BCWebServices.psm1    Verifica endpoint web service + SSL
│   └── Send-Notification.psm1     Invio notifiche Teams via webhook
│
├── tools\
│   ├── Get-CertLocations.ps1      Cerca un certificato in tutti gli store
│   └── Remove-Cert.ps1            Rimuove un certificato da tutti gli store
│
└── logs\
    ├── certament_20260324_060000.log   Log esecuzione
    └── snapshots\
        └── snapshot_20260324_060015_0D75AB65.json   Snapshot binding
```

---

## Troubleshooting

### Il task non parte

```powershell
# Verificare lo stato del task
Get-ScheduledTask -TaskName "CERTAMENT" | Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName "CERTAMENT" | Select-Object LastRunTime, LastTaskResult, NextRunTime
```

### Esecuzione manuale

```powershell
# Come Amministratore, dalla cartella di installazione
cd C:\CERTAMENT
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\_MAINCertManager.ps1"
```

### Consultare i log

```powershell
# Ultimo log
Get-ChildItem C:\CERTAMENT\logs\certament_*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content
```

### Verificare dove si trova un certificato

```powershell
# Dalla cartella tools
.\tools\Get-CertLocations.ps1 -Thumbprint "A5891105744CD279BAB93194C2A5032CD59AEB62"
```

### Diagnostica completa

```powershell
cd C:\CERTAMENT
.\Install-Certament.ps1
# Scegliere "d" per Diagnostica
```

---

## Checklist deployment

- [ ] File copiati sul server (o wizard eseguito)
- [ ] `config.json` personalizzato con:
  - [ ] `Context.CustomerName` impostato
  - [ ] `Pfx.Path` verificato e cartella esistente
  - [ ] `IIS.SiteName` corretto (case-sensitive)
  - [ ] Webhook Customer configurato (URL Power Automate)
  - [ ] Webhook Internal configurato (URL Power Automate)
  - [ ] `NotifyBeforeDays` impostato (tipico: 30-365)
- [ ] Scheduled Task `CERTAMENT` registrato e stato `Ready`
- [ ] Diagnostica eseguita con risultato positivo
- [ ] Esecuzione manuale di test completata con successo
- [ ] Cliente informato su dove depositare il PFX (`C:\_install` + `password.txt`)
