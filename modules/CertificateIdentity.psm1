function Normalize-DnsName([object]$Value){return ([string]$Value -replace '\s+','').Trim().ToLowerInvariant()}
function Test-WildcardDnsMatch {
    param([string]$Wildcard,[string]$Name)
    $suffix=Normalize-DnsName $Wildcard.Substring(2);$candidate=Normalize-DnsName $Name
    return ($Wildcard.StartsWith('*.') -and $candidate -like ('*.'+$suffix) -and ($candidate.Length-$suffix.Length-1 -gt 0) -and $candidate.Substring(0,$candidate.Length-$suffix.Length-1) -notmatch '\.')
}
function Test-DnsIdentityMatch {
    param([string[]]$ExpectedNames,[string[]]$CandidateNames)
    foreach($expected in @($ExpectedNames)){foreach($candidate in @($CandidateNames)){
        $e=Normalize-DnsName $expected;$c=Normalize-DnsName $candidate
        if($e -eq $c){return $true}
        if($e.StartsWith('*.') -and (Test-WildcardDnsMatch $e $c)){return $true}
        if($c.StartsWith('*.') -and (Test-WildcardDnsMatch $c $e)){return $true}
    }}
    return $false
}
function Resolve-EndpointDnsIdentity {
    param([string[]]$ExpectedDnsNames,[string[]]$HostHeaders)
    $expected=@($ExpectedDnsNames|ForEach-Object{Normalize-DnsName $_}|Where-Object{$_}|Sort-Object -Unique)
    $headers=@($HostHeaders|ForEach-Object{Normalize-DnsName $_}|Where-Object{$_}|Sort-Object -Unique)
    $conflict=($expected.Count -gt 0 -and $headers.Count -gt 0 -and -not (Test-DnsIdentityMatch $expected $headers))
    if($expected.Count -gt 0){return [pscustomobject]@{Names=$expected;ExpectedNames=$expected;HostHeaders=$headers;Source='ExpectedDnsNames';Conflict=$conflict}}
    return [pscustomobject]@{Names=$headers;ExpectedNames=$expected;HostHeaders=$headers;Source=$(if($headers.Count -gt 0){'HostHeader'}else{'None'});Conflict=$false}
}
Export-ModuleMember -Function Normalize-DnsName,Test-WildcardDnsMatch,Test-DnsIdentityMatch,Resolve-EndpointDnsIdentity
