# PMPC Deploy

PowerShell script that auto-deploys ConfigMgr (SCCM) applications to a
collection based on each application's category tags.

Two versions are included:

- **`Deploy-folderV4.ps1`** — original script, settings hardcoded for site
  `HOM` / collection `Endpoints`.
- **`Deploy-folderV5.ps1`** — same behavior, but every setting (site,
  collection, schedule, log paths, category names, etc.) is a script
  parameter with the v4 values as defaults, so it can be reused against
  other sites/collections without editing the script.

## What it does

1. Imports the ConfigurationManager module and connects to the target site.
2. Enumerates all applications in `SMS_ApplicationLatest`.
3. For each application, checks its category (Required / Available) and its
   existing deployments to the target collection:
   - No existing deployment → creates one.
   - Existing deployment, `-Redeploy` not passed → skips it.
   - Existing deployment, `-Redeploy` passed → removes the existing
     deployment(s) and recreates them.
   - An app tagged both Required and Available gets both deployment types.
   - An app with neither category tag is skipped with a warning.
4. Required deployments get an `AvailableDateTime`/`DeadlineDateTime`
   schedule (same day if that window hasn't passed yet, otherwise the next
   day; if only the available slot has passed, it becomes available
   immediately). Available deployments have no schedule.
5. Logs progress to the console, a PowerShell transcript, and a
   CMTrace-formatted log.

## Usage

### v4 (fixed settings)

```powershell
# Deploy any applications that don't already have a deployment
.\Deploy-folderV4.ps1

# Also remove and recreate deployments for applications that already have one
.\Deploy-folderV4.ps1 -Redeploy
```

### v5 (reusable, parameterized)

```powershell
# Same behavior as v4, using the same defaults
.\Deploy-folderV5.ps1 -Redeploy

# Point at a different site/collection with a different schedule and category tags
.\Deploy-folderV5.ps1 `
    -SiteCode "ABC" `
    -CollectionName "Workstations" `
    -AvailableHour 7 -DeadlineHour 10 `
    -RequiredCategoryName "Mandatory" -AvailableCategoryName "Optional"
```

## Parameters

### v4

| Parameter   | Type   | Description                                                        |
|-------------|--------|----------------------------------------------------------------------|
| `-Redeploy` | switch | Remove existing deployments in the collection and recreate them.   |

### v5

| Parameter                | Type   | Default                                                     | Description                                                    |
|---------------------------|--------|--------------------------------------------------------------|------------------------------------------------------------------|
| `-Redeploy`                | switch | (off)                                                         | Remove existing deployments in the collection and recreate them. |
| `-SiteCode`                | string | `HOM`                                                         | ConfigMgr site code to connect to.                                |
| `-CollectionName`          | string | `Endpoints`                                                   | Target collection for deployments.                                |
| `-ModulePath`              | string | `$env:SMS_ADMIN_UI_PATH\..\ConfigurationManager.psd1`         | Path to the ConfigurationManager module.                          |
| `-TranscriptLogPath`       | string | `C:\scripts\Deploy-folder.log`                                | PowerShell transcript output path.                                |
| `-CMTraceLogPath`          | string | `C:\Temp\Deploy-PMPC.log`                                     | CMTrace-formatted log output path.                                |
| `-LogComponent`            | string | `Deploy-PMPC`                                                 | Component name shown in the CMTrace log.                          |
| `-AvailableHour`           | int    | `6`                                                           | Hour (24h) Required deployments become available.                 |
| `-DeadlineHour`            | int    | `9`                                                           | Hour (24h) Required deployments are due.                          |
| `-DeployAction`            | string | `Install`                                                     | Deployment action passed to `New-CMApplicationDeployment`.        |
| `-UserNotification`        | string | `DisplaySoftwareCenterOnly`                                   | User notification setting for the deployment.                     |
| `-RequiredCategoryName`    | string | `Required`                                                    | Category name that marks an app for Required deployment.          |
| `-AvailableCategoryName`   | string | `Available`                                                   | Category name that marks an app for Available deployment.         |

## Requirements

- Windows PowerShell with the ConfigurationManager console installed
  (`$env:SMS_ADMIN_UI_PATH` must be set).
- Permissions to read applications/deployments and create/remove
  deployments on the target site and collection.

## Logging

- **Transcript**: full console output, appended on each run
  (`-TranscriptLogPath` in v5, fixed at `C:\scripts\Deploy-folder.log` in v4).
- **CMTrace log**: structured log viewable in CMTrace, including
  create/remove failures (`-CMTraceLogPath` in v5, fixed at
  `C:\Temp\Deploy-PMPC.log` in v4).

If an application's deployment removal or creation fails, the failure is
logged and that application is skipped rather than left in a partial state.
