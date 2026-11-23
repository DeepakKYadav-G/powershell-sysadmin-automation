#requires -Version 5.1

<#
=============================================================
 ZABBIX AGENT 6.0.40 - HO REMOTE DEPLOYMENT
=============================================================

Run this script from HO as Administrator.

Purpose:
- Install Zabbix Agent 6.0.40 MSI remotely
- Keep the MSI-created zabbix_agentd.conf
- Modify ONLY:
    Server=
    ServerActive=
- Add ONLY:
    folder.zip.count[*]
    folder.latest.info[*]

The existing MSI configuration is NOT replaced.

Example:
    .\Deploy-Zabbix-From-HO.ps1

Internal server:
    ComputerName = 192.0.2.50
    TunnelIP     = blank

Remote store:
    ComputerName = 198.51.100.20
    TunnelIP     = 203.0.113.20
#>

[CmdletBinding()]
param()

Clear-Host

# =============================================================
# SETTINGS
# =============================================================

$ZabbixServer = "192.0.2.10"   # CHANGE THIS to your Zabbix server IP

$MsiName = "zabbix_agent-6.0.40-windows-amd64-openssl.msi"

$LocalMsi = Join-Path $PSScriptRoot $MsiName

$RemoteInstallDir = "C:\ZabbixInstall"

$RemoteMsi = Join-Path $RemoteInstallDir $MsiName

$ZabbixDir = "C:\Program Files\Zabbix Agent"

$ZabbixExe = Join-Path $ZabbixDir "zabbix_agentd.exe"

$ZabbixConf = Join-Path $ZabbixDir "zabbix_agentd.conf"

$ZabbixService = "Zabbix Agent"

# =============================================================
# USER PARAMETERS
# =============================================================

$UserParameter1 = 'UserParameter=folder.zip.count[*],powershell -Command "Get-ChildItem -Path ''$1'' -Filter *.zip -File | Measure-Object | Select -ExpandProperty Count"'

$UserParameter2 = 'UserParameter=folder.latest.info[*],powershell -NoProfile -Command "$f=Get-ChildItem -Path ''$1'' -File | Where-Object {$_.Length -gt 1MB} | Sort-Object CreationTime -Descending | Select-Object -First 1; if ($f) { Write-Output ($f.CreationTime.ToString(''yyyy-MM-dd HH:mm:ss'') + ''|'' + [math]::Round($f.Length / 1MB, 2)) } else { Write-Output ''NoFile|0'' }"'

# =============================================================
# CHECK MSI
# =============================================================

if (-not (Test-Path $LocalMsi)) {

    Write-Host ""
    Write-Host "ERROR: MSI not found:" -ForegroundColor Red
    Write-Host $LocalMsi -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Put the following MSI in the same folder as this script:"
    Write-Host $MsiName
    exit 1
}

# =============================================================
# INPUT
# =============================================================

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "       ZABBIX AGENT 6.0.40 - HO DEPLOYMENT" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""

$ComputerName = Read-Host "Enter Store Server IP / Computer Name"

if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    Write-Host "ERROR: Computer name/IP is required." -ForegroundColor Red
    exit 1
}

Write-Host ""
$cred = Get-Credential -Message "Enter Windows administrator credentials for $ComputerName"

if (-not $cred) {
    Write-Host "ERROR: Credential was not provided." -ForegroundColor Red
    exit 1
}

Write-Host ""
$TunnelIP = Read-Host "Enter Store Tunnel IP (leave blank for Internal Server)"

# =============================================================
# BUILD SERVER VALUES
# =============================================================

if ([string]::IsNullOrWhiteSpace($TunnelIP)) {

    $ServerValue = $ZabbixServer
    $ServerActiveValue = $ZabbixServer

    Write-Host ""
    Write-Host "Mode: INTERNAL SERVER" -ForegroundColor Cyan
    Write-Host "Server=$ServerValue"
    Write-Host "ServerActive=$ServerActiveValue"
}
else {

    $ServerValue = "$ZabbixServer,$TunnelIP"
    $ServerActiveValue = "$ZabbixServer,$TunnelIP"

    Write-Host ""
    Write-Host "Mode: REMOTE STORE" -ForegroundColor Cyan
    Write-Host "Server=$ServerValue"
    Write-Host "ServerActive=$ServerActiveValue"
}

# =============================================================
# TEST WINRM
# =============================================================

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "Testing WinRM..." -ForegroundColor Cyan
Write-Host "============================================================="

try {

    Test-WSMan `
        -ComputerName $ComputerName `
        -Authentication Negotiate `
        -Credential $cred `
        -ErrorAction Stop | Out-Null

    Write-Host "WinRM: OK" -ForegroundColor Green
}
catch {

    Write-Host ""
    Write-Host "ERROR: WinRM connection failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    exit 1
}

