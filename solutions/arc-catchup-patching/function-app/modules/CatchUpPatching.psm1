#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Core logic for the Arc Catch-Up Patching solution.
    Provides functions to validate offline duration, read maintenance configurations,
    assess patch compliance, and trigger on-demand update installations.
#>

$script:ApiVersion = '2024-07-10'
$script:MaintenanceApiVersion = '2023-04-01'

function Get-AzRestToken {
    <#
    .SYNOPSIS
        Returns a Bearer token for ARM REST API calls.
    #>
    $context = Get-AzContext
    $token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
    return $token
}

function Invoke-ArmRestMethod {
    <#
    .SYNOPSIS
        Wrapper for ARM REST API calls with retry logic.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Body,
        [int]$MaxRetries = 3
    )

    $token = Get-AzRestToken
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++
        try {
            $params = @{
                Method  = $Method
                Uri     = $Uri
                Headers = $headers
            }
            if ($Body) { $params.Body = $Body }

            $response = Invoke-RestMethod @params -ErrorAction Stop
            return $response
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 429 -or $statusCode -ge 500) {
                $waitSeconds = [math]::Pow(2, $attempt)
                Write-Warning "ARM API returned $statusCode. Retrying in ${waitSeconds}s (attempt $attempt/$MaxRetries)..."
                Start-Sleep -Seconds $waitSeconds
            }
            else {
                throw
            }
        }
    }
    throw "ARM API call failed after $MaxRetries attempts: $Method $Uri"
}

function Test-OfflineDuration {
    <#
    .SYNOPSIS
        Checks if an Arc machine was offline longer than the configured threshold.
    .DESCRIPTION
        Queries the Microsoft.ResourceHealth/availabilityStatuses API for the machine,
        finds the most recent Unavailable → Available transition, and calculates
        the offline duration. Returns $true if duration exceeds the threshold.
    .OUTPUTS
        PSCustomObject with properties: ExceedsThreshold (bool), OfflineHours (double)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][int]$ThresholdHours
    )

    $uri = "https://management.azure.com${ResourceId}/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2024-02-01&`$top=10"

    try {
        $result = Invoke-ArmRestMethod -Method 'GET' -Uri $uri
    }
    catch {
        Write-Warning "Failed to query Resource Health for $ResourceId : $_"
        # If we can't determine offline duration, proceed with catch-up (fail-open)
        return [PSCustomObject]@{
            ExceedsThreshold = $true
            OfflineHours     = -1
            Note             = 'Resource Health query failed; proceeding with catch-up as a safety measure.'
        }
    }

    $statuses = $result.value | Sort-Object { [datetime]$_.properties.occurredTime } -Descending

    # Find the most recent "Unavailable" status (the offline period we just recovered from)
    $unavailable = $statuses | Where-Object { $_.properties.availabilityState -eq 'Unavailable' } | Select-Object -First 1
    $available = $statuses | Where-Object { $_.properties.availabilityState -eq 'Available' } | Select-Object -First 1

    if (-not $unavailable) {
        Write-Host "No Unavailable status found in recent history for $ResourceId. Skipping catch-up."
        return [PSCustomObject]@{
            ExceedsThreshold = $false
            OfflineHours     = 0
            Note             = 'No recent offline period found.'
        }
    }

    $offlineStart = [datetime]$unavailable.properties.occurredTime
    $onlineTime = if ($available) { [datetime]$available.properties.occurredTime } else { [datetime]::UtcNow }
    $offlineDuration = $onlineTime - $offlineStart
    $offlineHours = [math]::Round($offlineDuration.TotalHours, 2)

    Write-Host "Machine $ResourceId was offline for $offlineHours hours (threshold: $ThresholdHours hours)."

    return [PSCustomObject]@{
        ExceedsThreshold = ($offlineHours -ge $ThresholdHours)
        OfflineHours     = $offlineHours
        OfflineStart     = $offlineStart
        OnlineTime       = $onlineTime
        Note             = if ($offlineHours -ge $ThresholdHours) { 'Offline duration exceeds threshold. Catch-up required.' } else { 'Brief blip. Skipping catch-up.' }
    }
}

