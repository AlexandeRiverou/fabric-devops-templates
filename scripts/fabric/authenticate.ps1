<#
.SYNOPSIS
    Acquires a Power BI / Microsoft Fabric access token for a user or service principal.

.DESCRIPTION
    Configuration is read from environment variables so no secret is passed on a command line:
      FABRIC_TENANT_ID       Entra tenant ID (required)
      FABRIC_CLIENT_ID       Application (client) ID (required)
      FABRIC_CLIENT_SECRET   Client secret (required for ServicePrincipal; optional for UserPrincipal)
      FABRIC_USERNAME        User name (UserPrincipal only)
      FABRIC_PASSWORD        Password (UserPrincipal only)
      FABRIC_PRINCIPAL_TYPE  'ServicePrincipal' (default), 'UserPrincipal', or 'AzureCLI'

    The token is masked in logs and exported as FABRIC_ACCESS_TOKEN to later steps of the
    same job through GITHUB_ENV. Exit codes: 0 success, 1 failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$tenantId = $env:FABRIC_TENANT_ID
$clientId = $env:FABRIC_CLIENT_ID
$clientSecret = $env:FABRIC_CLIENT_SECRET
$username = $env:FABRIC_USERNAME
$password = $env:FABRIC_PASSWORD
$principalType = if ($env:FABRIC_PRINCIPAL_TYPE) { $env:FABRIC_PRINCIPAL_TYPE } else { 'ServicePrincipal' }

function Stop-WithError([string]$Message) {
    [Console]::Error.WriteLine("ERROR: $Message")
    exit 1
}

if ($principalType -notin 'UserPrincipal', 'ServicePrincipal', 'AzureCLI') {
    Stop-WithError "Invalid principal type '$principalType'. Use 'AzureCLI', 'UserPrincipal' or 'ServicePrincipal'."
}
if ($principalType -eq 'AzureCLI') {
    $token = (& az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken --output tsv)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        Stop-WithError 'Could not acquire a Microsoft Fabric API access token from Azure CLI.'
    }
    $token = $token.Trim()
    Write-Output "::add-mask::$token"
    if ($env:GITHUB_ENV) {
        "FABRIC_ACCESS_TOKEN=$token" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
    Write-Output 'INFO: Authentication successful. Token acquired through Azure CLI.'
    exit 0
}
if ($tenantId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
    Stop-WithError 'FABRIC_TENANT_ID must be a GUID.'
}

$errors = @()
if ([string]::IsNullOrWhiteSpace($clientId)) { $errors += 'Client ID is required.' }
if ($principalType -eq 'UserPrincipal') {
    if ([string]::IsNullOrWhiteSpace($username)) { $errors += 'Username is required for UserPrincipal authentication.' }
    if ([string]::IsNullOrWhiteSpace($password)) { $errors += 'Password is required for UserPrincipal authentication.' }
}
elseif ([string]::IsNullOrWhiteSpace($clientSecret)) {
    $errors += 'Client secret is required for ServicePrincipal authentication.'
}
if ($errors.Count -gt 0) { Stop-WithError ($errors -join ' ') }

$body = @{
    client_id = $clientId
    scope     = 'https://analysis.windows.net/powerbi/api/.default'
}
if ($principalType -eq 'UserPrincipal') {
    $body.grant_type = 'password'
    $body.username = $username
    $body.password = $password
    if (-not [string]::IsNullOrWhiteSpace($clientSecret)) { $body.client_secret = $clientSecret }
}
else {
    $body.grant_type = 'client_credentials'
    $body.client_secret = $clientSecret
}

Write-Output "INFO: Authenticating as principal type: $principalType"
try {
    $response = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded'
}
catch {
    Stop-WithError "Token request failed: $($_.Exception.Message)"
}

$token = $response.access_token
if ([string]::IsNullOrWhiteSpace($token)) { Stop-WithError 'Token response did not contain an access token.' }

Write-Output "::add-mask::$token"
if ($env:GITHUB_ENV) {
    "FABRIC_ACCESS_TOKEN=$token" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
Write-Output 'INFO: Authentication successful. Token acquired.'
