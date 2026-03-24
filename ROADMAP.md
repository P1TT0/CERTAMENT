# CERTAMENT — Roadmap to Production

## Current Status: ~80% ready

---

## BLOCKER (da fare PRIMA di distribuire)

| # | Cosa | Effort | Perché blocca | Status |
|---|------|--------|---------------|--------|
| B1 | **README.md** — guida installazione, configurazione, troubleshooting | ~4h | Il cliente (o il tuo collega) non sa come installarlo/configurarlo | NOT STARTED |
| B2 | **Version tracking** — `$CertamentVersion = '1.0.0'` nel main + inclusa nei log e heartbeat | ~30min | Non puoi sapere che versione gira su quale server | NOT STARTED |
| B3 | **Uninstall-Certament.ps1** — rimuove task schedulato, cartella installazione, log | ~2h | Se c'è un problema non puoi disinstallare pulito | NOT STARTED |
| B4 | **Config: sezioni mancanti** — il config.json di questo server non ha Context, IIS, Logging, Heartbeat | ~10min | L'installer le crea ma se qualcuno edita a mano può toglierle | NOT STARTED |

**Effort totale blocker: ~7h**

---

## NICE-TO-HAVE (non bloccanti, v1.1+)

| Cosa | Effort | Status |
|------|--------|--------|
| Rollback automatico se update fallisce (export old cert prima di aggiornare) | ~4h | NOT STARTED |
| Config schema validation (segnala chiavi mancanti/typo) | ~2h | NOT STARTED |
| Self-update da repo centrale | ~6h | NOT STARTED |
| Password encryption (DPAPI) | ~3h | NOT STARTED |

**Effort totale nice-to-have: ~15h**

---

## COMPLETATI (storico)

- [x] Fix disabled service handling (skip StartType=Disabled)
- [x] Fix IIS binding retry (drop OldThumbprint on retry)
- [x] Add password.txt instructions to customer notifications
- [x] Concurrent-run protection (named mutex)
- [x] Clean orphan files from root (~30 files)
- [x] Delete TOOLKIT/ duplicate folder
- [x] Fix Set-CertamentCertificate.ps1 drift (disabled-service skip + RestartIIS)
- [x] Remove dead config keys (AutoSelectLatest, email SMTP)
- [x] Implement Logging.Enabled config key
- [x] Clean config.json (remove commented webhooks)
