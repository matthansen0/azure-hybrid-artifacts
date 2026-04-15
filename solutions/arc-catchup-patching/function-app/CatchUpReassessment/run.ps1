<#
.SYNOPSIS
    Queue-triggered function that runs a post-install patch reassessment.
    After catch-up patching installs updates, this function fires (after a
    configurable delay) to re-run assessPatches so the compliance dashboard
    reflects the newly installed patches immediately — rather than waiting
    for the next 24-hour periodic assessment cycle.
#>
param([string]$QueueItem, $TriggerMetadata)

Import-Module "$PSScriptRoot/../modules/CatchUpPatching.psm1" -Force

$message = $QueueItem | ConvertFrom-Json

$resourceId = $message.resourceId
$correlationId = $message.correlationId ?? 'unknown'

Write-Host "Post-install reassessment triggered for: $resourceId (correlationId: $correlationId)"

if (-not $resourceId) {
    Write-Error "Queue message missing resourceId. Skipping."
    return
}

# Run an on-demand patch assessment to refresh the compliance status in AUM
try {
    $assessment = Invoke-CatchUpAssessment -ResourceId $resourceId -TimeoutMinutes 8
    $totalPatches = Get-TotalAvailablePatches -AssessmentResult $assessment

    Write-Host "Post-install reassessment complete for $resourceId. Remaining patches: $totalPatches"

    if ($totalPatches -gt 0) {
        Write-Warning "$resourceId still has $totalPatches patches available after catch-up installation. This may indicate the installation is still in progress, some patches failed to install, or new patches were published."
    }
    else {
        Write-Host "$resourceId is now fully compliant."
    }
}
catch {
    Write-Error "Post-install reassessment failed for ${resourceId}: $_"
    # Do not throw — let the message complete. The next 24h periodic assessment will pick it up.
}