function Get-MaintenanceConfigClassifications {
    <#
    .SYNOPSIS
        Reads the maintenance configuration(s) assigned to an Arc machine and extracts
        the update classifications to apply during catch-up patching.
    .DESCRIPTION
        Queries Azure Resource Graph for maintenance configuration assignments linked
        to the machine, then reads each maintenance configuration to extract the
        installPatches classifications for both Windows and Linux.
        Falls back to Critical + Security if no maintenance config is found.
    .OUTPUTS
        PSCustomObject with WindowsClassifications and LinuxClassifications arrays.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId
    )

    # Query Resource Graph for configuration assignments targeting this machine
    $query = @"
maintenanceresources
| where type =~ 'microsoft.maintenance/configurationassignments'
| where properties.resourceId =~ '$ResourceId'
| project configId = tostring(properties.maintenanceConfigurationId)
"@

    $assignments = Search-AzGraph -Query $query

    if (-not $assignments -or $assignments.Count -eq 0) {
        Write-Host "No maintenance configuration assignments found for $ResourceId. Using default: Critical + Security."
        return [PSCustomObject]@{
            WindowsClassifications = @('Critical', 'Security')
            LinuxClassifications   = @('Critical', 'Security')
            MaintenanceWindows     = @()
            Source                 = 'Default (no maintenance config assigned)'
        }
    }

    $windowsClassifications = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $linuxClassifications = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $maintenanceWindows = [System.Collections.ArrayList]::new()

    foreach ($assignment in $assignments) {
        $configId = $assignment.configId
        if (-not $configId) { continue }

        $configUri = "https://management.azure.com${configId}?api-version=$script:MaintenanceApiVersion"

        try {
            $config = Invoke-ArmRestMethod -Method 'GET' -Uri $configUri

            # Extract Windows classifications
            $winClassList = $config.properties.installPatches.windowsParameters.classificationsToInclude
            if ($winClassList) {
                foreach ($c in $winClassList) { [void]$windowsClassifications.Add($c) }
            }

            # Extract Linux classifications
            $linClassList = $config.properties.installPatches.linuxParameters.classificationsToInclude
            if ($linClassList) {
                foreach ($c in $linClassList) { [void]$linuxClassifications.Add($c) }
            }

            # Capture the maintenance window schedule for missed-window detection
            $mw = $config.properties.maintenanceWindow
            if ($mw) {
                [void]$maintenanceWindows.Add(@{
                    ConfigId          = $configId
                    StartDateTime     = $mw.startDateTime
                    Duration          = $mw.duration
                    TimeZone          = $mw.timeZone
                    RecurEvery        = $mw.recurEvery
                    ExpirationDateTime = $mw.expirationDateTime
                })
            }
        }
        catch {
            Write-Warning "Failed to read maintenance configuration ${configId}: $_"
        }
    }

    # Fall back to defaults if nothing was extracted
    if ($windowsClassifications.Count -eq 0) {
        $windowsClassifications = [System.Collections.Generic.HashSet[string]]@('Critical', 'Security')
    }
    if ($linuxClassifications.Count -eq 0) {
        $linuxClassifications = [System.Collections.Generic.HashSet[string]]@('Critical', 'Security')
    }

    return [PSCustomObject]@{
        WindowsClassifications = @($windowsClassifications)
        LinuxClassifications   = @($linuxClassifications)
        MaintenanceWindows     = @($maintenanceWindows)
        Source                 = "Maintenance config(s): $($assignments.configId -join ', ')"
    }
}

