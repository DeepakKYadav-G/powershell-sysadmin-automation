# ============================================================
# STORE BACKUP SYNC - PARALLEL VERSION
# Pulls the latest .bak file from each store to a central NAS,
# running several stores concurrently (see -MaxParallel).
# ============================================================

#requires -Version 5.1

[CmdletBinding()]
param(
    # CSV with columns: StoreName, StoreIP, AdminUsername, AdminPassword, BackupPath, NASPath
    [string]$CsvPath = (Join-Path $PSScriptRoot "stores.csv"),

    [string]$LogFolder = (Join-Path $PSScriptRoot "Logs"),

    # Maximum number of stores running at the same time
    [ValidateRange(1,50)]
    [int]$MaxParallel = 10
)

# ------------------------------------------------------------
# LOG SETUP
# ------------------------------------------------------------

if (-not (Test-Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}

$RunTime = Get-Date -Format "yyyy-MM-dd_HHmmss"
$LogFile = Join-Path $LogFolder "StoreBackupSync_$RunTime.log"

# ------------------------------------------------------------
# MAIN LOG FUNCTION
# ------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$TimeStamp] [$Level] $Message"

    Add-Content -Path $LogFile -Value $LogLine

    switch ($Level) {
        "SUCCESS" { Write-Host $LogLine -ForegroundColor Green }
        "ERROR"   { Write-Host $LogLine -ForegroundColor Red }
        "WARNING" { Write-Host $LogLine -ForegroundColor Yellow }
        default   { Write-Host $LogLine }
    }
}

# ------------------------------------------------------------
# START
# ------------------------------------------------------------

Write-Log "============================================================"
Write-Log "STORE BACKUP SYNC STARTED - PARALLEL MODE"
Write-Log "CSV File: $CsvPath"
Write-Log "Log File: $LogFile"
Write-Log "Maximum parallel stores: $MaxParallel"
Write-Log "============================================================"

# ------------------------------------------------------------
# READ CSV
# ------------------------------------------------------------

try {
    $Stores = Import-Csv $CsvPath -ErrorAction Stop
    Write-Log "Loaded $($Stores.Count) store(s) from CSV."
}
catch {
    Write-Log "Cannot read CSV: $($_.Exception.Message)" "ERROR"
    exit 1
}

# ------------------------------------------------------------
# STORE PROCESSING SCRIPT
# This runs independently for each store.
# ------------------------------------------------------------

