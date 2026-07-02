# PMPC Deploy v4

PowerShell script that auto-deploys ConfigMgr (SCCM) applications to the
`Endpoints` collection based on each application's category tags.

## What it does

1. Imports the ConfigurationManager module and connects to site `HOM`.
2. Enumerates all applications in `SMS_ApplicationLatest`.
3. For each application, checks its category (`Required` / `Available`) and
   its existing deployments to the `Endpoints` collection:
   - No existing deployment → creates one.
   - Existing deployment, `-Redeploy` not passed → skips it.
   - Existing deployment, `-Redeploy` passed → removes the existing
     deployment(s) and recreates them.
   - An app tagged both `Required` and `Available` gets both deployment
     types.
   - An app with neither category tag is skipped with a warning.
4. Required deployments get an `AvailableDateTime` of 06:00 and a
   `DeadlineDateTime` of 09:00 (same day if that window hasn't passed yet,
   otherwise the next day; if only the 06:00 slot has passed, it becomes
   available immediately). Available deployments have no schedule.
5. Logs progress to the console, a PowerShell transcript
   (`C:\scripts\Deploy-folder.log`), and a CMTrace-formatted log
   (`C:\Temp\Deploy-PMPC.log`).

## Usage

```powershell
# Deploy any applications that don't already have a deployment
.\Deploy-folderV4.ps1

# Also remove and recreate deployments for applications that already have one
.\Deploy-folderV4.ps1 -Redeploy
```

## Parameters

| Parameter   | Type   | Description                                                        |
|-------------|--------|----------------------------------------------------------------------|
| `-Redeploy` | switch | Remove existing deployments in the collection and recreate them.   |

## Requirements

- Windows PowerShell with the ConfigurationManager console installed
  (`$env:SMS_ADMIN_UI_PATH` must be set).
- Permissions to read applications/deployments and create/remove
  deployments on site `HOM`, collection `Endpoints`.

## Logging

- **Transcript**: `C:\scripts\Deploy-folder.log` — full console output,
  appended on each run.
- **CMTrace log**: `C:\Temp\Deploy-PMPC.log` — structured log viewable in
  CMTrace, including create/remove failures.

If an application's deployment removal or creation fails, the failure is
logged and that application is skipped rather than left in a partial state.
