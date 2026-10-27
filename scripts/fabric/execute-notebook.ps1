<#
.SYNOPSIS
    Executes a Microsoft Fabric notebook using the Fabric REST API.

.DESCRIPTION
    Looks up a notebook by display name, starts a RunNotebook job, and optionally polls
    until it finishes. Configuration is read from environment variables so no secret is
    passed on a command line:
      FABRIC_ACCESS_TOKEN      Fabric access token (required)
      FABRIC_WORKSPACE_ID      Workspace GUID (required)
      FABRIC_NOTEBOOK_NAME     Notebook display name (required)
      FABRIC_NOTEBOOK_PARAMETERS_JSON  Optional JSON object of notebook parameters
      FABRIC_SPARK_CONF_JSON   Optional JSON object of Spark configuration
      FABRIC_TIMEOUT_MINUTES   Optional, default 30
      FABRIC_POLL_INTERVAL_SECONDS  Optional, default 30
      FABRIC_WAIT_FOR_COMPLETION    Optional, 'true' (default) or 'false'

    The Fabric REST API does not return notebook outputs or exit values. Have the notebook
    write results to a Lakehouse, storage account, or database. Use the rootActivityId
    for tracing in the Fabric Monitoring Hub.

    The identity needs access to the workspace (Contributor or higher) and the Fabric
    notebook/item execute and read permissions.

    Exit codes: 0 success, 1 failure, timeout or cancellation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$apiRoot = 'https://api.fabric.microsoft.com/v1'
$httpTimeoutSeconds = 60

function Write-ErrorMessage {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("ERROR: $Message")
}

function Get-EnvValue {
    param([Parameter(Mandatory)][string]$Name, [string]$Default = '')
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Get-RequiredEnvValue {
    param([Parameter(Mandatory)][string]$Name)
    $value = Get-EnvValue -Name $Name
    if ($value -eq '') { throw "$Name must not be empty." }
    return $value
}

function Get-PositiveInt {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Default, [int]$Max = 1440)
    $raw = Get-EnvValue -Name $Name -Default ([string]$Default)
    $parsed = 0
    if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt $Max) {
        throw "$Name must be an integer between 1 and $Max."
    }
    return $parsed
}

