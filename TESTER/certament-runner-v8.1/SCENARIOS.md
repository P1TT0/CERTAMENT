# Scenari

## Core

- **NoOp** — prepara BC, IIS e HTTP.sys con un certificato LAB gia valido e corrente, esegue il vero CERTAMENT sullo stato LAB e verifica nessun cambiamento.
- **PfxMissing** — certificato BC in scadenza, nessun PFX; atteso rifiuto senza modifiche runtime.
- **WrongPassword** — PFX valido ma password errata; atteso rifiuto senza modifiche runtime.
- **PfxExpired** — PFX leggibile ma certificato già scaduto; atteso rifiuto senza installazione.
- **PfxNotNewer** — PFX con `NotAfter` non maggiore del certificato corrente; atteso rifiuto.
- **WrongSan** — PFX valido ma SAN non pertinente; se la release lo installa/usa viene classificato `EXPECTED-GAP`.
- **MultipleCandidates** — PFX pertinenti multipli; uno migliore ma meno recente come file. Serve a dimostrare la selezione per `LastWriteTime` della release corrente.
- **UnrelatedPfx** — PFX più recente ma identità non pertinente; se viene usato è `EXPECTED-GAP`.
- **AlreadyCurrent** — BC target, IIS 443 e HTTP.sys già sul certificato LAB nuovo; atteso no-op.

## Renewal

- **HappyPath** — target coerente sul vecchio LAB; atteso rinnovo completo BC + IIS + HTTP.sys.
- **MultiGroup** — `PROD_NUP` e `PROD_NUP2` condividono lo stesso vecchio LAB; atteso rinnovo di entrambe.
- **RestartPolicy** — come HappyPath ma `IIS.RestartAfterUpdate=false`; atteso aggiornamento senza `iisreset`.