$StoreScript = {

    param(
        [object]$Store,
        [string]$StoreLogFolder
    )

    $StoreName      = $Store.StoreName
    $StoreIP        = $Store.StoreIP
    $AdminUsername  = $Store.AdminUsername
    $AdminPassword  = $Store.AdminPassword
    $BackupPath     = $Store.BackupPath
    $NASPath        = $Store.NASPath

    $ShareName  = "StoreFullBackup"
    $StoreShare = "\\$StoreIP\$ShareName"

    # Each store gets its own log.
    # This prevents parallel Robocopy processes from fighting over
    # the same log file.
    $StoreSafeName = ($StoreName -replace '[\\/:*?"<>| ]', '_')
    $StoreLogFile = Join-Path $StoreLogFolder "Store_${StoreSafeName}.log"

    function Store-Log {
        param(
            [string]$Message,
            [string]$Level = "INFO"
        )

        $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $LogLine = "[$TimeStamp] [$Level] $Message"

        Add-Content -Path $StoreLogFile -Value $LogLine

        [PSCustomObject]@{
            Type    = "LOG"
            Store   = $StoreName
            Level   = $Level
            Message = $Message
            Time    = $TimeStamp
        }
    }

    $StartTime = Get-Date
    $Session = $null
    $Completed = $false
    $Result = "FAILED"
    $ErrorMessage = ""

    Store-Log "============================================================"
    Store-Log "PROCESSING STORE: $StoreName"
    Store-Log "============================================================"
    Store-Log "Store IP       : $StoreIP"
    Store-Log "Backup Path    : $BackupPath"
    Store-Log "NAS Destination: $NASPath"

    try {

        # --------------------------------------------------------
        # CREATE CREDENTIAL
        # --------------------------------------------------------

        Store-Log "Creating credential object..."

        $SecurePassword = ConvertTo-SecureString `
            $AdminPassword `
            -AsPlainText `
            -Force

        $Credential = New-Object `
            System.Management.Automation.PSCredential(
                $AdminUsername,
                $SecurePassword
            )

        # --------------------------------------------------------
        # CONNECT TO STORE
        # --------------------------------------------------------

        Store-Log "Connecting to store using PowerShell Remoting..."

        $Session = New-PSSession `
            -ComputerName $StoreIP `
            -Credential $Credential `
            -ErrorAction Stop

        Store-Log "PowerShell Remoting connection successful." "SUCCESS"

        # --------------------------------------------------------
        # CHECK BACKUP FOLDER AND CREATE SMB SHARE
        # --------------------------------------------------------

        Store-Log "Checking backup folder and SMB share..."

        $ShareResult = Invoke-Command `
            -Session $Session `
            -ScriptBlock {

                param(
                    $BackupPath,
                    $ShareName
                )

                if (-not (Test-Path $BackupPath)) {
                    throw "Backup folder does not exist: $BackupPath"
                }

                $ExistingShare = Get-SmbShare `
                    -Name $ShareName `
                    -ErrorAction SilentlyContinue

                if ($ExistingShare) {

                    [PSCustomObject]@{
                        Status = "EXISTING"
                        Share  = $ShareName
                        Path   = $BackupPath
                    }

                }
                else {

                    New-SmbShare `
                        -Name $ShareName `
                        -Path $BackupPath `
                        -ChangeAccess "Administrators" `
                        -ErrorAction Stop | Out-Null

                    [PSCustomObject]@{
                        Status = "CREATED"
                        Share  = $ShareName
                        Path   = $BackupPath
                    }
                }

            } `
            -ArgumentList $BackupPath, $ShareName `
            -ErrorAction Stop

        Store-Log "Share status: $($ShareResult.Status)" "SUCCESS"
        Store-Log "Share path: $StoreShare"

        # --------------------------------------------------------
        # AUTHENTICATE TO STORE SMB SHARE
        # --------------------------------------------------------

        Store-Log "Authenticating to store SMB share..."

        net use $StoreShare /delete /y 2>$null | Out-Null

        $UserForSMB = "$StoreIP\$AdminUsername"

        net use $StoreShare `
            /user:$UserForSMB `
            $AdminPassword `
            2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "SMB authentication failed. Robocopy cannot access the store."
        }

        if (-not (Test-Path $StoreShare)) {
            throw "SMB authentication succeeded but share is not accessible."
        }

        Store-Log "SMB connection successful." "SUCCESS"

        # --------------------------------------------------------
        # FIND LATEST BACKUP
        # --------------------------------------------------------

        Store-Log "Searching for latest .bak file..."

        $LatestBackup = Get-ChildItem `
            -Path "$StoreShare\*.bak" `
            -File `
            -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if (-not $LatestBackup) {
            throw "No .bak backup file found."
        }

        $BackupSizeMB = [math]::Round(
            $LatestBackup.Length / 1MB,
            2
        )

        Store-Log "Latest backup found." "SUCCESS"
        Store-Log "File : $($LatestBackup.Name)"
        Store-Log "Size : $BackupSizeMB MB"
        Store-Log "Time : $($LatestBackup.LastWriteTime)"

        # --------------------------------------------------------
        # CHECK NAS
        # --------------------------------------------------------

        Store-Log "Checking NAS destination..."

        if (-not (Test-Path $NASPath)) {

            Store-Log "NAS folder does not exist. Creating it..." "WARNING"

            New-Item `
                -Path $NASPath `
                -ItemType Directory `
                -Force `
                -ErrorAction Stop | Out-Null

            Store-Log "NAS folder created." "SUCCESS"

        }
        else {
            Store-Log "NAS destination exists." "SUCCESS"
        }

        # --------------------------------------------------------
        # ROBOCOPY
        # --------------------------------------------------------

        Store-Log "Starting Robocopy..."
        Store-Log "Source: $StoreShare"
        Store-Log "Destination: $NASPath"
        Store-Log "File: $($LatestBackup.Name)"

        # Robocopy gets its own per-store log.
        # This is important when multiple stores copy simultaneously.
        $RobocopyLog = Join-Path `
            $StoreLogFolder `
            "Robocopy_${StoreSafeName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

        robocopy `
            $StoreShare `
            $NASPath `
            $LatestBackup.Name `
            /Z `
            /J `
            /R:3 `
            /W:5 `
            /COPY:DAT `
            /V `
            /TEE `
            /LOG:"$RobocopyLog"

        $RobocopyExitCode = $LASTEXITCODE

        Store-Log "Robocopy exit code: $RobocopyExitCode"

        # Robocopy 0-7 = successful/non-fatal result
        if ($RobocopyExitCode -le 7) {
            Store-Log "Robocopy completed successfully." "SUCCESS"
        }
        else {
            throw "Robocopy FAILED. Exit code: $RobocopyExitCode"
        }

        # --------------------------------------------------------
        # VERIFY DESTINATION
        # --------------------------------------------------------

        Store-Log "Verifying copied file..."

        $DestinationFile = Join-Path `
            $NASPath `
            $LatestBackup.Name

        if (-not (Test-Path $DestinationFile)) {
            throw "Destination file does not exist."
        }

        $DestinationInfo = Get-Item `
            $DestinationFile `
            -ErrorAction Stop

        Store-Log "Destination file found."
        Store-Log "Destination size: $($DestinationInfo.Length) bytes"
        Store-Log "Source size     : $($LatestBackup.Length) bytes"

        if ($DestinationInfo.Length -ne $LatestBackup.Length) {
            throw "File size mismatch."
        }

        Store-Log "File size verification PASSED." "SUCCESS"

        $Completed = $true
        $Result = "SUCCESS"

    }
    catch {

        $ErrorMessage = $_.Exception.Message

        Store-Log "FAILED: $ErrorMessage" "ERROR"
    }
    finally {

        # --------------------------------------------------------
        # CLEANUP
        # --------------------------------------------------------

        if ($StoreShare) {
            net use $StoreShare /delete /y 2>$null | Out-Null
        }

        if ($Session) {
            Remove-PSSession $Session -ErrorAction SilentlyContinue
        }

        $EndTime = Get-Date
        $Duration = $EndTime - $StartTime

        Store-Log "Store $StoreName finished with status: $Result"
        Store-Log "Duration: $($Duration.ToString('hh\:mm\:ss'))"
        Store-Log "============================================================"

        [PSCustomObject]@{
            Type          = "RESULT"
            StoreName     = $StoreName
            StoreIP       = $StoreIP
            Result        = $Result
            ErrorMessage  = $ErrorMessage
            StartTime     = $StartTime
            EndTime       = $EndTime
            Duration      = $Duration.ToString('hh\:mm\:ss')
            StoreLogFile  = $StoreLogFile
        }
    }
}

