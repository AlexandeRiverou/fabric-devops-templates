<#
.SYNOPSIS
    Selectively deploys items between stages in a Microsoft Fabric Deployment Pipeline.

.DESCRIPTION
    Uses the Microsoft Fabric REST API to trigger a selective deployment between two stages
    (e.g., Dev to Test, or Test to Prod) within a named Deployment Pipeline. Items from
    the source stage can be filtered by resource type and by a single folder reference.
    Supports native PowerShell -WhatIf to preview which items would deploy and which items
    would be excluded, without sending the deploy request.

.PARAMETER powerBIToken
    A bearer token used to authenticate against the Microsoft Fabric API.
    If omitted or empty, the FABRIC_ACCESS_TOKEN environment variable is used.

.PARAMETER deploymentPipelineName
    The display name of the Deployment Pipeline to target (e.g., "MyProject Pipeline").

.PARAMETER sourceStageName
    The display name of the stage to deploy from (e.g., "Dev").

.PARAMETER targetStageName
    The display name of the stage to deploy to (e.g., "Test").

.PARAMETER excludedResourceTypes
    An optional array (or comma-separated string) of item types to exclude from the
    deployment (e.g., "Reflex", "Warehouse"). Items matching these types in the source
    stage will not be included in the deploy request.

.PARAMETER excludedFolderReference
    Optional single folder reference to exclude from deployment. The referenced folder and
    all descendants are excluded. The value can include whitespace and slashes; the script
    normalizes path separators and trims leading/trailing whitespace.

.PARAMETER timeoutMinutes
    The maximum number of minutes to poll for deployment completion before throwing a
    timeout error. Defaults to 60 minutes.

.EXAMPLE
    .\deployment-pipelines-selective-deploy.ps1 `
        -powerBIToken $token `
        -deploymentPipelineName "MyProject Pipeline" `
        -sourceStageName "Dev" `
        -targetStageName "Test"

    Deploys all items from the Dev stage to the Test stage with the default 60-minute timeout.

