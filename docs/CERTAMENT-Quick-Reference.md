# CERTAMENT — Quick Reference Card

> Scheda rapida per chi effettua il deployment sul server cliente.

---

## Installazione rapida

```powershell
# 1. Copiare i file sorgente sul server
# 2. Aprire PowerShell come Amministratore
# 3. Lanciare il wizard:
.\Install-Certament.ps1
```

Il wizard copia i file, scrive `config.json` e registra lo Scheduled Task.

---

## Comandi utili post-installazione

| Azione | Comando |
|--------|---------|
| **Esecuzione manuale** | `cd C:\CERTAMENT; powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\_MAINCertManager.ps1"` |
| **Diagnostica** | `cd C:\CERTAMENT; .\Install-Certament.ps1` → scegliere `d` |
| **Ultimo log** | `Get-ChildItem C:\CERTAMENT\logs\certament_*.log \| Sort LastWriteTime -Desc \| Select -First 1 \| Get-Content` |
| **Stato task** | `Get-ScheduledTask -TaskName CERTAMENT \| Select TaskName, State` |
| **Prossima esecuzione** | `Get-ScheduledTaskInfo -TaskName CERTAMENT \| Select NextRunTime` |
| **Cerca certificato** | `.\tools\Get-CertLocations.ps1 -Thumbprint "<THUMBPRINT>"` |
| **Rimuovi certificato** | `.\tools\Remove-Cert.ps1 -Thumbprint "<THUMBPRINT>"` |

---

## Cosa deve fare il cliente per rinnovare

```
1. Ottenere il nuovo file .pfx dal fornitore del certificato
2. Copiare il file .pfx in C:\_install  (o cartella configurata)
3. Creare un file "password.txt" nella stessa cartella con la password del PFX
4. Attendere l'esecuzione automatica (o chiedere esecuzione manuale)
```

CERTAMENT:
- Trova il PFX → lo valida → lo installa
- Aggiorna BC, SSL, IIS automaticamente
- Archivia il PFX usato, elimina password.txt
- Notifica via Teams

---

## Mappa notifiche

| Situazione | Chi riceve | Cosa dice |
|------------|-----------|-----------|
| Certificato in scadenza, PFX assente | **Cliente** | "Caricare PFX in C:\\_install" |
| PFX presente ma password mancante | **Cliente** | "Creare password.txt" |
| PFX scaduto o non più recente | **Cliente** | "Caricare PFX aggiornato" |
| PFX non leggibile | **Cliente** | "Verificare password" |
| Rinnovo completato con successo | **Interno** | Riepilogo completo |
| Rinnovo completato con errori | **Interno** | Riepilogo + dettagli errore |
| Errore pipeline (BC, IIS, SSL) | **Interno** | Descrizione errore |
| Eccezione non gestita | **Interno** | Stack trace |
| Webhook Customer non funziona | **Interno** | Alert fallback |

---

## Valori config.json da personalizzare per ogni cliente

| Campo | Esempio | Note |
|-------|---------|------|
| `Context.CustomerName` | `"Contoso S.r.l."` | Appare nelle notifiche |
| `Pfx.Path` | `"C:\\_install"` | Dove il cliente deposita il PFX |
| `IIS.SiteName` | `"Microsoft Dynamics 365 Business Central Web Client"` | Case-sensitive! |
| `Webhooks.Customer` | URL Power Automate | Canale Teams del cliente |
| `Webhooks.Internal` | URL Power Automate | Canale Teams interno |
| `NotifyBeforeDays` | `365` | Soglia pre-scadenza in giorni |
| `Heartbeat.Url` | URL Azure Function | Endpoint monitoraggio (opzionale) |

---

## Cosa controllare se qualcosa non va

| Sintomo | Cosa verificare |
|---------|-----------------|
| Il task non parte | `Get-ScheduledTask CERTAMENT` — stato deve essere `Ready` |
| Nessun log generato | Lo script si auto-eleva? Controllare event viewer |
| Notifiche non arrivano | Verificare webhook URL con diagnostica (`Install-Certament.ps1` → `d`) |
| PFX ignorato | Il PFX è davvero più recente del cert attuale? Controllare log |
| Errore "mutex" | Un'altra istanza è in esecuzione, attendere o killare il processo |
| SSL mismatch dopo rinnovo | Eseguire di nuovo manualmente: il repair automatico corregge |
| Istanza BC non viene aggiornata | Ha un certificato diverso? CERTAMENT tocca solo le istanze con lo stesso cert |
