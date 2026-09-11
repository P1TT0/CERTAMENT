function Get-PfxFile {
    [CmdletBinding()]
    param(
        [string]$Path = "C:\Certs"
    )

    if (-not (Test-Path $Path)) {
        Write-Error "Directory non trovata: $Path"
        return $null
    }

    $pfxFiles = Get-ChildItem -Path $Path -Filter *.pfx -File | Sort-Object LastWriteTime -Descending

    if (-not $pfxFiles) {
        Write-Warning "Nessun file .pfx trovato in $Path"
        return $null
    }

    return $pfxFiles[0].FullName
}

function Get-PfxCandidates {
    [CmdletBinding()]
    param(
        [string]$Path = "C:\Certs"
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Error "Directory non trovata: $Path"
        return @()
    }

    return @(Get-ChildItem -LiteralPath $Path -Filter '*.pfx' -File | Sort-Object Name)
}

Export-ModuleMember -Function Get-PfxFile, Get-PfxCandidates
