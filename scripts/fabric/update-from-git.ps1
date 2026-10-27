<#
.SYNOPSIS
    Syncs a Microsoft Fabric workspace with its connected Git repository.

.DESCRIPTION
    Resolves the target workspace (by ID or by display name), reads its Git status, and
    calls Update From Git when the workspace head differs from the remote commit. The
    long-running operation is polled until it succeeds, fails, or times out. Configuration
    is read from environment variables so no secret is passed on a command line:
      FABRIC_ACCESS_TOKEN        Fabric access token (required)
      FABRIC_WORKSPACE_ID        Workspace GUID (required)
      FABRIC_TIMEOUT_MINUTES     Optional, default 30
    git_update_succeeded is set to true on success.

    Conflicts are resolved in favor of the Git repository (PreferRemote). The identity
    needs Contributor or higher on the workspace and access to the Git connection.

    Exit codes: 0 success, 1 failure or timeout.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$apiRoot = 'https://api.fabric.microsoft.com/v1'
$httpTimeoutSeconds = 60

function Get-EnvValue {
    param([Parameter(Mandatory)][string]$Name, [string]$Default = '')
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Invoke-Fabric {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Body
    )

    $request = @{
        Method                  = $Method
        Uri                     = $Uri
        Headers                 = $script:Headers
        TimeoutSec              = $httpTimeoutSeconds
        ResponseHeadersVariable = 'responseHeaders'
        StatusCodeVariable      = 'statusCode'
        SkipHttpErrorCheck      = $true
    }
    if ($Body) { $request['Body'] = $Body; $request['ContentType'] = 'application/json' }
    $result = Invoke-RestMethod @request
    return @{ Body = $result; Headers = $responseHeaders; StatusCode = [int]$statusCode }
}

function Get-HeaderValue {
    param($Headers, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Headers -or -not $Headers.ContainsKey($Name)) { return $null }
    return ([string](@($Headers[$Name])[0])).Trim()
}

function Write-Output-Value {
    param([string]$Name, [string]$Value)
    $file = Get-EnvValue -Name 'GITHUB_OUTPUT'
    if ($file -ne '') { Add-Content -LiteralPath $file -Value "$Name=$Value" }
}

try {
    $token = Get-EnvValue -Name 'FABRIC_ACCESS_TOKEN'
    if ($token -eq '') { throw 'FABRIC_ACCESS_TOKEN must not be empty.' }
    $script:Headers = @{ Authorization = ('Bearer ' + $token) }
    $timeoutMinutes = 0
    if (-not [int]::TryParse((Get-EnvValue -Name 'FABRIC_TIMEOUT_MINUTES' -Default '30'), [ref]$timeoutMinutes) -or
        $timeoutMinutes -lt 1 -or $timeoutMinutes -gt 1440) {
        throw 'FABRIC_TIMEOUT_MINUTES must be an integer between 1 and 1440.'
    }

    $workspaceId = Get-EnvValue -Name 'FABRIC_WORKSPACE_ID'
    $parsedWorkspaceId = [guid]::Empty
    if (-not [guid]::TryParse($workspaceId, [ref]$parsedWorkspaceId)) {
        throw 'FABRIC_WORKSPACE_ID must be a UUID.'
    }
    $workspaceId = $parsedWorkspaceId.ToString()
    Write-Output "INFO: Target workspace ID: $workspaceId"

    $status = Invoke-Fabric -Method Get -Uri "$apiRoot/workspaces/$workspaceId/git/status"
    if ($status.StatusCode -ne 200) { throw "Git status request failed with HTTP $($status.StatusCode)." }
    $remoteCommitHash = $status.Body.remoteCommitHash
    $workspaceHead = $status.Body.workspaceHead
    Write-Output "INFO: Remote commit: $remoteCommitHash; workspace head: $workspaceHead"

    if ($remoteCommitHash -and $remoteCommitHash -eq $workspaceHead) {
        Write-Output 'INFO: Workspace is already in sync with Git. Skipping update.'
        Write-Output-Value -Name 'git_update_succeeded' -Value 'true'
        exit 0
    }

    $body = @{
        remoteCommitHash   = $remoteCommitHash
        workspaceHead      = $workspaceHead
        conflictResolution = @{
            conflictResolutionType   = 'Workspace'
            conflictResolutionPolicy = 'PreferRemote'
        }
        options            = @{ allowOverrideItems = $true }
    } | ConvertTo-Json -Depth 5

    Write-Output 'INFO: Updating the workspace from Git.'
    $update = Invoke-Fabric -Method Post -Uri "$apiRoot/workspaces/$workspaceId/git/updateFromGit" -Body $body
    if ($update.StatusCode -eq 200) {
        Write-Output 'INFO: Workspace update completed synchronously.'
        Write-Output-Value -Name 'git_update_succeeded' -Value 'true'
        exit 0
    }
    if ($update.StatusCode -ne 202) { throw "Update from Git failed with HTTP $($update.StatusCode)." }

    $operationId = Get-HeaderValue -Headers $update.Headers -Name 'x-ms-operation-id'
    $parsedOperation = [guid]::Empty
    if (-not [guid]::TryParse([string]$operationId, [ref]$parsedOperation)) {
        throw 'Update from Git did not return a valid operation ID.'
    }
    $retrySeconds = 0
    if (-not [int]::TryParse([string](Get-HeaderValue -Headers $update.Headers -Name 'Retry-After'), [ref]$retrySeconds) -or
        $retrySeconds -lt 1) {
        $retrySeconds = 20
    }
    $retrySeconds = [Math]::Min($retrySeconds, 60)

    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    $operationUri = "$apiRoot/operations/$($parsedOperation.ToString())"
    while ($true) {
        if ((Get-Date) -gt $deadline) { throw "Update from Git did not complete within $timeoutMinutes minutes." }
        Start-Sleep -Seconds $retrySeconds
        $op = Invoke-Fabric -Method Get -Uri $operationUri
        if ($op.StatusCode -ne 200) { throw "Operation status request failed with HTTP $($op.StatusCode)." }
        $state = [string]$op.Body.status
        Write-Output "INFO: Operation status: $state"
        if ($state -eq 'Succeeded') { break }
        if ($state -eq 'Failed') {
            $message = if ($op.Body.error) { "$($op.Body.error.errorCode): $($op.Body.error.message)" } else { 'no details returned' }
            throw "Update from Git failed ($message)."
        }
    }

    Write-Output 'INFO: Workspace update completed successfully.'
    Write-Output-Value -Name 'git_update_succeeded' -Value 'true'
    exit 0
}
catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}
