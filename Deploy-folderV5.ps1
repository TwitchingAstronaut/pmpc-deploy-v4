param(
    [switch]$Redeploy,

    # --- Reusable settings: override any of these to point the script at a
    #     different site, collection, schedule, or log location. ---
    [string]$SiteCode          = "HOM",
    [string]$CollectionName    = "Endpoints",
    [string]$ModulePath        = "$($env:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1",
    [string]$TranscriptLogPath = "C:\scripts\Deploy-folder.log",
    [string]$CMTraceLogPath    = "C:\Temp\Deploy-PMPC.log",
    [string]$LogComponent      = "Deploy-PMPC",
    [int]$AvailableHour        = 6,
    [int]$DeadlineHour         = 9,
    [string]$DeployAction      = "Install",
    [string]$UserNotification  = "DisplaySoftwareCenterOnly",

    # Category names (as tagged on the application in ConfigMgr) that mark
    # an app for Required vs. Available deployment.
    [string]$RequiredCategoryName  = "Required",
    [string]$AvailableCategoryName = "Available"
)

# --- CMTrace Logging Function ---
function Write-CMTraceLog {
    param(
        [string]$Message,
        [string]$Component = $LogComponent,
        [int]$Type = 1  # 1=Info, 2=Warning, 3=Error
    )

    $Time = (Get-Date).ToString("HH:mm:ss.fff")
    $Date = (Get-Date).ToString("MM-dd-yyyy")
    $LogLine = "<![LOG[$Message]LOG]!><time=""$Time"" date=""$Date"" component=""$Component"" type=""$Type"" thread=""1"" file="""">"

    Add-Content -Path $CMTraceLogPath -Value $LogLine
}

# C6: ensure log directory exists before any logging calls
$CMTraceLogDir = Split-Path -Parent $CMTraceLogPath
if (-not (Test-Path $CMTraceLogDir)) {
    New-Item -ItemType Directory -Path $CMTraceLogDir -Force | Out-Null
}

Start-Transcript -Path $TranscriptLogPath -Append

# C4: catch module import failure rather than silently continuing
try {
    Import-Module $ModulePath -ErrorAction Stop
} catch {
    Write-Host "Failed to import ConfigurationManager module: $_" -ForegroundColor Red
    Write-CMTraceLog "Failed to import ConfigurationManager module: $_" "Deploy-PMPC" 3
    Stop-Transcript
    exit 1
}

Set-Location "$SiteCode`:"

# C2: advance timestamps to tomorrow if the deadline has already passed today;
#     otherwise, if only the available slot has passed, make it available now
$Now           = Get-Date
$AvailableTime = (Get-Date -Hour $AvailableHour -Minute 0 -Second 0)
$DeadlineTime  = (Get-Date -Hour $DeadlineHour -Minute 0 -Second 0)

if ($Now -ge $DeadlineTime) {
    $AvailableTime = $AvailableTime.AddDays(1)
    $DeadlineTime  = $DeadlineTime.AddDays(1)
} elseif ($Now -ge $AvailableTime) {
    # Deadline is still ahead today, but the available slot has already
    # passed — make it available immediately rather than backdating it.
    $AvailableTime = $Now
}

Write-CMTraceLog "Starting PMPC deployment script"
Write-CMTraceLog "Redeploy flag: $Redeploy"
Write-CMTraceLog "AvailableTime: $AvailableTime  DeadlineTime: $DeadlineTime"

# C9: shared helper so REQUIRED/AVAILABLE creation, error handling, and logging
#     live in one place instead of two near-identical blocks.
function New-PMPCDeployment {
    param(
        [Parameter(Mandatory)][string]$CollectionName,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][ValidateSet("Required", "Available")][string]$Purpose,
        [datetime]$AvailableDateTime,
        [datetime]$DeadlineDateTime
    )

    $Label = $Purpose.ToUpper()
    Write-Host "  Deploying as $Label" -ForegroundColor Cyan
    Write-CMTraceLog "Deploying $AppName as $Label"

    $Params = @{
        CollectionName   = $CollectionName
        Name             = $AppName
        DeployAction     = $DeployAction
        DeployPurpose    = $Purpose
        UserNotification = $UserNotification
        ErrorAction      = "Stop"
    }
    if ($Purpose -eq "Required") {
        $Params["AvailableDateTime"] = $AvailableDateTime
        $Params["DeadlineDateTime"]  = $DeadlineDateTime
    }

    try {
        New-CMApplicationDeployment @Params | Out-Null
        Write-CMTraceLog "$Label deployment created for $AppName"
    } catch {
        Write-Host "  Failed to create $Label deployment for $AppName`: $_" -ForegroundColor Red
        Write-CMTraceLog "Failed to create $Label deployment for $AppName`: $_" "Deploy-PMPC" 3
    }
}

$Apps = Get-WmiObject -Namespace "root\sms\site_$SiteCode" -Class SMS_ApplicationLatest

if (-not $Apps) {
    Write-CMTraceLog "No applications found in SMS_ApplicationLatest" "Deploy-PMPC" 3
    Write-Host "No applications found." -ForegroundColor Red
    # C1: call Stop-Transcript before all early exits
    Stop-Transcript
    exit 1
}

Write-CMTraceLog "Found $($Apps.Count) applications in SMS_ApplicationLatest"

# C7: pre-fetch all deployments once; avoid one SMS Provider round-trip per app.
# C5: ApplicationName on deployment objects mirrors LocalizedDisplayName at creation time;
#     apps renamed after deployment may not match — investigate if duplicates appear.
$AllDeployments = Get-CMDeployment -CollectionName $CollectionName
$DeploymentMap  = @{}
foreach ($dep in $AllDeployments) {
    if (-not $DeploymentMap.ContainsKey($dep.ApplicationName)) {
        $DeploymentMap[$dep.ApplicationName] = [System.Collections.Generic.List[object]]::new()
    }
    $DeploymentMap[$dep.ApplicationName].Add($dep)
}

foreach ($AppCI in $Apps) {

    $AppName  = $AppCI.LocalizedDisplayName
    $Category = $AppCI.LocalizedCategoryInstanceNames

    Write-Host "Processing: $AppName ($Category)" -ForegroundColor White
    Write-CMTraceLog "Processing $AppName ($Category)"

    $Existing = $DeploymentMap[$AppName]

    if ($Existing -and -not $Redeploy) {
        Write-Host "  Deployment already exists. Skipping." -ForegroundColor Yellow
        Write-CMTraceLog "Deployment already exists for $AppName. Skipping."
        continue
    }

    # C3: $Existing can be a list of multiple objects — iterate to remove each one
    if ($Existing -and $Redeploy) {
        Write-Host "  Removing $($Existing.Count) existing deployment(s)..." -ForegroundColor Cyan
        Write-CMTraceLog "Removing $($Existing.Count) existing deployment(s) for $AppName"

        # C10: track removal failures so a failed removal doesn't fall through
        #      into creating a deployment alongside the one that failed to delete.
        $RemovalFailed = $false
        foreach ($dep in $Existing) {
            try {
                Remove-CMDeployment -InputObject $dep -Force -ErrorAction Stop
            } catch {
                $RemovalFailed = $true
                Write-Host "  Failed to remove existing deployment: $_" -ForegroundColor Red
                Write-CMTraceLog "Failed to remove existing deployment for $AppName`: $_" "Deploy-PMPC" 3
            }
        }

        if ($RemovalFailed) {
            Write-CMTraceLog "Skipping redeploy of $AppName due to removal failure" "Deploy-PMPC" 3
            continue
        }
    }

    $isRequired  = $Category -contains $RequiredCategoryName
    $isAvailable = $Category -contains $AvailableCategoryName

    if (-not $isRequired -and -not $isAvailable) {
        Write-Host "  Unknown category '$Category' — skipping." -ForegroundColor Yellow
        Write-CMTraceLog "Unknown category '$Category' for $AppName — skipping" "Deploy-PMPC" 2
        continue
    }

    # C8: use separate if blocks so a dual-tagged app receives both deployment types
    if ($isRequired -and $isAvailable) {
        Write-CMTraceLog "App '$AppName' is tagged both Required and Available — creating both deployments" "Deploy-PMPC" 2
    }

    if ($isRequired) {
        New-PMPCDeployment -CollectionName $CollectionName -AppName $AppName -Purpose Required `
            -AvailableDateTime $AvailableTime -DeadlineDateTime $DeadlineTime
    }

    if ($isAvailable) {
        New-PMPCDeployment -CollectionName $CollectionName -AppName $AppName -Purpose Available
    }
}

Write-Host "All deployments completed." -ForegroundColor Cyan
Write-CMTraceLog "All deployments completed successfully"

Stop-Transcript