function Test-MissedMaintenanceWindow {
    <#
    .SYNOPSIS
        Determines whether the machine missed a scheduled maintenance window while offline.
        Prevents unnecessary patching by checking if a window actually occurred during the
        offline period AND the machine didn't get patched during that window.
    .DESCRIPTION
        1. Parses the maintenance configuration schedule (recurEvery, startDateTime, timeZone)
        2. Calculates the most recent scheduled window occurrence before "now"
        3. Queries ARG patchinstallationresources for the machine's last successful install
        4. If lastInstall < lastScheduledWindow → missed it → return $true
        5. If no maintenance config assigned (default classifications) → assume missed (fail-open)
    .OUTPUTS
        PSCustomObject with MissedWindow (bool), LastScheduledWindow (datetime), LastPatchInstall (datetime)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][PSCustomObject]$Classifications,
        [Parameter(Mandatory)][datetime]$OfflineStart,
        [Parameter(Mandatory)][datetime]$OnlineTime
    )

    $maintenanceWindows = $Classifications.MaintenanceWindows

    # If no maintenance config is assigned, we can't calculate a schedule.
    # Fail-open: assume the machine needs patching (original behavior).
    if (-not $maintenanceWindows -or $maintenanceWindows.Count -eq 0) {
        Write-Host "No maintenance window schedule available (default classifications). Assuming catch-up is needed."
        return [PSCustomObject]@{
            MissedWindow        = $true
            Reason              = 'No maintenance configuration assigned. Cannot determine schedule; proceeding with catch-up.'
            LastScheduledWindow = $null
            LastPatchInstall    = $null
        }
    }

    # --- Get last successful patch installation time from ARG ---
    $installQuery = @"
patchinstallationresources
| where type =~ 'microsoft.hybridcompute/machines/patchinstallationresults'
| where id contains '$ResourceId'
| where properties.status =~ 'Succeeded'
| project installTime = todatetime(properties.lastModifiedDateTime), startedBy = tostring(properties.startedBy)
| order by installTime desc
| take 1
"@

    $lastInstallResult = Search-AzGraph -Query $installQuery
    $lastPatchInstall = $null
    if ($lastInstallResult -and $lastInstallResult.Count -gt 0) {
        $lastPatchInstall = [datetime]$lastInstallResult[0].installTime
        Write-Host "Last successful patch installation: $lastPatchInstall UTC (startedBy: $($lastInstallResult[0].startedBy))"
    }
    else {
        Write-Host "No previous patch installation found in ARG for $ResourceId. Assuming catch-up is needed."
        return [PSCustomObject]@{
            MissedWindow        = $true
            Reason              = 'No patch installation history found. Machine may never have been patched through AUM.'
            LastScheduledWindow = $null
            LastPatchInstall    = $null
        }
    }

    # --- Calculate the most recent scheduled maintenance window ---
    # Check each maintenance config; if ANY window was missed, catch-up is needed.
    $missedAny = $false
    $lastScheduledWindowTime = $null

    foreach ($mw in $maintenanceWindows) {
        $lastWindow = Get-LastScheduledWindowOccurrence -MaintenanceWindow $mw -BeforeDate $OnlineTime

        if (-not $lastWindow) {
            Write-Host "Could not calculate schedule for config $($mw.ConfigId). Skipping this config."
            continue
        }

        Write-Host "Config $($mw.ConfigId): last scheduled window was $($lastWindow.ToString('u'))"

        # Track the most recent window across all configs
        if (-not $lastScheduledWindowTime -or $lastWindow -gt $lastScheduledWindowTime) {
            $lastScheduledWindowTime = $lastWindow
        }

        # Did this window fall during the offline period?
        if ($lastWindow -ge $OfflineStart -and $lastWindow -le $OnlineTime) {
            Write-Host "  → Window at $($lastWindow.ToString('u')) falls within offline period ($($OfflineStart.ToString('u')) to $($OnlineTime.ToString('u')))"

            # Was the machine patched AFTER this window? (It shouldn't be if it was offline)
            if ($lastPatchInstall -lt $lastWindow) {
                Write-Host "  → Last install ($($lastPatchInstall.ToString('u'))) is BEFORE this window. Missed!"
                $missedAny = $true
            }
            else {
                Write-Host "  → Last install ($($lastPatchInstall.ToString('u'))) is AFTER this window. Already patched."
            }
        }
        else {
            Write-Host "  → Window at $($lastWindow.ToString('u')) is outside the offline period. No miss."
        }
    }

    if ($missedAny) {
        return [PSCustomObject]@{
            MissedWindow        = $true
            Reason              = "Machine was offline during a scheduled maintenance window and was not patched."
            LastScheduledWindow = $lastScheduledWindowTime
            LastPatchInstall    = $lastPatchInstall
        }
    }
    else {
        return [PSCustomObject]@{
            MissedWindow        = $false
            Reason              = "No maintenance window was missed during the offline period. Next scheduled window will handle patching."
            LastScheduledWindow = $lastScheduledWindowTime
            LastPatchInstall    = $lastPatchInstall
        }
    }
}

