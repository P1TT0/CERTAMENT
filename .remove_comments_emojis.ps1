
$files = Get-ChildItem -Path . -Recurse -Include *.ps1,*.psm1 | Select-Object -ExpandProperty FullName

$emojiPattern = '[\u{1F300}-\u{1F6FF}\u{1F900}-\u{1F9FF}\u{1F700}-\u{1F77F}\u{2600}-\u{26FF}\u{2700}-\u{27BF}]'

foreach ($f in $files) {
    $orig = Get-Content -Raw -LiteralPath $f
    $outLines = @()
    foreach ($line in $orig -split "\r?\n") {
        $trim = $line.TrimStart()
        if ($trim.StartsWith('#')) { continue }

        $inString = $false
        $quoteChar = ''
        $result = ''
        for ($i=0; $i -lt $line.Length; $i++) {
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

        if ($result -ne '') { $outLines += $result }
    }

    Copy-Item -LiteralPath $f -Destination ($f + '.bak') -Force
    Set-Content -LiteralPath $f -Value ($outLines -join "`r`n") -Force
    Write-Host "Edited: $f"
}

