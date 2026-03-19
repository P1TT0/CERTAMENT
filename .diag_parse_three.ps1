$paths = @(
    'c:\Users\zio\OneDrive - EOS S.p.A. - Production\CODE\CERTAMENT\_MAINCertManager.ps1',
    'c:\Users\zio\OneDrive - EOS S.p.A. - Production\CODE\CERTAMENT\Update-IISBinding.psm1',
    'c:\Users\zio\OneDrive - EOS S.p.A. - Production\CODE\CERTAMENT\Test-BCWebServices.psm1'
)
foreach ($p in $paths) {
    Write-Host "\n--- Parsing: $p ---"
    try {
        $c = Get-Content -Raw -LiteralPath $p
        [System.Management.Automation.Language.Parser]::ParseInput($c,[ref]$null,[ref]$null) | Out-Null
        Write-Host "PARSE_OK: $p"
    } catch {
        Write-Host "PARSE_ERROR: $p -> $($_.Exception.Message)"
    }
}