function Get-LastScheduledWindowOccurrence {
    <#
    .SYNOPSIS
        Parses a maintenance configuration schedule and calculates the most recent
        window occurrence before a given date. Supports Day, Week, and Month recurrence.
    .DESCRIPTION
        Handles Azure Maintenance Configuration recurEvery patterns:
        - "Day", "2Days", "3Days"               → daily/N-daily
        - "Week Monday", "2Weeks Tuesday,Friday" → weekly/N-weekly on specific days
        - "Month First Tuesday", "Month day15"   → monthly ordinal or day-of-month
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$MaintenanceWindow,
        [Parameter(Mandatory)][datetime]$BeforeDate
    )

    $recurEvery = $MaintenanceWindow.RecurEvery
    $startStr = $MaintenanceWindow.StartDateTime
    $tzName = $MaintenanceWindow.TimeZone

    if (-not $recurEvery -or -not $startStr) { return $null }

    # Parse start datetime
    try {
        $startDt = [datetime]::ParseExact($startStr.Trim(), @('yyyy-MM-dd HH:mm', 'yyyy-MM-dd hh:mm'), $null, 'None')
    }
    catch {
        Write-Warning "Could not parse startDateTime '$startStr': $_"
        return $null
    }

    $timeOfDay = $startDt.TimeOfDay
    $recurLower = $recurEvery.Trim()

    # --- Daily: "Day", "2Days", "3Days" ---
    if ($recurLower -match '^(\d*)Days?$') {
        $interval = if ($Matches[1]) { [int]$Matches[1] } else { 1 }
        $daysSinceStart = [math]::Floor(($BeforeDate - $startDt).TotalDays)
        $completeCycles = [math]::Floor($daysSinceStart / $interval)
        $lastOccurrence = $startDt.AddDays($completeCycles * $interval)
        if ($lastOccurrence -gt $BeforeDate) { $lastOccurrence = $lastOccurrence.AddDays(-$interval) }
        return $lastOccurrence
    }

    # --- Weekly: "Week Monday", "2Weeks Tuesday,Friday", "Week" ---
    if ($recurLower -match '^(\d*)Weeks?\s*(.*)$') {
        $interval = if ($Matches[1]) { [int]$Matches[1] } else { 1 }
        $dayNames = if ($Matches[2]) {
            $Matches[2].Split(',') | ForEach-Object { [System.DayOfWeek]$_.Trim() }
        }
        else {
            @($startDt.DayOfWeek)
        }

        # Walk backwards from BeforeDate to find the last matching day in the correct week cycle
        $candidate = $BeforeDate.Date.Add($timeOfDay)
        for ($i = 0; $i -lt ($interval * 7 + 7); $i++) {
            $check = $candidate.AddDays(-$i)
            if ($check -gt $BeforeDate) { continue }
            if ($check -lt $startDt) { return $null }
            if ($dayNames -contains $check.DayOfWeek) {
                # Verify it's in the correct week cycle
                $weeksSinceStart = [math]::Floor(($check.Date - $startDt.Date).TotalDays / 7)
                if ($weeksSinceStart % $interval -eq 0) {
                    return $check
                }
            }
        }
        return $null
    }

    # --- Monthly by ordinal: "Month First Tuesday", "Month Last Sunday" ---
    if ($recurLower -match '^(\d*)Month\s+(First|Second|Third|Fourth|Last)\s+(\w+)') {
        $interval = if ($Matches[1]) { [int]$Matches[1] } else { 1 }
        $ordinal = $Matches[2]
        $dayOfWeek = [System.DayOfWeek]$Matches[3]

        # Check current month and walk backwards
        $checkMonth = Get-Date -Year $BeforeDate.Year -Month $BeforeDate.Month -Day 1
        for ($m = 0; $m -lt 13; $m++) {
            $candidateDate = $checkMonth.AddMonths(-$m)
            if ($candidateDate -lt (Get-Date -Year $startDt.Year -Month $startDt.Month -Day 1)) { return $null }

            # Verify month interval
            $monthsSinceStart = (($candidateDate.Year - $startDt.Year) * 12) + ($candidateDate.Month - $startDt.Month)
            if ($monthsSinceStart -lt 0 -or $monthsSinceStart % $interval -ne 0) { continue }

            $windowDate = Get-OrdinalDayInMonth -Year $candidateDate.Year -Month $candidateDate.Month -DayOfWeek $dayOfWeek -Ordinal $ordinal
            if ($windowDate) {
                $windowDt = $windowDate.Add($timeOfDay)
                if ($windowDt -le $BeforeDate) {
                    return $windowDt
                }
            }
        }
        return $null
    }

    # --- Monthly by day number: "Month day15", "Month day23,day24" ---
    if ($recurLower -match '^(\d*)Month\s+day(\d+)') {
        $interval = if ($Matches[1]) { [int]$Matches[1] } else { 1 }
        $dayNum = [int]$Matches[2]

        $checkMonth = Get-Date -Year $BeforeDate.Year -Month $BeforeDate.Month -Day 1
        for ($m = 0; $m -lt 13; $m++) {
            $candidateDate = $checkMonth.AddMonths(-$m)
            if ($candidateDate -lt (Get-Date -Year $startDt.Year -Month $startDt.Month -Day 1)) { return $null }

            $monthsSinceStart = (($candidateDate.Year - $startDt.Year) * 12) + ($candidateDate.Month - $startDt.Month)
            if ($monthsSinceStart -lt 0 -or $monthsSinceStart % $interval -ne 0) { continue }

            $daysInMonth = [DateTime]::DaysInMonth($candidateDate.Year, $candidateDate.Month)
            $effectiveDay = [math]::Min($dayNum, $daysInMonth)
            $windowDt = (Get-Date -Year $candidateDate.Year -Month $candidateDate.Month -Day $effectiveDay).Add($timeOfDay)
            if ($windowDt -le $BeforeDate) {
                return $windowDt
            }
        }
        return $null
    }

    Write-Warning "Unrecognized recurEvery pattern: '$recurEvery'. Cannot determine schedule."
    return $null
}

