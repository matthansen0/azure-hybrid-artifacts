using namespace System.Net

<#
.SYNOPSIS
    HTTP trigger entry point for the Arc Catch-Up Patching solution.
    Receives a Common Alert Schema payload from an Azure Monitor Action Group
    when an Arc machine transitions from Disconnected → Available (Resource Health).
    Orchestrates: validate offline duration → read maintenance config → assess → install.
#>
param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../modules/CatchUpPatching.psm1" -Force

$thresholdHours = [int]($env:OFFLINE_THRESHOLD_HOURS ?? '2')

# --- Parse Common Alert Schema payload ---
$alertPayload = $Request.Body

if (-not $alertPayload) {
    Write-Host "No request body received."
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'No alert payload received.' } | ConvertTo-Json
    })
    return
}

# Extract the affected resource ID from the Common Alert Schema
$essentials = $alertPayload.data.essentials
$resourceId = $null

if ($essentials.alertTargetIDs -and $essentials.alertTargetIDs.Count -gt 0) {
    $resourceId = $essentials.alertTargetIDs[0]
}

if (-not $resourceId) {
    # Try alternative path in the alert context
    $resourceId = $alertPayload.data.alertContext.AffectedResource
}

if (-not $resourceId) {
    Write-Host "Could not extract resource ID from alert payload."
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'Could not extract resource ID from alert payload.' } | ConvertTo-Json
    })
    return
}

Write-Host "Processing catch-up patching for: $resourceId"
Write-Host "Offline threshold: $thresholdHours hours"

# --- Step 1: Validate offline duration ---
$offlineCheck = Test-OfflineDuration -ResourceId $resourceId -ThresholdHours $thresholdHours

if (-not $offlineCheck.ExceedsThreshold) {
    Write-Host "Machine was offline for $($offlineCheck.OfflineHours) hours (below threshold). Skipping."
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{
            status     = 'Skipped'
            resourceId = $resourceId
            reason     = $offlineCheck.Note
            offlineHours = $offlineCheck.OfflineHours
        } | ConvertTo-Json
    })
    return
}

Write-Host "Machine was offline for $($offlineCheck.OfflineHours) hours. Proceeding with catch-up evaluation."

# --- Step 2: Read maintenance configuration classifications ---
$classifications = Get-MaintenanceConfigClassifications -ResourceId $resourceId
Write-Host "Classifications source: $($classifications.Source)"
Write-Host "Windows: $($classifications.WindowsClassifications -join ', ')"
Write-Host "Linux: $($classifications.LinuxClassifications -join ', ')"

# --- Step 3: Check if a maintenance window was actually missed ---
$missedWindowCheck = Test-MissedMaintenanceWindow `
    -ResourceId $resourceId `
    -Classifications $classifications `
    -OfflineStart $offlineCheck.OfflineStart `
    -OnlineTime $offlineCheck.OnlineTime

Write-Host "Missed window check: $($missedWindowCheck.Reason)"

if (-not $missedWindowCheck.MissedWindow) {
    Write-Host "No maintenance window was missed. Next scheduled window will handle patching."
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{
            status              = 'Skipped'
            resourceId          = $resourceId
            reason              = $missedWindowCheck.Reason
            offlineHours        = $offlineCheck.OfflineHours
            lastScheduledWindow = $missedWindowCheck.LastScheduledWindow?.ToString('u')
            lastPatchInstall    = $missedWindowCheck.LastPatchInstall?.ToString('u')
        } | ConvertTo-Json
    })
    return
}

Write-Host "Maintenance window was missed. Proceeding with catch-up patching."

# --- Step 4: Assess patches ---
try {
    $assessment = Invoke-CatchUpAssessment -ResourceId $resourceId
}
catch {
    Write-Error "Patch assessment failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{
            status     = 'Error'
            resourceId = $resourceId
            stage      = 'Assessment'
            error      = $_.ToString()
        } | ConvertTo-Json
    })
    return
}

# --- Step 5: Install patches if any are available ---
$totalPatches = Get-TotalAvailablePatches -AssessmentResult $assessment

if ($totalPatches -eq 0) {
    Write-Host "No patches available. Machine is compliant."
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{
            status     = 'Compliant'
            resourceId = $resourceId
            message    = 'Maintenance window was missed but no patches are pending. Machine is already compliant.'
        } | ConvertTo-Json
    })
    return
}

Write-Host "$totalPatches patches available. Triggering installation..."

try {
    $installResult = Invoke-CatchUpInstallation -ResourceId $resourceId -Classifications $classifications
}
catch {
    Write-Error "Patch installation trigger failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{
            status     = 'Error'
            resourceId = $resourceId
            stage      = 'Installation'
            error      = $_.ToString()
        } | ConvertTo-Json
    })
    return
}

# --- Step 6: Enqueue delayed reassessment ---
# After the install completes server-side, we need a fresh assessPatches to update
# the compliance dashboard. Queue a message with a visibility delay so it fires
# after the installation is expected to finish.
$reassessmentDelayMinutes = [int]($env:REASSESSMENT_DELAY_MINUTES ?? '60')
$correlationId = $essentials.alertId ?? [guid]::NewGuid().ToString()

try {
    $connectionString = $env:AzureWebJobsStorage
    $queueName = 'catchup-reassessment'
    $message = @{
        resourceId    = $resourceId
        correlationId = $correlationId
        installedAt   = (Get-Date -Format 'o')
        patchCount    = $totalPatches
    } | ConvertTo-Json -Compress

    # Use the Storage context from the connection string the Function App already has
    $storageContext = New-AzStorageContext -ConnectionString $connectionString
    $visibilityTimeout = New-TimeSpan -Minutes $reassessmentDelayMinutes
    $encodedMessage = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message))
    $queue = Get-AzStorageQueue -Name $queueName -Context $storageContext
    $queue.QueueClient.SendMessage($encodedMessage, $visibilityTimeout, $null)

    Write-Host "Reassessment queued for $reassessmentDelayMinutes minutes from now (correlationId: $correlationId)."
}
catch {
    # Non-fatal: the 24h periodic assessment will still pick it up
    Write-Warning "Failed to queue reassessment message: $_. The next periodic assessment (24h) will update compliance."
}

# --- Done ---
$summary = @{
    status                = 'InstallationTriggered'
    resourceId            = $resourceId
    offlineHours          = $offlineCheck.OfflineHours
    totalPatchesAvailable = $totalPatches
    osType                = $installResult.OsType
    classifications       = $installResult.Classifications
    asyncOperationUrl     = $installResult.AsyncOperationUrl
    reassessmentDelayMin  = $reassessmentDelayMinutes
    correlationId         = $correlationId
    message               = "Catch-up patching triggered for $totalPatches patches. Compliance reassessment scheduled in $reassessmentDelayMinutes minutes."
}

Write-Host "Catch-up patching summary: $($summary | ConvertTo-Json -Compress)"

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = $summary | ConvertTo-Json -Depth 5
})