function Get-JsonObject {
    param([Parameter(Mandatory)][string]$Name)
    $raw = Get-EnvValue -Name $Name
    if ($raw -eq '') { return @{} }
    try { $parsed = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw "$Name must be a valid JSON object." }
    if ($parsed -isnot [hashtable]) { throw "$Name must be a JSON object." }
    return $parsed
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

function Get-NotebookId {
    param([Parameter(Mandatory)][string]$WorkspaceId, [Parameter(Mandatory)][string]$Name)

    $found = @()
    $uri = "$apiRoot/workspaces/$WorkspaceId/items?type=Notebook"
    while ($uri) {
        $r = Invoke-Fabric -Method Get -Uri $uri
        if ($r.StatusCode -ne 200) { throw "Notebook lookup failed with HTTP $($r.StatusCode)." }
        $found += @($r.Body.value | Where-Object { $_.type -eq 'Notebook' -and $_.displayName -eq $Name })
        $uri = $null
        $next = $r.Body.continuationUri
        if ($next -and ([uri]$next).Host -eq 'api.fabric.microsoft.com') { $uri = $next }
    }

    if ($found.Count -eq 0) { throw "No notebook named '$Name' was found in the workspace." }
    if ($found.Count -gt 1) { throw "Multiple notebooks named '$Name' were found; names must be unique." }
    return [string]$found[0].id
}

try {
    $token = Get-RequiredEnvValue -Name 'FABRIC_ACCESS_TOKEN'
    $script:Headers = @{ Authorization = ('Bearer ' + $token) }
    $workspaceInput = Get-RequiredEnvValue -Name 'FABRIC_WORKSPACE_ID'
    $parsedGuid = [guid]::Empty
    if (-not [guid]::TryParse($workspaceInput, [ref]$parsedGuid)) { throw 'FABRIC_WORKSPACE_ID must be a UUID.' }
    $workspaceId = $parsedGuid.ToString()
    $notebookName = Get-RequiredEnvValue -Name 'FABRIC_NOTEBOOK_NAME'
    $timeoutMinutes = Get-PositiveInt -Name 'FABRIC_TIMEOUT_MINUTES' -Default 30
    $pollSeconds = Get-PositiveInt -Name 'FABRIC_POLL_INTERVAL_SECONDS' -Default 30 -Max 600
    $wait = (Get-EnvValue -Name 'FABRIC_WAIT_FOR_COMPLETION' -Default 'true') -ne 'false'
    $notebookParameters = Get-JsonObject -Name 'FABRIC_NOTEBOOK_PARAMETERS_JSON'
    $sparkConf = Get-JsonObject -Name 'FABRIC_SPARK_CONF_JSON'

    $notebookId = Get-NotebookId -WorkspaceId $workspaceId -Name $notebookName
    Write-Output "INFO: Found notebook '$notebookName' ($notebookId)."

    $executionData = @{}
    if ($notebookParameters.Count -gt 0) {
        $typed = @{}
        foreach ($key in $notebookParameters.Keys) {
            $value = $notebookParameters[$key]
            $type = switch ($value) {
                { $_ -is [bool] } { 'bool'; break }
                { $_ -is [int] -or $_ -is [long] } { 'int'; break }
                { $_ -is [double] -or $_ -is [decimal] } { 'float'; break }
                default { 'string' }
            }
            $typed[$key] = @{ value = $value; type = $type }
        }
        $executionData['parameters'] = $typed
    }
    if ($sparkConf.Count -gt 0) { $executionData['configuration'] = @{ conf = $sparkConf } }
    $body = if ($executionData.Count -gt 0) { @{ executionData = $executionData } | ConvertTo-Json -Depth 10 } else { $null }

    $jobsUri = "$apiRoot/workspaces/$workspaceId/items/$notebookId/jobs/instances"
    $start = Invoke-Fabric -Method Post -Uri "${jobsUri}?jobType=RunNotebook" -Body $body
    if ($start.StatusCode -ne 202) { throw "Starting the notebook failed with HTTP $($start.StatusCode)." }

    $location = [string]($start.Headers['Location'] | Select-Object -First 1)
    $idPattern = '/jobs/instances/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    if ($location -notmatch $idPattern) { throw 'Could not determine the job instance ID from the response.' }
    $jobId = $Matches[1]
    Write-Output "INFO: Started notebook job $jobId."

    if (-not $wait) {
        Write-Output 'INFO: Not waiting for completion.'
        exit 0
    }

    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    $lastStatus = ''
    while ($true) {
        Start-Sleep -Seconds $pollSeconds
        $r = Invoke-Fabric -Method Get -Uri "$jobsUri/$jobId"
        if ($r.StatusCode -eq 200) {
            $job = $r.Body
            if ($job.status -ne $lastStatus) {
                Write-Output "INFO: Job status: $($job.status)"
                $lastStatus = $job.status
            }
            switch ($job.status) {
                'Completed' {
                    Write-Output "INFO: Notebook completed. Root activity ID: $($job.rootActivityId)"
                    Write-Output 'INFO: Notebook outputs are not available via the REST API.'
                    exit 0
                }
                { $_ -in 'Failed', 'Cancelled', 'Deduped' } {
                    $reason = $job.failureReason | ConvertTo-Json -Compress -Depth 5
                    Write-ErrorMessage "Notebook job ended with status $($job.status). Root activity ID: $($job.rootActivityId). Reason: $reason"
                    exit 1
                }
            }
        }
        elseif ($r.StatusCode -notin 429, 500, 502, 503, 504) {
            throw "Polling the job failed with HTTP $($r.StatusCode)."
        }

        if ((Get-Date) -gt $deadline) {
            Write-ErrorMessage "Timed out after $timeoutMinutes minutes; requesting cancellation."
            try { Invoke-Fabric -Method Post -Uri "$jobsUri/$jobId/cancel" | Out-Null } catch { }
            exit 1
        }
    }
}
catch {
    Write-ErrorMessage $_.Exception.Message
    exit 1
}
