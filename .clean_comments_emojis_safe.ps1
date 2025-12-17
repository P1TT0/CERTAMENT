param(
    [switch]$ForceBackup
)

$files = Get-ChildItem -Path . -Recurse -Include *.ps1,*.psm1 | Select-Object -ExpandProperty FullName

$emojiPattern = '([\u2600-\u27BF]|[\uD800-\uDBFF][\uDC00-\uDFFF])'

function Remove-BlockComments($text) {
    $out = $text
    while ($true) {
        $start = $out.IndexOf('', $start + 2)
        if ($end -lt 0) {
            $out = $out.Substring(0, $start)
            break
        }
        $out = $out.Substring(0, $start) + $out.Substring($end + 2)
    }
    return $out
}

foreach ($f in $files) {
    Write-Host "Processing: $f"
    $orig = Get-Content -Raw -LiteralPath $f

    $bak = $f + '.bak'
    if (Test-Path -LiteralPath $bak) {
        if ($ForceBackup) { Copy-Item -LiteralPath $f -Destination $bak -Force }
    } else {
        Copy-Item -LiteralPath $f -Destination $bak -Force
    }

    $step1 = Remove-BlockComments $orig

    $outLines = @()
    foreach ($line in $step1 -split "\r?\n") {
        $trim = $line.TrimStart()
        if ($trim.StartsWith('#')) { continue }

        $inString = $false
        $quoteChar = ''
        $result = ''
        for ($i = 0; $i -lt $line.Length; $i++) {
            $ch = $line[$i]
            if ($ch -eq '"' -or $ch -eq "'") {
                if (-not $inString) { $inString = $true; $quoteChar = $ch }
                elseif ($ch -eq $quoteChar) { $inString = $false; $quoteChar = '' }
                $result += $ch
                continue
            }
            if (-not $inString -and $ch -eq '#') { break }
            $result += $ch
        }

        $result = [regex]::Replace($result, $emojiPattern, '')
        $result = $result.TrimEnd()
        $outLines += $result
    }

    $newContent = $outLines -join "`r`n"

    Set-Content -LiteralPath $f -Value $newContent -Force

    try {
        $c = Get-Content -Raw -LiteralPath $f
        [System.Management.Automation.Language.Parser]::ParseInput($c,[ref]$null,[ref]$null) | Out-Null
        Write-Host "PARSE OK: $f"
    }
    catch {
        Write-Warning "Parse failed for $f; restoring from backup"
        Copy-Item -LiteralPath $bak -Destination $f -Force
    }
}

Write-Host "Done. Backups stored as .bak next to each file."
