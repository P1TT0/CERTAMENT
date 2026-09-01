# CERTAMENT -- Roadmap Esecutiva

## Obiettivo

Trasformare CERTAMENT da tool locale funzionante a servizio gestibile, distribuibile e osservabile, senza introdurre complessita' non necessaria troppo presto.

La priorita' non e' costruire subito tutta la piattaforma runbook multi-tenant. La priorita' e' mettere ordine operativo attorno al prodotto esistente.

---

## Priorita' strategica

Ordine consigliato di esecuzione:

1. stabilita' del runtime locale
2. CI minima e artifact versionati
3. CD controllata con ring e inventory
4. dashboard e monitoraggio operativo
5. self-update controllato con rollback
6. eventuale evoluzione futura a thin executor + control plane centrale

---

## Fase 0 -- Baseline di prodotto

### Priorita': P0

### Obiettivo

Fare in modo che ogni installazione sia identificabile, verificabile e supportabile.

### Task

| ID | Task | Priorita' | Effort | Output atteso |
|---|---|---|---|---|
| F0-01 | Aggiungere version tracking nel runtime | P0 | Basso | versione esposta in log, heartbeat, output |
| F0-02 | Definire policy di release | P0 | Basso | schema versioning e naming release |
| F0-03 | Standardizzare artifact ZIP | P0 | Basso | pacchetto unico deployabile |
| F0-04 | Definire checklist smoke test manuale | P0 | Basso | test minimo post-deploy |
| F0-05 | Mappare server/clienti esistenti | P0 | Basso | primo inventory centralizzato |

### Exit criteria

- ogni release ha una versione chiara
- ogni server noto ha una entry in inventory
- esiste un artifact standard da distribuire

---

## Fase 1 -- CI minima ma reale

### Priorita': P0

### Obiettivo

Bloccare regressioni banali prima del deploy.

### Task

| ID | Task | Priorita' | Effort | Output atteso |
|---|---|---|---|---|
| F1-01 | Aggiungere pipeline CI | P0 | Basso | validazione automatica su push/PR |
| F1-02 | Eseguire syntax check PowerShell 5.1 | P0 | Basso | rilevazione errori parser reali |
| F1-03 | Integrare PSScriptAnalyzer | P0 | Basso | lint coerente |
| F1-04 | Creare primi test Pester | P0 | Medio | coverage minima su moduli critici |
| F1-05 | Pubblicare artifact ZIP | P0 | Basso | pacchetto versionato in pipeline |
| F1-06 | Facoltativo: code signing | P1 | Medio | artifact/script firmati |

### Moduli da testare per primi

1. `Get-PfxFile.psm1`
2. `Send-Notification.psm1`
3. `Install-PfxCert.psm1`
4. `Update-IISBinding.psm1`

### Exit criteria

- nessuna release senza CI verde
- artifact generato automaticamente
- almeno 3-4 test Pester iniziali presenti

---

## Fase 2 -- CD controllata

### Priorita': P0

### Obiettivo

Distribuire senza copy-paste manuale indiscriminato.

### Task

| ID | Task | Priorita' | Effort | Output atteso |
|---|---|---|---|---|
| F2-01 | Creare customer manifest | P0 | Basso | elenco target centralizzato |
| F2-02 | Definire ring di rollout | P0 | Basso | sequenza deploy controllata |
| F2-03 | Creare pipeline CD | P0 | Medio | deploy automatizzabile |
| F2-04 | Implementare gate manuale dopo Ring 0 | P0 | Basso | stop facile se qualcosa rompe |
| F2-05 | Definire rollback di versione | P0 | Medio | ritorno rapido release precedente |
| F2-06 | Salvare esito deploy per target | P1 | Medio | audit e troubleshooting |

### Ring consigliati

- Ring 0: laboratorio interno EOS
- Ring 1: 1 cliente pilota
- Ring 2: pochi clienti controllati
- Ring 3: rollout largo

### Exit criteria

- esiste una pipeline che distribuisce almeno a Ring 0
- esiste un manifest con target reali o pilota
- il rollback a versione precedente e' definito

---

## Fase 3 -- Observability e operations

### Priorita': P1

### Obiettivo