function Get-OrdinalDayInMonth {
    <#
    .SYNOPSIS
        Gets the Nth occurrence of a day-of-week in a given month (First, Second, Third, Fourth, Last).
    #>
    param(
        [int]$Year, [int]$Month,
        [System.DayOfWeek]$DayOfWeek,
        [string]$Ordinal
    )

    $firstOfMonth = Get-Date -Year $Year -Month $Month -Day 1
    $daysInMonth = [DateTime]::DaysInMonth($Year, $Month)

    if ($Ordinal -eq 'Last') {
        for ($d = $daysInMonth; $d -ge 1; $d--) {
            $date = Get-Date -Year $Year -Month $Month -Day $d
            if ($date.DayOfWeek -eq $DayOfWeek) { return $date }
        }
        return $null
    }

    $ordinalMap = @{ 'First' = 1; 'Second' = 2; 'Third' = 3; 'Fourth' = 4 }
    $target = $ordinalMap[$Ordinal]
    $count = 0
    for ($d = 1; $d -le $daysInMonth; $d++) {
        $date = Get-Date -Year $Year -Month $Month -Day $d
        if ($date.DayOfWeek -eq $DayOfWeek) {
            $count++
            if ($count -eq $target) { return $date }
        }
    }
    return $null
}

function Invoke-CatchUpAssessment {
    <#
    .SYNOPSIS
        Triggers an on-demand patch assessment on an Arc machine and polls for the result.
    .OUTPUTS
        Assessment result object from the Azure Update Manager API.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [int]$PollIntervalSeconds = 30,
        [int]$TimeoutMinutes = 5
    )

    $assessUri = "https://management.azure.com${ResourceId}/assessPatches?api-version=$script:ApiVersion"

    Write-Host "Triggering patch assessment for $ResourceId ..."

    try {
        # assessPatches returns 200 if immediate, or we need to check headers for async
        $response = Invoke-WebRequest -Method POST -Uri $assessUri -Headers @{
            'Authorization' = "Bearer $(Get-AzRestToken)"
            'Content-Type'  = 'application/json'
        } -ErrorAction Stop

        # If 200, result is in the body
        if ($response.StatusCode -eq 200) {
            $result = $response.Content | ConvertFrom-Json
            Write-Host "Assessment completed immediately. Available patches: $(($result.availablePatchCountByClassification | ConvertTo-Json -Compress))"
            return $result
        }

        # If 202, poll the Location header for the async result
        $locationUrl = $response.Headers['Location']
        if (-not $locationUrl) {
            $locationUrl = $response.Headers['Azure-AsyncOperation']
        }
    }
    catch {
        # Invoke-WebRequest throws on non-2xx but 202 is expected
        if ($_.Exception.Response.StatusCode.value__ -eq 202) {
            $locationUrl = $_.Exception.Response.Headers.Location?.ToString()
            if (-not $locationUrl) {
                $locationUrl = $_.Exception.Response.Headers.GetValues('Azure-AsyncOperation') | Select-Object -First 1
            }
        }
        else {
            throw "Failed to trigger patch assessment: $_"
        }
    }

    if (-not $locationUrl) {
        throw "assessPatches returned no Location or Azure-AsyncOperation header for polling."
    }

    # Poll for completion
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $token = Get-AzRestToken

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds

        try {
            $pollResponse = Invoke-RestMethod -Method GET -Uri $locationUrl -Headers @{
                'Authorization' = "Bearer $token"
            } -ErrorAction Stop

            $status = $pollResponse.status
            if ($status -eq 'Succeeded') {
                Write-Host "Assessment completed. Available patches: $(($pollResponse.properties.availablePatchCountByClassification | ConvertTo-Json -Compress))"
                return $pollResponse.properties
            }
            elseif ($status -eq 'Failed') {
                throw "Patch assessment failed: $($pollResponse.properties.error | ConvertTo-Json -Compress)"
            }

            Write-Host "Assessment status: $status. Polling again in ${PollIntervalSeconds}s..."
        }
        catch {
            if ($_.Exception.Message -notmatch 'assessment failed') {
                Write-Warning "Poll error (will retry): $_"
            }
            else { throw }
        }
    }

    throw "Patch assessment timed out after $TimeoutMinutes minutes."
}

