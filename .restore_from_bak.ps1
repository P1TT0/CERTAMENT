$files = Get-ChildItem -Path . -Recurse -Include *.ps1,*.psm1 | Select-Object -ExpandProperty FullName
foreach ($f in $files) {
    $bak = $f + '.bak'
    if (Test-Path -LiteralPath $bak) {
        Copy-Item -LiteralPath $bak -Destination $f -Force
        Write-Host "Restored: $f from .bak"
    }
}

