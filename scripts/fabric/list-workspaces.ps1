<#
.SYNOPSIS
    Resolves a Microsoft Fabric workspace by ID or display name.

.DESCRIPTION
    Reads FABRIC_ACCESS_TOKEN and either FABRIC_WORKSPACE_ID or FABRIC_WORKSPACE_NAME
    from the environment. A name must match exactly one workspace visible to the
    identity. The selected ID is written to GITHUB_OUTPUT as workspace_id.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$apiRoot = 'https://api.fabric.microsoft.com/v1'

function Get-EnvValue {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    return $value.Trim()
}

try {
    $token = Get-EnvValue -Name 'FABRIC_ACCESS_TOKEN'
    if ($token -eq '') { throw 'FABRIC_ACCESS_TOKEN must not be empty.' }
    $workspaceId = Get-EnvValue -Name 'FABRIC_WORKSPACE_ID'

    if ($workspaceId -ne '') {
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse($workspaceId, [ref]$parsedId)) {
            throw 'FABRIC_WORKSPACE_ID must be a UUID.'
        }
        $workspaceId = $parsedId.ToString()
    }
    else {
        $workspaceName = Get-EnvValue -Name 'FABRIC_WORKSPACE_NAME'
        if ($workspaceName -eq '') {
            throw 'Set FABRIC_WORKSPACE_ID or FABRIC_WORKSPACE_NAME.'
        }

        $headers = @{ Authorization = ('Bearer ' + $token) }
        $matches = @()
        $uri = "$apiRoot/workspaces"
        while ($uri) {
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 60 -ErrorAction Stop
            $matches += @($response.value | Where-Object { $_.displayName -ceq $workspaceName })
            $uri = $null
            $nextPage = $response.continuationUri
            if ($nextPage) {
                $nextUri = [uri]$nextPage
                if ($nextUri.Scheme -ne 'https' -or $nextUri.Host -ne 'api.fabric.microsoft.com') {
                    throw 'Workspace listing returned an untrusted continuation URL.'
                }
                $uri = $nextUri.AbsoluteUri
            }
        }

        if ($matches.Count -eq 0) {
            throw "Workspace '$workspaceName' was not found or is not accessible to the identity."
        }
        if ($matches.Count -gt 1) {
            throw "Multiple workspaces named '$workspaceName' were found; provide FABRIC_WORKSPACE_ID."
        }
        $workspaceId = [string]$matches[0].id
    }

    Write-Output "INFO: Resolved workspace ID: $workspaceId"
    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "workspace_id=$workspaceId"
    }
}
catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}