Sapere cosa gira, dove gira e in che stato si trova.

### Task

| ID | Task | Priorita' | Effort | Output atteso |
|---|---|---|---|---|
| F3-01 | Consolidare endpoint heartbeat | P1 | Basso | ingest stabile |
| F3-02 | Salvare heartbeat in storage/queryable backend | P1 | Medio | stato consultabile |
| F3-03 | Dashboard server/clienti/versioni | P1 | Medio | vista operativa centralizzata |
| F3-04 | Alert su heartbeat mancanti | P1 | Medio | detection guasti silenziosi |
| F3-05 | Alert su errori ricorrenti | P1 | Medio | triage piu' rapido |
| F3-06 | Contratto response heartbeat con target version | P1 | Medio | desired state lato server |

### KPI minimi utili

- ultimo heartbeat per server
- esito ultima esecuzione
- versione installata
- giorni residui al prossimo certificato critico

### Exit criteria

- un operatore puo' vedere in pochi minuti chi e' sano e chi no

---

## Fase 4 -- Self-update controllato

### Priorita': P2

### Obiettivo

Permettere al server di aggiornare il runtime in autonomia, in modo sicuro e rollbackabile, senza introdurre infrastruttura remota pesante.

### Task

| ID | Task | Priorita' | Effort | Output atteso |
|---|---|---|---|---|
| F4-01 | Definire manifest di update | P2 | Basso | target version, URL, hash |
| F4-02 | Creare updater locale dedicato | P2 | Medio | script di update isolato |
| F4-03 | Implementare backup versione corrente | P2 | Medio | base per rollback |
| F4-04 | Implementare rollback automatico | P2 | Medio | recovery su update fallito |
| F4-05 | Validare update su Ring 0 | P2 | Medio | prova end-to-end controllata |

### Domande a cui questa fase deve rispondere

- il server scarica solo artifact validi?
- il rollback ripristina davvero il runtime precedente?
- il `config.json` resta integro?
- il modello a pull e' sufficiente per la maggior parte dei clienti?

### Exit criteria

- esiste un self-update affidabile validato su Ring 0

---

## Fase 5 -- Evoluzione a control plane centrale

### Priorita': P3

### Obiettivo

Ridurre l'esposizione del codice e centralizzare la logica di valore.

### Task

| ID | Task | Priorita' | Effort | Output atteso |
|---|---|---|---|---|
| F5-01 | Definire protocollo executor <-> control plane | P3 | Alto | contratto API/manifest |
| F5-02 | Separare core logico e wrapper esecutivi | P3 | Alto | architettura piu' modulare |
| F5-03 | Spostare policy e orchestration lato EOS | P3 | Alto | brain centrale |
| F5-04 | Introdurre token/manifest firmati | P3 | Alto | trust model piu' robusto |
| F5-05 | Ridurre codice sensibile lato cliente | P3 | Alto | migliore protezione IP |

### Exit criteria

- il cliente esegue solo il minimo necessario localmente
- la logica di orchestrazione non e' piu' interamente sul server cliente

---

## Backlog tecnico trasversale

Task utili indipendentemente dalla fase:

| ID | Task | Priorita' |
|---|---|---|
| X-01 | Config schema validation | P1 |
| X-02 | DPAPI per secret locali non transitori | P1 |
| X-03 | Script di self-update controllato | P0 |
| X-04 | Code signing | P1 |
| X-05 | Rate limiting notifiche customer | P1 |
| X-06 | Migliorare output machine-readable | P1 |
| X-07 | Standardizzare release notes | P1 |

---

## Sequenza raccomandata immediata

Se devi decidere cosa fare adesso, l'ordine migliore e' questo:

1. completare CI
2. creare manifest clienti
3. far funzionare CD verso Ring 0
4. aggiungere dashboard heartbeat
5. implementare self-update controllato

---

## Definizione di successo

CERTAMENT e' in una forma professionale quando:

- ogni release e' tracciata
- ogni deploy e' ripetibile
- ogni server ha uno stato visibile
- ogni regressione banale viene fermata in CI
- ogni rollout puo' essere fermato o rollbackato

Quando questi punti sono veri, il progetto e' gia' forte anche senza piattaforma runbook completa.