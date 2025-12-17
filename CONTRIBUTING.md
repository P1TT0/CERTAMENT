# Contributing to CERTAMENT

Thanks for your interest! Here's how to contribute:

## Branches & workflow
- `main` is the stable branch; all PRs target `main`.
- Create feature branches from `main`: `git switch -c feature/your-feature`.
- Keep commits atomic and well-messaged.

## Code style
- PowerShell 5.1+ (Windows 10+, Windows Server 2016+).
- Use `Write-Log` (in `_MAINCertManager.ps1`) for consistent logging.
- Avoid plaintext secrets in code; use `config.json` (ignored) or env vars.
- Use `param()` blocks; avoid global variables.

## Testing
- Before pushing, run `./_MAINCertManager.ps1 -WhatIf` to validate flow.
- Test both with and without BC/IIS present.

## PR process
1. Push branch to your fork (or use `-b` flag if you have write access).
2. Open a PR on GitHub targeting `main`.
3. Include a clear summary and rationale.
4. Ensure CI/tests pass (if configured).
5. Wait for review and merge.

## Commit messages
Follow [Conventional Commits](https://www.conventionalcommits.org/):
- `feat: add notification on cert expiry`
- `fix: correct IIS binding update logic`
- `docs: update README with troubleshooting`
- `chore: refactor config loading`

Questions? Open an issue.
