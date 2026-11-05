[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._-]{1,48}$')]
    [string] $Release,

    [Parameter(Mandatory)]
    [DateTimeOffset] $AppliedAt,

    [Parameter(Mandatory)]
    [securestring] $Token
)

$ErrorActionPreference = 'Stop'
$endpoint = 'http://127.0.0.1:13000/api/annotations'
$body = @{
    time = $AppliedAt.ToUnixTimeMilliseconds()
    tags = @('pg-schema', 'staging17', $Release)
    text = "PostgreSQL delivery. Схема 2. Релиз $Release."
} | ConvertTo-Json -Compress
$result = Invoke-RestMethod -Uri $endpoint -Method Post -Authentication Bearer -Token $Token `
    -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 10 -AllowUnencryptedAuthentication -NoProxy
Write-Output $result
