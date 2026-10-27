<#
.SYNOPSIS
    Deploys all supported items between stages in a Microsoft Fabric Deployment Pipeline.

.DESCRIPTION
    Resolves a deployment pipeline and its stages by display name, submits a deploy-all
    request to the Microsoft Fabric REST API, and polls the asynchronous operation until
    it succeeds, fails, or reaches the configured timeout.

.PARAMETER powerBIToken
    Fabric bearer token. If omitted, FABRIC_ACCESS_TOKEN is used.

.PARAMETER deploymentPipelineName
    Display name of the Deployment Pipeline.

.PARAMETER sourceStageName
    Display name of the source stage.

.PARAMETER targetStageName
    Display name of the target stage.

.PARAMETER note
    Optional note recorded with the deployment.

.PARAMETER timeoutMinutes
    Maximum time to wait for the deployment operation. Defaults to 60 minutes.

.PARAMETER WhatIf
    Resolve the pipeline and stages but do not submit the deployment request.

.PARAMETER ThrowOnError
    Rethrow errors instead of exiting with code 1, for local troubleshooting.

.EXAMPLE
    .\deployment-pipelines-deploy-all.ps1 `
        -deploymentPipelineName "MyProject Pipeline" `
        -sourceStageName "Dev" `
        -targetStageName "Test"

    Deploys all supported items from the Dev stage to the Test stage.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param (
    [string]$powerBIToken,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$deploymentPipelineName,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$sourceStageName,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$targetStageName,
    [string]$note = "Deploying business ready items",
    [ValidateRange(1, 360)]
    [int]$timeoutMinutes = 60,
    [switch]$ThrowOnError
)

$ErrorActionPreference = 'Stop'
$baseUrl = 'https://api.fabric.microsoft.com/v1'

function Invoke-FabricGetPagedCollection {
    param([Parameter(Mandatory)][string]$InitialUri)

    $results = @()
    $nextUri = $InitialUri

    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $validatedUri = $null
        if (-not [System.Uri]::TryCreate($nextUri, [System.UriKind]::Absolute, [ref]$validatedUri) -or
            $validatedUri.Scheme -ne 'https' -or
            $validatedUri.Host -ne 'api.fabric.microsoft.com' -or
            -not $validatedUri.IsDefaultPort) {
            throw 'Fabric returned an invalid or untrusted collection continuation URI.'
        }

        $response = Invoke-RestMethod -Headers $script:fabricHeaders -Uri $validatedUri.AbsoluteUri -Method Get
        if ($null -ne $response.value) {
            $results += @($response.value)
        }

        $nextUri = if ($response.PSObject.Properties['continuationUri']) {
            [string]$response.continuationUri
        }
        else {
            $null
        }
    }

    return $results
}

function Get-UniqueNamedResource {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Resources,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$ResourceDescription
    )

    $matchingResources = @($Resources | Where-Object { $_.displayName -eq $DisplayName })
    if ($matchingResources.Count -eq 0) {
        throw "$ResourceDescription '$DisplayName' was not found."
    }
    if ($matchingResources.Count -gt 1) {
        throw "More than one $ResourceDescription matched '$DisplayName'; use a unique display name."
    }

    return $matchingResources[0]
}

function Get-ErrorResponseMessage {
    param([Parameter(Mandatory)]$ErrorRecord)

    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        return $ErrorRecord.ErrorDetails.Message
    }

    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response) {
        $content = $response.Content
        if ($content -is [string] -and -not [string]::IsNullOrWhiteSpace($content)) {
            return $content
        }
        if ($null -ne $content -and $content.PSObject.Methods['ReadAsStringAsync']) {
            $body = $content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not [string]::IsNullOrWhiteSpace($body)) {
                return $body
            }
        }

        if ($response.PSObject.Methods['GetResponseStream']) {
            $stream = $response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = [System.IO.StreamReader]::new($stream)
                try {
                    $body = $reader.ReadToEnd()
                    if (-not [string]::IsNullOrWhiteSpace($body)) {
                        return $body
                    }
                }
                finally {
                    $reader.Dispose()
                }
            }
        }
    }

    return $ErrorRecord.Exception.Message
}

try {
    if ([string]::IsNullOrWhiteSpace($powerBIToken)) {
        $powerBIToken = $env:FABRIC_ACCESS_TOKEN
    }
    if ([string]::IsNullOrWhiteSpace($powerBIToken)) {
        throw "No Fabric access token supplied. Pass -powerBIToken or set FABRIC_ACCESS_TOKEN."
    }
    if ($sourceStageName -eq $targetStageName) {
        throw "Source and target stages must be different."
    }

    Write-Output "Deployment pipeline: $deploymentPipelineName"
    Write-Output "Source stage: $sourceStageName"
    Write-Output "Target stage: $targetStageName"

    $script:fabricHeaders = @{
        Authorization = ('Bearer ' + $powerBIToken)
    }
    $powerBIToken = $null

    $pipelines = Invoke-FabricGetPagedCollection -InitialUri "$baseUrl/deploymentPipelines"
    $pipeline = Get-UniqueNamedResource -Resources $pipelines -DisplayName $deploymentPipelineName -ResourceDescription 'Deployment pipeline'
    if ([string]::IsNullOrWhiteSpace($pipeline.id)) {
        throw "Deployment pipeline '$deploymentPipelineName' did not include an ID."
    }

    $stages = Invoke-FabricGetPagedCollection -InitialUri "$baseUrl/deploymentPipelines/$($pipeline.id)/stages"
    $sourceStage = Get-UniqueNamedResource -Resources $stages -DisplayName $sourceStageName -ResourceDescription 'Source stage'
    $targetStage = Get-UniqueNamedResource -Resources $stages -DisplayName $targetStageName -ResourceDescription 'Target stage'
    if ([string]::IsNullOrWhiteSpace($sourceStage.id) -or [string]::IsNullOrWhiteSpace($targetStage.id)) {
        throw 'The source or target stage did not include an ID.'
    }
    if ($sourceStage.id -eq $targetStage.id) {
        throw 'Source and target stage IDs must be different.'
    }

    $deployUrl = "$baseUrl/deploymentPipelines/$($pipeline.id)/deploy"
    $deployBody = @{
        sourceStageId = $sourceStage.id
        targetStageId = $targetStage.id
        note           = $note
    } | ConvertTo-Json -Compress

    $targetDescription = "Deployment pipeline '$deploymentPipelineName' from '$sourceStageName' to '$targetStageName'"
    if (-not $PSCmdlet.ShouldProcess($targetDescription, 'Deploy all supported items')) {
        Write-Host 'Preview only: deployment request was not sent.' -ForegroundColor Cyan
        return
    }

    Write-Host "Submitting deploy-all request from '$sourceStageName' to '$targetStageName'."
    $deployResponse = Invoke-WebRequest -Headers $script:fabricHeaders -Uri $deployUrl -Method Post `
        -Body $deployBody -ContentType 'application/json'

    $operationIdHeader = $deployResponse.Headers['x-ms-operation-id']
    if ($operationIdHeader -is [array]) {
        $operationIdHeader = $operationIdHeader[0]
    }
    $operationId = [string]$operationIdHeader
    if ([string]::IsNullOrWhiteSpace($operationId)) {
        throw 'Fabric accepted the deployment request but did not return an operation ID.'
    }

    $retryAfterHeader = $deployResponse.Headers['Retry-After']
    if ($retryAfterHeader -is [array]) {
        $retryAfterHeader = $retryAfterHeader[0]
    }
    $retryInterval = 30
    $parsedRetryAfter = 0
    if ([int]::TryParse([string]$retryAfterHeader, [ref]$parsedRetryAfter) -and $parsedRetryAfter -gt 0) {
        $retryInterval = $parsedRetryAfter
    }

    $operationStatusUrl = "$baseUrl/operations/$operationId"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $succeeded = $false

    while ($stopwatch.Elapsed.TotalSeconds -lt ($timeoutMinutes * 60)) {
        $remainingSeconds = ($timeoutMinutes * 60) - $stopwatch.Elapsed.TotalSeconds
        $sleepSeconds = [Math]::Max(1, [Math]::Min($retryInterval, [Math]::Ceiling($remainingSeconds)))
        Start-Sleep -Seconds $sleepSeconds

        $statusResponse = Invoke-RestMethod -Headers $script:fabricHeaders -Uri $operationStatusUrl -Method Get
        $status = [string]$statusResponse.status
        Write-Host "Fabric deployment operation status: $status"

        if ($status -eq 'Succeeded') {
            $succeeded = $true
            break
        }
        if ($status -in @('Failed', 'Cancelled', 'Canceled')) {
            $details = if ($statusResponse.PSObject.Properties['error']) {
                $statusResponse.error | ConvertTo-Json -Depth 10 -Compress
            }
            else {
                'No additional error details were returned.'
            }
            throw "Fabric deployment operation ended with status '$status'. $details"
        }
    }

    if (-not $succeeded) {
        throw "Fabric deployment did not complete within $timeoutMinutes minute(s)."
    }

    Write-Host 'Fabric deployment completed successfully.' -ForegroundColor Green
}
catch {
    $message = Get-ErrorResponseMessage -ErrorRecord $_
    [Console]::Error.WriteLine("Fabric deploy-all failed: $message")
    if ($ThrowOnError) {
        throw
    }
    exit 1
}
finally {
    $script:fabricHeaders = $null
    $powerBIToken = $null
}
