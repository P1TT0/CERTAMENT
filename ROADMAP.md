# CERTAMENT — Roadmap to Production

## Current Status: READY FOR PRODUCTION (v1.0)

Branch: `release` — ultimo push: 2026-03-24

---

## BLOCKER — TUTTI COMPLETATI

| # | Cosa | Status |
|---|------|--------|
| B1 | **Documentazione italiana** — guida deploy, diagrammi Mermaid, quick reference card | ✅ DONE |
| B2 | **Version tracking** — `$CertamentVersion` nel main + log/heartbeat | ⏳ v1.1 (spostato a nice-to-have) |
| B3 | **Uninstall-Certament.ps1** — wizard interattivo di disinstallazione | ✅ DONE |
| B4 | **Config: sezioni mancanti** — il config.example.json ha tutte le sezioni, il wizard le genera | ✅ DONE (gestito dall'installer) |

---

## NICE-TO-HAVE (non bloccanti, v1.1+)

| Cosa | Effort | Status |
|------|--------|--------|
| Version tracking (`$CertamentVersion = '1.0.0'` in main + log + heartbeat) | ~30min | NOT STARTED |
| Protezione codice (licenza con scadenza / PS2EXE / conversione C#) | variabile | NOT STARTED |
| Validazione online licenza (via heartbeat endpoint) | ~1-2h | NOT STARTED |
| Rollback automatico se update fallisce (export old cert prima di aggiornare) | ~4h | NOT STARTED |
| Config schema validation (segnala chiavi mancanti/typo) | ~2h | NOT STARTED |
| Rate-limiting notifiche customer (evita spam PFX mancante) | ~1h | NOT STARTED |
| Notifica successo opzionale al customer dopo rinnovo | ~30min | NOT STARTED |
| Self-update da repo centrale | ~6h | NOT STARTED |
| Password encryption (DPAPI) | ~3h | NOT STARTED |
| Azure heartbeat dashboard (Function + Table Storage) | ~2-3h | NOT STARTED |

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
- [x] PS5/PS7 compatibility (Write-Host hashtable workaround)
- [x] SSL/IIS self-healing con snapshot persistence
- [x] Scoping SSL mismatch per InstanceNames (no false positives)
- [x] Documentazione italiana (guida deploy + diagrammi + quick reference)
- [x] Uninstall-Certament.ps1 (wizard interattivo 3 fasi)
- [x] E2E tester scenario-based engine
- [x] Multi-certificate support (più thumbprint diversi su BC)