# ------------------------------------------------------------
# PARALLEL JOB MANAGEMENT
# ------------------------------------------------------------

$Jobs = @()
$Results = @()
$NextStoreIndex = 0

while (
    ($NextStoreIndex -lt $Stores.Count) -or
    ($Jobs.Count -gt 0)
) {

    # --------------------------------------------------------
    # START NEW JOBS UNTIL MAX PARALLEL LIMIT IS REACHED
    # --------------------------------------------------------

    while (
        ($NextStoreIndex -lt $Stores.Count) -and
        ($Jobs.Count -lt $MaxParallel)
    ) {

        $Store = $Stores[$NextStoreIndex]

        Write-Log "STARTING PARALLEL JOB: Store $($Store.StoreName)"

        $Job = Start-Job `
            -ScriptBlock $StoreScript `
            -ArgumentList $Store, $LogFolder

        $Jobs += $Job
        $NextStoreIndex++
    }

    # --------------------------------------------------------
    # CHECK FOR COMPLETED JOBS
    # --------------------------------------------------------

    $CompletedJobs = @(
        $Jobs | Where-Object {
            $_.State -in @("Completed", "Failed", "Stopped")
        }
    )

    foreach ($Job in $CompletedJobs) {

        try {

            $JobOutput = Receive-Job `
                -Job $Job `
                -ErrorAction SilentlyContinue

            # Pick out the final RESULT object.
            $JobResult = $JobOutput |
                Where-Object { $_.Type -eq "RESULT" } |
                Select-Object -Last 1

            if ($JobResult) {

                $Results += $JobResult

                if ($JobResult.Result -eq "SUCCESS") {

                    Write-Log `
                        "STORE COMPLETED: $($JobResult.StoreName) | Duration: $($JobResult.Duration)" `
                        "SUCCESS"

                }
                else {

                    Write-Log `
                        "STORE FAILED: $($JobResult.StoreName) | $($JobResult.ErrorMessage)" `
                        "ERROR"
                }

            }
            else {

                Write-Log `
                    "JOB FINISHED WITHOUT RESULT. Job ID: $($Job.Id)" `
                    "ERROR"
            }

        }
        catch {

            Write-Log `
                "Error receiving job $($Job.Id): $($_.Exception.Message)" `
                "ERROR"
        }

        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue

        $Jobs = @(
            $Jobs | Where-Object { $_.Id -ne $Job.Id }
        )
    }

    # --------------------------------------------------------
    # SMALL DELAY
    # Prevents excessive CPU usage while polling jobs.
    # --------------------------------------------------------

    if ($Jobs.Count -gt 0) {
        Start-Sleep -Seconds 2
    }
}

# ------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------

$SuccessCount = @(
    $Results | Where-Object { $_.Result -eq "SUCCESS" }
).Count

$FailedCount = @(
    $Results | Where-Object { $_.Result -ne "SUCCESS" }
).Count

Write-Log ""
Write-Log "============================================================"
Write-Log "STORE BACKUP SYNC FINISHED"
Write-Log "============================================================"
Write-Log "Total stores : $($Stores.Count)"
Write-Log "Successful   : $SuccessCount" "SUCCESS"
Write-Log "Failed       : $FailedCount"

if ($FailedCount -gt 0) {

    Write-Log ""
    Write-Log "FAILED STORE SUMMARY:" "WARNING"

    foreach ($Failed in ($Results | Where-Object { $_.Result -ne "SUCCESS" })) {

        Write-Log `
            "Store: $($Failed.StoreName) | IP: $($Failed.StoreIP) | Error: $($Failed.ErrorMessage)" `
            "ERROR"
    }
}

Write-Log ""
Write-Log "Detailed per-store logs are in: $LogFolder"
Write-Log "Main Log File: $LogFile"
Write-Log "============================================================"