# =============================================================
# CREATE PSSESSION
# =============================================================

Write-Host ""
Write-Host "Creating PowerShell session..." -ForegroundColor Cyan

$session = $null

try {

    $session = New-PSSession `
        -ComputerName $ComputerName `
        -Credential $cred `
        -Authentication Negotiate `
        -ErrorAction Stop

    Write-Host "PowerShell session: OK" -ForegroundColor Green
}
catch {

    Write-Host ""
    Write-Host "ERROR: Could not create PowerShell session." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    exit 1
}

try {

    # =========================================================
    # REMOTE DEPLOYMENT
    # =========================================================

    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "Preparing remote installation folder..." -ForegroundColor Cyan
    Write-Host "============================================================="

    Invoke-Command -Session $session -ScriptBlock {

        param($RemoteInstallDir)

        if (-not (Test-Path $RemoteInstallDir)) {

            New-Item `
                -Path $RemoteInstallDir `
                -ItemType Directory `
                -Force | Out-Null
        }

    } -ArgumentList $RemoteInstallDir

    Write-Host "Remote folder ready." -ForegroundColor Green

    # =========================================================
    # COPY MSI
    # =========================================================

    Write-Host ""
    Write-Host "Copying MSI to remote server..." -ForegroundColor Cyan

    Copy-Item `
        -Path $LocalMsi `
        -Destination $RemoteMsi `
        -ToSession $session `
        -Force

    Write-Host "MSI copied successfully." -ForegroundColor Green

    # =========================================================
    # INSTALL MSI
    # =========================================================

    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "Installing Zabbix Agent 6.0.40..." -ForegroundColor Cyan
    Write-Host "============================================================="

    $InstallResult = Invoke-Command -Session $session -ScriptBlock {

        param(
            $RemoteMsi,
            $ZabbixServer,
            $ZabbixDir
        )

        $LogFile = "C:\ZabbixInstall\zabbix-msi-install.log"

        $Arguments = @(
            "/i"
            "`"$RemoteMsi`""
            "/qn"
            "/norestart"
            "SERVER=$ZabbixServer"
            "SERVERACTIVE=$ZabbixServer"
            "/L*v"
            "`"$LogFile`""
        )

        $process = Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru `
            -WindowStyle Hidden

        [PSCustomObject]@{
            ExitCode = $process.ExitCode
            LogFile  = $LogFile
        }

    } -ArgumentList $RemoteMsi, $ZabbixServer, $ZabbixDir

    Write-Host "MSI Exit Code: $($InstallResult.ExitCode)" -ForegroundColor Cyan

    if ($InstallResult.ExitCode -notin @(0,3010)) {

        Write-Host ""
        Write-Host "ERROR: Zabbix MSI installation failed." -ForegroundColor Red
        Write-Host "MSI Log: $($InstallResult.LogFile)" -ForegroundColor Yellow

        exit 1
    }

    if ($InstallResult.ExitCode -eq 3010) {

        Write-Host "MSI installation completed. Reboot required by MSI, but /norestart was used." -ForegroundColor Yellow
    }
    else {

        Write-Host "MSI installation successful." -ForegroundColor Green
    }

    # =========================================================
    # MODIFY EXISTING CONFIGURATION
    # =========================================================

    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "Modifying existing MSI configuration..." -ForegroundColor Cyan
    Write-Host "============================================================="

    $ConfigResult = Invoke-Command -Session $session -ScriptBlock {

        param(
            $ZabbixDir,
            $ZabbixExe,
            $ZabbixConf,
            $ServerValue,
            $ServerActiveValue,
            $UserParameter1,
            $UserParameter2
        )

        # -----------------------------------------------------
        # Check files
        # -----------------------------------------------------

        if (-not (Test-Path $ZabbixConf)) {

            throw "Zabbix configuration file not found: $ZabbixConf"
        }

        if (-not (Test-Path $ZabbixExe)) {

            throw "Zabbix executable not found: $ZabbixExe"
        }

        # -----------------------------------------------------
        # Backup existing configuration
        # -----------------------------------------------------

        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

        $BackupFile = Join-Path `
            $ZabbixDir `
            "zabbix_agentd.conf.before-HO-rollout-$Timestamp.bak"

        Copy-Item `
            -Path $ZabbixConf `
            -Destination $BackupFile `
            -Force

        # -----------------------------------------------------
        # READ ORIGINAL FILE AS BYTES
        #
        # This is important.
        #
        # We don't use:
        #     Set-Content -Encoding UTF8
        #
        # because Windows PowerShell 5.1 can add a UTF-8 BOM,
        # which caused:
        #
        #     ﻿#
        #
        # in the Zabbix configuration.
        # -----------------------------------------------------

        [byte[]]$bytes = [System.IO.File]::ReadAllBytes($ZabbixConf)

        # -----------------------------------------------------
        # Detect encoding
        # -----------------------------------------------------

        $encoding = $null
        $startIndex = 0

        # UTF-8 BOM
        if (
            $bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and
            $bytes[1] -eq 0xBB -and
            $bytes[2] -eq 0xBF
        ) {

            $encoding = New-Object System.Text.UTF8Encoding($true)
            $startIndex = 3
        }

        # UTF-16 Little Endian BOM
        elseif (
            $bytes.Length -ge 2 -and
            $bytes[0] -eq 0xFF -and
            $bytes[1] -eq 0xFE
        ) {

            $encoding = New-Object System.Text.UnicodeEncoding($false, $true)
            $startIndex = 2
        }

        # UTF-16 Big Endian BOM
        elseif (
            $bytes.Length -ge 2 -and
            $bytes[0] -eq 0xFE -and
            $bytes[1] -eq 0xFF
        ) {

            $encoding = New-Object System.Text.UnicodeEncoding($true, $true)
            $startIndex = 2
        }

        # No BOM
        else {

            # MSI configuration is normally ASCII/UTF-8 compatible.
            # Use UTF-8 WITHOUT BOM.
            $encoding = New-Object System.Text.UTF8Encoding($false)
            $startIndex = 0
        }

        # -----------------------------------------------------
        # Decode configuration
        # -----------------------------------------------------

        $text = $encoding.GetString(
            $bytes,
            $startIndex,
            $bytes.Length - $startIndex
        )

        # -----------------------------------------------------
        # Preserve existing line-ending style
        # -----------------------------------------------------

        if ($text.Contains("`r`n")) {

            $NewLine = "`r`n"
        }
        elseif ($text.Contains("`n")) {

            $NewLine = "`n"
        }
        else {

            $NewLine = "`r`n"
        }

        # -----------------------------------------------------
        # Split into lines WITHOUT replacing the whole config
        # -----------------------------------------------------

        $lines = $text -split "\r\n|\n|\r"

        $ServerChanged = $false
        $ServerActiveChanged = $false

        # -----------------------------------------------------
        # Change ONLY Server=
        # -----------------------------------------------------

        for ($i = 0; $i -lt $lines.Count; $i++) {

            if (
                -not $ServerChanged -and
                $lines[$i] -match '^\s*Server\s*='
            ) {

                $lines[$i] = "Server=$ServerValue"
                $ServerChanged = $true
            }
        }

        # -----------------------------------------------------
        # Change ONLY ServerActive=
        # -----------------------------------------------------

        for ($i = 0; $i -lt $lines.Count; $i++) {

            if (
                -not $ServerActiveChanged -and
                $lines[$i] -match '^\s*ServerActive\s*='
            ) {

                $lines[$i] = "ServerActive=$ServerActiveValue"
                $ServerActiveChanged = $true
            }
        }

        if (-not $ServerChanged) {

            throw "Active Server= parameter was not found in MSI-created configuration."
        }

        if (-not $ServerActiveChanged) {

            throw "Active ServerActive= parameter was not found in MSI-created configuration."
        }

        # -----------------------------------------------------
        # Check whether UserParameters already exist
        # -----------------------------------------------------

        $UserParameter1Exists = $false
        $UserParameter2Exists = $false

        foreach ($line in $lines) {

            if ($line -eq $UserParameter1) {

                $UserParameter1Exists = $true
            }

            if ($line -eq $UserParameter2) {

                $UserParameter2Exists = $true
            }
        }

        # -----------------------------------------------------
        # Add ONLY missing UserParameters
        # -----------------------------------------------------

        $AddedParameters = @()

        if (-not $UserParameter1Exists) {

            $lines += $UserParameter1
            $AddedParameters += "folder.zip.count[*]"
        }

        if (-not $UserParameter2Exists) {

            $lines += $UserParameter2
            $AddedParameters += "folder.latest.info[*]"
        }

        # -----------------------------------------------------
        # Rebuild text using SAME line-ending style
        # -----------------------------------------------------

        $newText = [string]::Join($NewLine, $lines)

        # -----------------------------------------------------
        # IMPORTANT:
        #
        # If original file had NO BOM, write NO BOM.
        #
        # If original had BOM, preserve that encoding.
        # -----------------------------------------------------

        $outputBytes = $encoding.GetBytes($newText)

        if ($startIndex -gt 0) {

            # Preserve original BOM
            $bom = New-Object byte[] $startIndex

            [Array]::Copy(
                $bytes,
                0,
                $bom,
                0,
                $startIndex
            )

            $finalBytes = New-Object byte[] (
                $bom.Length + $outputBytes.Length
            )

            [Array]::Copy(
                $bom,
                0,
                $finalBytes,
                0,
                $bom.Length
            )

            [Array]::Copy(
                $outputBytes,
                0,
                $finalBytes,
                $bom.Length,
                $outputBytes.Length
            )

            [System.IO.File]::WriteAllBytes(
                $ZabbixConf,
                $finalBytes
            )
        }
        else {

            [System.IO.File]::WriteAllBytes(
                $ZabbixConf,
                $outputBytes
            )
        }

        [PSCustomObject]@{
            BackupFile              = $BackupFile
            ServerChanged            = $ServerChanged
            ServerActiveChanged      = $ServerActiveChanged
            AddedParameters          = ($AddedParameters -join ", ")
            ServerValue              = $ServerValue
            ServerActiveValue        = $ServerActiveValue
        }

    } -ArgumentList `
        $ZabbixDir,
        $ZabbixExe,
        $ZabbixConf,
        $ServerValue,
        $ServerActiveValue,
        $UserParameter1,
        $UserParameter2

    Write-Host ""
    Write-Host "Configuration backup:" -ForegroundColor Green
    Write-Host $ConfigResult.BackupFile

    Write-Host ""
    Write-Host "Server changed:       $($ConfigResult.ServerChanged)" -ForegroundColor Green
    Write-Host "ServerActive changed: $($ConfigResult.ServerActiveChanged)" -ForegroundColor Green

    if ([string]::IsNullOrWhiteSpace($ConfigResult.AddedParameters)) {

        Write-Host "UserParameters: already present" -ForegroundColor Green
    }
    else {

        Write-Host "UserParameters added: $($ConfigResult.AddedParameters)" -ForegroundColor Green
    }

    # =========================================================
    # SHOW RESULTING SETTINGS
    # =========================================================

    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "Resulting Zabbix configuration" -ForegroundColor Cyan
    Write-Host "============================================================="

    Invoke-Command -Session $session -ScriptBlock {

        param($ZabbixConf)

        Get-Content $ZabbixConf |
            Where-Object {
                $_ -match '^\s*(Server|ServerActive|UserParameter)\s*='
            }

    } -ArgumentList $ZabbixConf

    # =========================================================
    # TEST ZABBIX BEFORE SERVICE START
    # =========================================================

    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "Testing Zabbix configuration..." -ForegroundColor Cyan
    Write-Host "============================================================="

    $TestResult = Invoke-Command -Session $session -ScriptBlock {

        param(
            $ZabbixExe,
            $ZabbixConf
        )

        # Start agent in foreground for a few seconds.
        # This validates that the configuration can actually start.

        $psi = New-Object System.Diagnostics.ProcessStartInfo

        $psi.FileName = $ZabbixExe
        $psi.Arguments = "-c `"$ZabbixConf`" -f"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process

        $process.StartInfo = $psi

        [void]$process.Start()

        Start-Sleep -Seconds 5

        if ($process.HasExited) {

            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()

            [PSCustomObject]@{
                Started  = $false
                ExitCode = $process.ExitCode
                Output   = ($stdout + "`r`n" + $stderr).Trim()
            }

            return
        }

        # Agent stayed alive = configuration accepted.
        $process.Kill()

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        [PSCustomObject]@{
            Started  = $true
            ExitCode = 0
            Output   = ($stdout + "`r`n" + $stderr).Trim()
        }

    } -ArgumentList $ZabbixExe, $ZabbixConf

    if (-not $TestResult.Started) {

        Write-Host ""
        Write-Host "=============================================================" -ForegroundColor Red
        Write-Host "ZABBIX CONFIGURATION TEST FAILED" -ForegroundColor Red
        Write-Host "=============================================================" -ForegroundColor Red

        Write-Host $TestResult.Output -ForegroundColor Yellow

        Write-Host ""
        Write-Host "The service will NOT be started because the configuration test failed." -ForegroundColor Yellow

        exit 1
    }

    Write-Host "Zabbix configuration test: PASSED" -ForegroundColor Green

    # =========================================================
    # STOP EXISTING SERVICE IF RUNNING
    # =========================================================

    Write-Host ""
    Write-Host "Checking Zabbix service..." -ForegroundColor Cyan

    Invoke-Command -Session $session -ScriptBlock {

        param($ZabbixService)

        $service = Get-Service `
            -Name $ZabbixService `
            -ErrorAction SilentlyContinue

        if ($service) {

            if ($service.Status -eq "Running") {

                Stop-Service `
                    -Name $ZabbixService `
                    -Force `
                    -ErrorAction Stop

                $service.WaitForStatus(
                    [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                    [TimeSpan]::FromSeconds(30)
                )
            }
        }

    } -ArgumentList $ZabbixService

    # =========================================================
    # START SERVICE
    # =========================================================

    Write-Host ""
    Write-Host "Starting Zabbix Agent service..." -ForegroundColor Cyan

    $ServiceResult = Invoke-Command -Session $session -ScriptBlock {

        param($ZabbixService)

        try {

            Start-Service `
                -Name $ZabbixService `
                -ErrorAction Stop

            $service = Get-Service -Name $ZabbixService

            $service.WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Running,
                [TimeSpan]::FromSeconds(30)
            )

            [PSCustomObject]@{
                Success = $true
                Status  = $service.Status
                Error   = ""
            }
        }
        catch {

            [PSCustomObject]@{
                Success = $false
                Status  = (Get-Service -Name $ZabbixService -ErrorAction SilentlyContinue).Status
                Error   = $_.Exception.Message
            }
        }

    } -ArgumentList $ZabbixService

    if (-not $ServiceResult.Success) {

        Write-Host ""
        Write-Host "=============================================================" -ForegroundColor Red
        Write-Host "ZABBIX SERVICE FAILED TO START" -ForegroundColor Red
        Write-Host "=============================================================" -ForegroundColor Red

        Write-Host $ServiceResult.Error -ForegroundColor Yellow

        Write-Host ""
        Write-Host "Checking recent Zabbix log..." -ForegroundColor Cyan

        Invoke-Command -Session $session -ScriptBlock {

            $log = "C:\Program Files\Zabbix Agent\zabbix_agentd.log"

            if (Test-Path $log) {

                Get-Content $log -Tail 30
            }
            else {

                Write-Host "Zabbix log not found."
            }

        }

        exit 1
    }

    # =========================================================
    # FINAL VERIFICATION
    # =========================================================

    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Green
    Write-Host "FINAL VERIFICATION" -ForegroundColor Green
    Write-Host "============================================================="

    $Final = Invoke-Command -Session $session -ScriptBlock {

        param(
            $ZabbixService,
            $ZabbixConf
        )

        $service = Get-Service -Name $ZabbixService

        $server = Get-Content $ZabbixConf |
            Where-Object { $_ -match '^\s*Server\s*=' }

        $serverActive = Get-Content $ZabbixConf |
            Where-Object { $_ -match '^\s*ServerActive\s*=' }

        $userParams = Get-Content $ZabbixConf |
            Where-Object { $_ -match '^\s*UserParameter=' }

        [PSCustomObject]@{
            ServiceStatus = $service.Status
            Server        = ($server -join "`n")
            ServerActive  = ($serverActive -join "`n")
            UserParameters = ($userParams -join "`n")
        }

    } -ArgumentList $ZabbixService, $ZabbixConf

    Write-Host ""
    Write-Host "Service Status:" -ForegroundColor Cyan
    Write-Host $Final.ServiceStatus -ForegroundColor Green

    Write-Host ""
    Write-Host "Server:" -ForegroundColor Cyan
    Write-Host $Final.Server

    Write-Host ""
    Write-Host "ServerActive:" -ForegroundColor Cyan
    Write-Host $Final.ServerActive

    Write-Host ""
    Write-Host "UserParameters:" -ForegroundColor Cyan
    Write-Host $Final.UserParameters

    # =========================================================
    # SUCCESS
    # =========================================================

    if ($Final.ServiceStatus -eq "Running") {

        Write-Host ""
        Write-Host "=============================================================" -ForegroundColor Green
        Write-Host " ZABBIX AGENT DEPLOYMENT SUCCESSFUL" -ForegroundColor Green
        Write-Host "=============================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Server       : $ComputerName"
        Write-Host "Tunnel IP    : $(if ([string]::IsNullOrWhiteSpace($TunnelIP)) {'None'} else {$TunnelIP})"
        Write-Host "Zabbix Server: $ZabbixServer"
        Write-Host "Service      : Running"
        Write-Host ""
    }
    else {

        Write-Host ""
        Write-Host "WARNING: Zabbix service is not Running." -ForegroundColor Yellow
    }

}
finally {

    # =========================================================
    # CLOSE SESSION
    # =========================================================

    if ($session) {

        Remove-PSSession $session -ErrorAction SilentlyContinue
    }
}