function Invoke-CatchUpInstallation {
    <#
    .SYNOPSIS
        Triggers an on-demand patch installation on an Arc machine (fire-and-forget).
        Uses the classifications from the machine's maintenance configuration.
    .DESCRIPTION
        Determines the OS type, builds the installPatches request body using the
        provided classifications, and POSTs to the Azure Update Manager API.
        Returns immediately after the API accepts the request (202).
    .OUTPUTS
        PSCustomObject with InstallationTriggered (bool) and AsyncOperationUrl (string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][PSCustomObject]$Classifications,
        [string]$RebootSetting = 'IfRequired',
        [string]$MaxDuration = 'PT4H'
    )

    # Determine OS type from the machine resource
    $machineUri = "https://management.azure.com${ResourceId}?api-version=$script:ApiVersion"
    $machine = Invoke-ArmRestMethod -Method 'GET' -Uri $machineUri
    $osType = $machine.properties.osType  # "Windows" or "Linux"

    Write-Host "Machine OS type: $osType. Building install request..."

    # Build the request body based on OS type
    $body = @{
        maximumDuration = $MaxDuration
        rebootSetting   = $RebootSetting
    }

    if ($osType -eq 'Windows') {
        $body.windowsParameters = @{
            classificationsToInclude = $Classifications.WindowsClassifications
        }
    }
    else {
        $body.linuxParameters = @{
            classificationsToInclude = $Classifications.LinuxClassifications
        }
    }

    $installUri = "https://management.azure.com${ResourceId}/installPatches?api-version=$script:ApiVersion"
    $bodyJson = $body | ConvertTo-Json -Depth 5

    Write-Host "Triggering patch installation for $ResourceId (reboot: $RebootSetting, maxDuration: $MaxDuration)..."

    try {
        $response = Invoke-WebRequest -Method POST -Uri $installUri -Headers @{
            'Authorization' = "Bearer $(Get-AzRestToken)"
            'Content-Type'  = 'application/json'
        } -Body $bodyJson -ErrorAction Stop

        $asyncUrl = $response.Headers['Azure-AsyncOperation'] ?? $response.Headers['Location']

        Write-Host "Patch installation triggered successfully (fire-and-forget). Async operation: $asyncUrl"

        return [PSCustomObject]@{
            InstallationTriggered = $true
            AsyncOperationUrl     = $asyncUrl
            OsType                = $osType
            Classifications       = if ($osType -eq 'Windows') { $Classifications.WindowsClassifications } else { $Classifications.LinuxClassifications }
        }
    }
    catch {
        # 202 Accepted is expected and may come through as an exception with Invoke-WebRequest
        if ($_.Exception.Response.StatusCode.value__ -eq 202) {
            $asyncUrl = $_.Exception.Response.Headers.GetValues('Azure-AsyncOperation') | Select-Object -First 1
            if (-not $asyncUrl) {
                $asyncUrl = $_.Exception.Response.Headers.Location?.ToString()
            }

            Write-Host "Patch installation accepted (202). Async operation: $asyncUrl"

            return [PSCustomObject]@{
                InstallationTriggered = $true
                AsyncOperationUrl     = $asyncUrl
                OsType                = $osType
                Classifications       = if ($osType -eq 'Windows') { $Classifications.WindowsClassifications } else { $Classifications.LinuxClassifications }
            }
        }

        throw "Failed to trigger patch installation: $_"
    }
}

function Get-TotalAvailablePatches {
    <#
    .SYNOPSIS
        Sums up the total available patches from an assessment result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$AssessmentResult
    )

    $counts = $AssessmentResult.availablePatchCountByClassification
    if (-not $counts) { return 0 }

    $total = 0
    $counts.PSObject.Properties | ForEach-Object {
        if ($_.Value -is [int]) { $total += $_.Value }
    }
    return $total
}

Export-ModuleMember -Function @(
    'Test-OfflineDuration'
    'Get-MaintenanceConfigClassifications'
    'Test-MissedMaintenanceWindow'
    'Invoke-CatchUpAssessment'
    'Invoke-CatchUpInstallation'
    'Get-TotalAvailablePatches'
)