.EXAMPLE
    .\deployment-pipelines-selective-deploy.ps1 `
        -powerBIToken $token `
        -deploymentPipelineName "MyProject Pipeline" `
        -sourceStageName "Test" `
        -targetStageName "Prod" `
        -excludedResourceTypes "Reflex,Warehouse" `
        -excludedFolderReference "Shared Artifacts/Do Not Promote" `
        -WhatIf

    Previews deployment from Test to Prod, showing items that would deploy and items excluded
    by type and folder, without triggering deployment.

.NOTES
    Requires a valid Fabric bearer token with permission to trigger deployments on the
    target pipeline. By default, the script exits with code 1 on unrecoverable error.
    Use -ThrowOnError to rethrow exceptions for local troubleshooting with full
    PowerShell script line information.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param (
    [string]$powerBIToken,                  # Fabric access token (defaults to $env:FABRIC_ACCESS_TOKEN)
    [string]$deploymentPipelineName,        # Deployment pipeline name
    [string]$sourceStageName,               # Name of the source stage (e.g., Dev)
    [string]$targetStageName,               # Name of the target stage (e.g., Test)
    [string[]]$excludedResourceTypes = @(), # Resource types to exclude (e.g., Reflex, Warehouse)
    [string]$excludedFolderReference,       # Single folder reference to exclude (folder + descendants)
    [int]$timeoutMinutes = 60,              # Maximum minutes to poll for deployment completion
    [switch]$ThrowOnError                   # Rethrow on error (useful for local test harness stack traces)
)

function NormalizeFolderReference {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalized = $Value.Trim()
    $normalized = $normalized -replace '\\', '/'
    $normalized = $normalized -replace '/+', '/'
    $normalized = $normalized.Trim('/')

    return $normalized
}

function Invoke-FabricGetPagedCollection {
    param([string]$InitialUri)

    $results = @()
    $nextUri = $InitialUri

    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $response = Invoke-RestMethod -Headers $global:fabricHeaders -Uri $nextUri -Method GET
        if ($response.value) {
            $results += $response.value
        }

        if ($response | Get-Member -Name 'continuationUri' -ErrorAction SilentlyContinue) {
            $nextUri = $response.continuationUri
        }
        else {
            $nextUri = $null
        }
    }

    return $results
}

function GetItemDisplayName {
    param($Item)

    if ($Item.itemDisplayName) { return $Item.itemDisplayName }
    if ($Item.displayName) { return $Item.displayName }
    return "<unknown>"
}

function WriteDeploymentItemList {
    param(
        [string]$Title,
        [array]$Items,
        [string]$Color = "Gray"
    )

    $safeItems = @($Items)
    Write-Host "$Title ($($safeItems.Count))" -ForegroundColor $Color

    if ($safeItems.Count -eq 0) {
        Write-Host "  - None" -ForegroundColor DarkGray
        return
    }

    foreach ($entry in $safeItems) {
        $itemIdForLog = if ($entry.itemId) { $entry.itemId } elseif ($entry.sourceItemId) { $entry.sourceItemId } elseif ($entry.id) { $entry.id } else { '<missing-id>' }
        Write-Host "  - $($entry.itemDisplayName) [$($entry.itemType)] (id: $itemIdForLog)" -ForegroundColor $Color
    }
}

function GetStageWorkspaceId {
    param($Stage)

    if (-not [string]::IsNullOrWhiteSpace($Stage.workspaceId)) {
        return $Stage.workspaceId
    }
    if (-not [string]::IsNullOrWhiteSpace($Stage.assignedWorkspaceId)) {
        return $Stage.assignedWorkspaceId
    }
    if (-not [string]::IsNullOrWhiteSpace($Stage.workspace.id)) {
        return $Stage.workspace.id
    }
    if (-not [string]::IsNullOrWhiteSpace($Stage.assignedWorkspace.id)) {
        return $Stage.assignedWorkspace.id
    }

    throw "Could not resolve source workspace ID from stage '$($Stage.displayName)'. Folder exclusion requires stage workspace metadata."
}

function GetFolderPathById {
    param(
        [string]$FolderId,
        [hashtable]$FoldersById
    )

    $segments = @()
    $cursor = $FolderId

    while ($cursor -and $FoldersById.ContainsKey($cursor)) {
        $folder = $FoldersById[$cursor]
        $segments = @($folder.displayName) + $segments
        $cursor = if ($folder | Get-Member -Name 'parentFolderId' -ErrorAction SilentlyContinue) { $folder.parentFolderId } else { $null }
    }

    return ($segments -join '/')
}

function GetObjectPropertyValue {
    param(
        $InputObject,
        [string]$PropertyName
    )

    if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace($PropertyName)) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}


##################################################################
# Normalize exclusions
##################################################################
if ($excludedResourceTypes) {
    $excludedResourceTypes = @($excludedResourceTypes |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
else {
    $excludedResourceTypes = @()
}

$excludedFolderReference = NormalizeFolderReference -Value $excludedFolderReference

if ([string]::IsNullOrWhiteSpace($powerBIToken)) {
    $powerBIToken = $env:FABRIC_ACCESS_TOKEN
}

# Log the received parameters
Write-Output "deploymentPipelineName: $deploymentPipelineName"
Write-Output "sourceStageName: $sourceStageName"
Write-Output "targetStageName: $targetStageName"
Write-Host "Excluded Resource Types: $($excludedResourceTypes -join ', ')"
Write-Host "Excluded Folder Reference: $excludedFolderReference"

$global:baseUrl = "https://api.fabric.microsoft.com/v1"
$global:resourceUrl = "https://api.fabric.microsoft.com"

$global:fabricHeaders = @{ Authorization = "Bearer $powerBIToken" }


##################################################################
# Get Deployment Pipeline By Name
##################################################################
function GetDeploymentPipelineByName($deploymentPipelineName) {
    $deploymentPipelinesUrl = "{0}/deploymentPipelines" -f $baseUrl
    $deploymentPipelines = Invoke-RestMethod -Headers $fabricHeaders -Uri $deploymentPipelinesUrl -Method GET

    $pipelineList = if ($deploymentPipelines | Get-Member -Name 'value' -ErrorAction SilentlyContinue) { $deploymentPipelines.value } else { $deploymentPipelines }
    $deploymentPipeline = $pipelineList | Where-Object { $_.displayName -eq "$deploymentPipelineName" }

    if (-not $deploymentPipeline) {
        throw "Deployment pipeline '$deploymentPipelineName' not found."
    }

    return $deploymentPipeline
}


##################################################################
# Get Deployment Pipeline Stage By Name
##################################################################
function GetDeploymentPipelineStageByName($deploymentPipelineStageName, $deploymentPipelineId) {
    $deploymentPipelineStagesUrl = "{0}/deploymentPipelines/{1}/stages" -f $baseUrl, $deploymentPipelineId
    $stagesResponse = Invoke-RestMethod -Headers $fabricHeaders -Uri $deploymentPipelineStagesUrl -Method GET
    $deploymentPipelineStages = if ($stagesResponse | Get-Member -Name 'value' -ErrorAction SilentlyContinue) { $stagesResponse.value } else { $stagesResponse }

    $deploymentPipelineStage = $deploymentPipelineStages | Where-Object { $_.DisplayName -eq $deploymentPipelineStageName }

    if (!$deploymentPipelineStage) {
        throw "A deployment pipeline stage with the requested name '$deploymentPipelineStageName' was not found."
    }

    return $deploymentPipelineStage
}


##################################################################
# Get Error Response
##################################################################
function GetErrorResponse($exception) {
    if (!$exception) {
        return "Unknown error occurred"
    }

    # Try to extract the response body from the HTTP exception
    $response = GetObjectPropertyValue -InputObject $exception -PropertyName 'Response'
    if ($null -ne $response) {
        try {
            $responseStream = GetObjectPropertyValue -InputObject $response -PropertyName 'Content'
            if ($null -eq $responseStream -and ($response | Get-Member -Name 'GetResponseStream' -MemberType Method -ErrorAction SilentlyContinue)) {
                $responseStream = $response.GetResponseStream()
            }

            if ($responseStream) {
                if ($responseStream -is [System.IO.Stream]) {
                    if ($responseStream.CanSeek) {
                        $responseStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
                    }

                    $streamReader = [System.IO.StreamReader]::new($responseStream, [System.Text.Encoding]::UTF8)
                    $responseBody = $streamReader.ReadToEnd()
                    $streamReader.Dispose()

                    if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                        return $responseBody
                    }
                }
                elseif ($responseStream -is [string]) {
                    return $responseStream
                }
            }
        }
        catch {
            Write-Verbose "Failed to read response content: $_"
        }
    }

    # Fallback: return exception message
    return $exception.ToString()
}


try {
    if ([string]::IsNullOrWhiteSpace($powerBIToken)) {
        throw "No access token supplied. Pass -powerBIToken or set FABRIC_ACCESS_TOKEN."
    }

    $deploymentPipeline = GetDeploymentPipelineByName $deploymentPipelineName
    Write-Host "deploymentPipeline.id: $($deploymentPipeline.id)"

    $sourceStage = GetDeploymentPipelineStageByName $sourceStageName $deploymentPipeline.id
    $targetStage = GetDeploymentPipelineStageByName $targetStageName $deploymentPipeline.id

    Write-Host "sourceStage.id: $($sourceStage.id)"
    Write-Host "targetStage.id: $($targetStage.id)"

    $deployUrl = [string]::Concat($baseUrl, "/deploymentPipelines/", $deploymentPipeline.id, "/deploy")
    $sourceItemsUrl = [string]::Concat($baseUrl, "/deploymentPipelines/", $deploymentPipeline.id, "/stages/", $sourceStage.id, "/items")
    $sourceItems = Invoke-FabricGetPagedCollection -InitialUri $sourceItemsUrl

    $excludedByFolderIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $resolvedFolderPath = $null
    $resolvedFolderId = $null

    if (-not [string]::IsNullOrWhiteSpace($excludedFolderReference)) {
        Write-Host "Resolving excluded folder reference: '$excludedFolderReference'" -ForegroundColor Yellow

        $sourceWorkspaceId = GetStageWorkspaceId -Stage $sourceStage
        Write-Host "sourceWorkspaceId: $sourceWorkspaceId"

        $foldersUrl = [string]::Concat($baseUrl, "/workspaces/", $sourceWorkspaceId, "/folders")
        $folders = Invoke-FabricGetPagedCollection -InitialUri $foldersUrl

        $foldersById = @{}
        foreach ($folder in $folders) {
            $foldersById[$folder.id] = $folder
        }

        $folderPathRows = $folders | ForEach-Object {
            [pscustomobject]@{
                id          = $_.id
                displayName = $_.displayName
                fullPath    = GetFolderPathById -FolderId $_.id -FoldersById $foldersById
            }
        }

        $matchingFolders = @($folderPathRows | Where-Object {
                $_.fullPath -and $_.fullPath.Equals($excludedFolderReference, [System.StringComparison]::OrdinalIgnoreCase)
            })

        if ($matchingFolders.Count -eq 0) {
            $knownPaths = $folderPathRows | Select-Object -ExpandProperty fullPath | Sort-Object -Unique
            Write-Warning "Excluded folder reference '$excludedFolderReference' was not found. Known folder paths: $($knownPaths -join '; '). Continuing without folder exclusion."
        }
        elseif ($matchingFolders.Count -gt 1) {
            $candidates = $matchingFolders | Select-Object -ExpandProperty fullPath | Sort-Object -Unique
            Write-Warning "Excluded folder reference '$excludedFolderReference' is ambiguous. Matches: $($candidates -join '; '). Continuing without folder exclusion."
        }
        else {
            $resolvedFolderId = $matchingFolders[0].id
            $resolvedFolderPath = $matchingFolders[0].fullPath
            Write-Host "Resolved excluded folder: '$resolvedFolderPath' ($resolvedFolderId)" -ForegroundColor Yellow

            $folderItemsUrl = [string]::Concat($baseUrl, "/workspaces/", $sourceWorkspaceId, "/items?rootFolderId=", $resolvedFolderId, "&recursive=true")
            $folderItems = Invoke-FabricGetPagedCollection -InitialUri $folderItemsUrl

            foreach ($folderItem in $folderItems) {
                if (-not [string]::IsNullOrWhiteSpace($folderItem.id)) {
                    [void]$excludedByFolderIds.Add($folderItem.id)
                }
            }

            Write-Host "Resolved $($excludedByFolderIds.Count) source workspace item(s) under excluded folder subtree." -ForegroundColor Yellow
        }
    }

    $deployCandidates = @()
    $excludedItems = @()

    foreach ($item in $sourceItems) {
        $itemDisplayName = GetItemDisplayName -Item $item
        $itemId = if ($item | Get-Member -Name 'itemId' -ErrorAction SilentlyContinue) { $item.itemId } else { $null }
        $sourceItemId = if (($item | Get-Member -Name 'sourceItemId' -ErrorAction SilentlyContinue) -and $item.sourceItemId) {
            $item.sourceItemId
        }
        elseif ($itemId) {
            $itemId
        }
        else {
            $null
        }

        $isExcludedByType = $excludedResourceTypes.Count -gt 0 -and ($excludedResourceTypes -contains $item.itemType)
        $isExcludedByFolder = $excludedByFolderIds.Count -gt 0 -and (
            ($sourceItemId -and $excludedByFolderIds.Contains($sourceItemId)) -or
            ($itemId -and $excludedByFolderIds.Contains($itemId))
        )

        $reason = @()
        if ($isExcludedByType) { $reason += 'Type' }
        if ($isExcludedByFolder) { $reason += 'Folder' }

        $entry = [pscustomobject]@{
            itemDisplayName  = $itemDisplayName
            itemType         = $item.itemType
            sourceItemId     = $sourceItemId
            itemId           = $itemId
            excludedByType   = $isExcludedByType
            excludedByFolder = $isExcludedByFolder
            excludedReason   = ($reason -join ',')
        }

        if ($isExcludedByType -or $isExcludedByFolder) {
            $excludedItems += $entry
        }
        else {
            $deployCandidates += $entry
        }
    }

    $excludedByTypeItems = @($excludedItems | Where-Object { $_.excludedByType })
    $excludedByFolderItems = @($excludedItems | Where-Object { $_.excludedByFolder })
    $excludedByTypeCount = $excludedByTypeItems.Count
    $excludedByFolderCount = $excludedByFolderItems.Count

    Write-Host "Source Items Before Filter: $($sourceItems.Count)"
    Write-Host "Excluded By Type Count: $excludedByTypeCount"
    Write-Host "Excluded By Folder Count: $excludedByFolderCount"
    if ($resolvedFolderPath) {
        Write-Host "Excluded Folder Path: $resolvedFolderPath"
    }
    Write-Host "Source Items After Filter: $($deployCandidates.Count)"

    if ($deployCandidates.Count -eq 0) {
        throw "No deployable items remain after applying exclusions."
    }

    if (-not $WhatIfPreference) {
        Write-Host ""
        WriteDeploymentItemList -Title "Excluded by Type" -Items $excludedByTypeItems -Color Yellow
        WriteDeploymentItemList -Title "Excluded by Folder" -Items $excludedByFolderItems -Color Yellow
        WriteDeploymentItemList -Title "Items to Deploy" -Items $deployCandidates -Color Green
        Write-Host ""
    }

    $shouldProcessTarget = "Deployment pipeline '$deploymentPipelineName' from '$sourceStageName' to '$targetStageName'"
    if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, "Deploy $($deployCandidates.Count) item(s)")) {
        Write-Host "Preview only: deployment request was not sent." -ForegroundColor Cyan

        Write-Host "Would Deploy Items:" -ForegroundColor Cyan
        Write-Host ($deployCandidates | Select-Object itemDisplayName, itemType, sourceItemId, itemId | ConvertTo-Json -Depth 5)

        Write-Host "Excluded Items:" -ForegroundColor Cyan
        Write-Host ($excludedItems | Select-Object itemDisplayName, itemType, sourceItemId, itemId, excludedByType, excludedByFolder, excludedReason | ConvertTo-Json -Depth 5)
        return
    }

    ##################################################################
    # Build Deploy Body
    ##################################################################
    $deployBody = @{
        sourceStageId = $sourceStage.id
        targetStageId = $targetStage.id
        note          = "Deploying business ready items"
        options       = @{
            allowOverwriteArtifact = $true
            allowCreateArtifact    = $true
            allowPurgeData         = $false
        }
        items         = @($deployCandidates | ForEach-Object {
                @{
                    sourceItemId = $_.itemId
                    itemType     = $_.itemType
                }
            })
    } | ConvertTo-Json -Depth 10 -Compress

    Write-Verbose "Sending deployment request..."

    Write-Host "Deploy request URL: $deployUrl" -ForegroundColor DarkCyan
    Write-Host "Deploy request headers (masked):" -ForegroundColor DarkCyan
    Write-Host '{"Authorization":"Bearer ***"}'
    Write-Host "Deploy request body:" -ForegroundColor DarkCyan
    Write-Host $deployBody

    ##################################################################
    # Trigger Deploy
    ##################################################################
    try {
        $deployResponse = Invoke-WebRequest -Headers $global:fabricHeaders -Uri $deployUrl -Method POST -Body $deployBody -ContentType "application/json" -UseBasicParsing
        Write-Host "Deployment request accepted. Status Code: $($deployResponse.StatusCode)"
    }
    catch {
        $responseHeadersForLog = $null
        $exceptionResponse = GetObjectPropertyValue -InputObject $_.Exception -PropertyName 'Response'
        if ($null -ne $exceptionResponse) {
            $responseHeadersForLog = GetObjectPropertyValue -InputObject $exceptionResponse -PropertyName 'Headers'
        }

        Write-Host "Deployment error response headers:" -ForegroundColor Yellow
        if ($null -ne $responseHeadersForLog) {
            Write-Host ($responseHeadersForLog | Out-String)
        }
        else {
            Write-Host "  <none>" -ForegroundColor DarkGray
        }

        $errorResponse = GetErrorResponse($_.Exception)
        Write-Host "Deployment failed with error: $errorResponse" -ForegroundColor Red

        # Try to parse the response as JSON to extract detailed error information
        try {
            Write-Host "Response body received. Attempting to parse as JSON..." -ForegroundColor Cyan
            $errorObj = $errorResponse | ConvertFrom-Json

            Write-Host "Error response JSON (formatted):" -ForegroundColor Cyan
            Write-Host ($errorObj | ConvertTo-Json -Depth 10)

            if ($errorObj | Get-Member -Name 'details' -ErrorAction SilentlyContinue) {
                $conflictedResourceIds = @()
                Write-Host "`nAnalyzing deployment conflicts..." -ForegroundColor Yellow

                foreach ($detail in $errorObj.details) {
                    if (($detail | Get-Member -Name 'errorCode' -ErrorAction SilentlyContinue) -and
                        $detail.errorCode -eq "TargetArtifactNameConflict" -and
                        ($detail | Get-Member -Name 'relatedResource' -ErrorAction SilentlyContinue) -and
                        ($detail.relatedResource | Get-Member -Name 'resourceId' -ErrorAction SilentlyContinue)) {
                        $conflictedResourceIds += $detail.relatedResource.resourceId
                        Write-Host "  - Conflicted Resource ID: $($detail.relatedResource.resourceId)" -ForegroundColor Yellow
                    }
                }

                if ($conflictedResourceIds.Count -gt 0) {
                    Write-Host "`nSummary: Found $($conflictedResourceIds.Count) items with naming conflicts" -ForegroundColor Red
                    Write-Host "Conflicted Resource IDs:" -ForegroundColor Yellow
                    $conflictedResourceIds | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }

                    Write-Host "`nTrying to identify conflicted items by name..." -ForegroundColor Cyan
                    foreach ($resourceId in $conflictedResourceIds) {
                        $matchingItem = $sourceItems | Where-Object {
                            (($_ | Get-Member -Name 'itemId' -ErrorAction SilentlyContinue) -and $_.itemId -eq $resourceId) -or
                            (($_ | Get-Member -Name 'sourceItemId' -ErrorAction SilentlyContinue) -and $_.sourceItemId -eq $resourceId)
                        } | Select-Object -First 1
                        if ($matchingItem) {
                            Write-Host "  - Item: $(GetItemDisplayName -Item $matchingItem) (Type: $($matchingItem.itemType), ID: $resourceId)" -ForegroundColor Cyan
                        }
                        else {
                            Write-Host "  - Unknown item with ID: $resourceId" -ForegroundColor Cyan
                        }
                    }
                }
            }
        }
        catch {
            Write-Host "Could not parse response as JSON. Raw response body:" -ForegroundColor Yellow
            Write-Host $errorResponse -ForegroundColor Yellow
            Write-Host "JSON parsing error: $_" -ForegroundColor Red
        }
        throw
    }

    $operationIdHeader = $deployResponse.Headers['x-ms-operation-id']
    if ($operationIdHeader -is [array]) {
        $operationId = $operationIdHeader[0]
    }
    elseif ($operationIdHeader) {
        $operationId = $operationIdHeader
    }
    else {
        throw "Operation ID is missing or invalid"
    }

    $retryAfterHeader = $deployResponse.Headers['Retry-After']
    if ($retryAfterHeader -is [array]) { $retryAfterHeader = $retryAfterHeader[0] }
    $retryAfter = $retryAfterHeader -as [int]
    Write-Host "Long Running Operation ID: $operationId"
    Write-Host "Retry After: $retryAfter seconds"

    ##################################################################
    # Poll Operation Status Until Complete
    ##################################################################
    $operationStatusUrl = [string]::Concat($global:baseUrl, "/operations/", $operationId)
    $retryCount = 0

    $defaultRetryAfter = 40
    if ($retryAfter -and $retryAfter -gt 0) {
        $retryInterval = $retryAfter
    }
    else {
        Write-Host "Retry-After header is missing or invalid. Using default: $defaultRetryAfter seconds."
        $retryInterval = $defaultRetryAfter
    }

    $maxRetries = [math]::Ceiling(($timeoutMinutes * 60) / $retryInterval)
    Write-Host "Calculated maxRetries: $maxRetries (for $timeoutMinutes minutes total with $retryInterval second intervals)"

    Write-Host "Polling operation status..."
    $succeeded = $false
    do {
        Write-Host "Polling attempt $($retryCount + 1) of $maxRetries..."
        Start-Sleep -Seconds $retryInterval
        $retryCount++

        try {
            $operationStatusResponse = Invoke-RestMethod -Headers $global:fabricHeaders -Uri $operationStatusUrl -Method GET
            Write-Verbose "Operation status payload retrieved."

            if ($operationStatusResponse.status -eq "Succeeded") {
                Write-Host "Executed deployment successfully." -ForegroundColor Green
                $succeeded = $true
                break
            }
            elseif ($operationStatusResponse.status -eq "Failed") {
                Write-Host "Deployment failed. Status: Failed" -ForegroundColor Red
                throw "Update operation failed."
            }
            else {
                Write-Host "Deployment is still in progress. Checking again after $retryInterval seconds..."
            }
        }
        catch {
            Write-Host "Failed to check operation status. Details: $_" -ForegroundColor Red
            throw
        }
    } while ($retryCount -lt $maxRetries)

    if (-not $succeeded) {
        throw "Operation did not complete within the allowed time."
    }
}
catch {
    $errorResponse = GetErrorResponse($_.Exception)
    Write-Host "Failed to deploy. Error response: $errorResponse" -ForegroundColor Red
    if ($ThrowOnError) {
        throw
    }
    exit 1
}
