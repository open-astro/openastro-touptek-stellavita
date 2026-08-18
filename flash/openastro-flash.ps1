<#
.SYNOPSIS
OpenAstro StellaVita flash tool (Windows). Run from an elevated PowerShell.

.DESCRIPTION
The StellaVita is a Raspberry Pi CM4 with a 32 GB eMMC. The eMMC is exposed
as a USB disk via rpiboot (Raspberry Pi usbboot) with the board in USB
device-boot mode.

Commands:
  install-rpiboot            download + run the official rpiboot installer
  backup  [-Path out.img.gz] save the current eMMC (stock ToupTek OS)
  flash   [-Path image]      write the OpenAstro image (.img/.img.gz; for
                             .img.xz use Raspberry Pi Imager, or 7-Zip to
                             decompress first)
  restore -Path backup       write a saved stock backup back

ALWAYS run 'backup' once before the first 'flash' - that backup is the only
way back to the stock ToupTek OS.

.EXAMPLE
  .\openastro-flash.ps1 install-rpiboot
  .\openastro-flash.ps1 backup
  .\openastro-flash.ps1 flash -Path ..\images\openastro-touptek-stellavita.img
  .\openastro-flash.ps1 restore -Path .\stellavita-stock-backup-20260818.img.gz
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('install-rpiboot', 'backup', 'flash', 'restore')]
    [string]$Command,
    [string]$Path
)

$ErrorActionPreference = 'Stop'

function Log($msg) { Write-Host "[flash] $msg" }
function Fail($msg) { Write-Error "[flash] $msg"; exit 1 }

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'Run this from an elevated (Administrator) PowerShell.'
    }
}

# ------------------------------------------------------------
# rpiboot
# ------------------------------------------------------------
function Find-Rpiboot {
    $candidates = @(
        "$env:ProgramFiles(x86)\Raspberry Pi\rpiboot.exe",
        "$env:ProgramFiles\Raspberry Pi\rpiboot.exe"
    ) + (Get-Command rpiboot.exe -ErrorAction SilentlyContinue | ForEach-Object Source)
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Install-Rpiboot {
    if (Find-Rpiboot) { Log "rpiboot already installed: $(Find-Rpiboot)"; return }
    Log 'Fetching the latest rpiboot installer from raspberrypi/usbboot releases...'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/raspberrypi/usbboot/releases/latest'
    $asset = $rel.assets | Where-Object name -like 'rpiboot_setup*.exe' | Select-Object -First 1
    if (-not $asset) { Fail 'No rpiboot_setup .exe found in the latest release - install manually from https://github.com/raspberrypi/usbboot/releases' }
    $dst = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $dst
    Log "Running installer $($asset.name) (accept the driver install prompts)..."
    Start-Process $dst -Wait
    if (-not (Find-Rpiboot)) { Fail 'rpiboot still not found after install.' }
    Log "rpiboot installed: $(Find-Rpiboot)"
}

# ------------------------------------------------------------
# Device discovery
# ------------------------------------------------------------
function Get-EmmcDisk {
    $rpiboot = Find-Rpiboot
    if (-not $rpiboot) { Fail "rpiboot not installed - run: .\openastro-flash.ps1 install-rpiboot" }

    $before = (Get-Disk | ForEach-Object Number)

    Write-Host ''
    Write-Host 'Put the StellaVita in USB device-boot mode now:'
    Write-Host '  1. Make sure the StellaVita is unplugged (no DC power).'
    Write-Host '  2. Short the nRPIBOOT pins with a jumper (keep them shorted).'
    Write-Host '  3. Connect a USB-A (computer) to USB-C (StellaVita) data cable.'
    Write-Host '     The board powers up over USB - do NOT connect DC power.'
    Write-Host ''
    Read-Host 'Press Enter when the pins are shorted and the USB cable is connected' | Out-Null
    Log 'Running rpiboot (waits for the CM4)...'
    Start-Process -FilePath $rpiboot -Wait -NoNewWindow

    Log 'Waiting for the eMMC to appear as a USB disk...'
    $disk = $null
    for ($i = 0; $i -lt 60; $i++) {
        $disk = Get-Disk | Where-Object {
            ($_.Number -notin $before) -or ($_.FriendlyName -match 'RPi-MSD')
        } | Select-Object -First 1
        if ($disk) { break }
        Start-Sleep 1
    }
    if (-not $disk) { Fail 'eMMC never appeared as a disk. Check the USB cable (must be data-capable) and boot mode.' }

    # Sanity: the StellaVita eMMC is 32 GB (~29 GiB); refuse anything wildly
    # different so a wrong disk can't be nuked.
    $sizeGB = [math]::Round($disk.Size / 1e9)
    Log "Found disk $($disk.Number): $($disk.FriendlyName) ($sizeGB GB)"
    if ($sizeGB -lt 28 -or $sizeGB -gt 36) {
        Fail "Disk $($disk.Number) is $sizeGB GB - not a 32 GB StellaVita eMMC. Aborting."
    }

    Write-Host ''
    Write-Host "  >>> Target: Disk $($disk.Number) - $($disk.FriendlyName) ($sizeGB GB) <<<" -ForegroundColor Yellow
    Write-Host ''
    $confirm = Read-Host "Type the disk number ($($disk.Number)) to confirm"
    if ($confirm -ne "$($disk.Number)") { Fail 'confirmation mismatch - aborting.' }
    return $disk
}

function Open-RawDisk([int]$Number, [System.IO.FileAccess]$Access) {
    $stream = New-Object System.IO.FileStream(
        "\\.\PhysicalDrive$Number", [System.IO.FileMode]::Open, $Access,
        [System.IO.FileShare]::ReadWrite)
    return $stream
}

function Copy-Stream($src, $dst, [long]$total, [string]$verb) {
    $buf = New-Object byte[] (4MB)
    [long]$done = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
    while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
        $dst.Write($buf, 0, $n)
        $done += $n
        if ($sw.ElapsedMilliseconds -gt 2000) {
            if ($total -gt 0) {
                Write-Progress -Activity $verb -Status ("{0:N1} / {1:N1} GB" -f ($done/1e9), ($total/1e9)) -PercentComplete ([math]::Min(100, 100*$done/$total))
            } else {
                Write-Progress -Activity $verb -Status ("{0:N1} GB" -f ($done/1e9))
            }
            $sw.Restart()
        }
    }
    $dst.Flush()
    Write-Progress -Activity $verb -Completed
    return $done
}

# ------------------------------------------------------------
# Commands
# ------------------------------------------------------------
function Invoke-Backup([string]$OutPath) {
    if (-not $OutPath) {
        $OutPath = Join-Path (Get-Location) ("stellavita-stock-backup-{0:yyyyMMdd}.img.gz" -f (Get-Date))
    }
    if (Test-Path $OutPath) { Fail "$OutPath already exists - refusing to overwrite a backup." }
    $disk = Get-EmmcDisk
    Log "Reading eMMC -> $OutPath (32 GB read, takes a while)..."
    $raw = Open-RawDisk $disk.Number ([System.IO.FileAccess]::Read)
    $out = [System.IO.File]::Create($OutPath)
    $gz  = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionLevel]::Fastest)
    try     { Copy-Stream $raw $gz $disk.Size 'Backing up eMMC' | Out-Null }
    finally { $gz.Dispose(); $out.Dispose(); $raw.Dispose() }
    $hash = (Get-FileHash -Algorithm SHA256 $OutPath).Hash.ToLower()
    "$hash  $(Split-Path -Leaf $OutPath)" | Set-Content "$OutPath.sha256"
    Log "Backup complete: $OutPath ($([math]::Round((Get-Item $OutPath).Length/1e9, 2)) GB)"
    Log 'Keep this file safe - it is the way back to the stock ToupTek OS.'
}

function Invoke-Write([string]$ImagePath, [string]$Label) {
    if (-not $ImagePath) { Fail "Pass the image with -Path" }
    if (-not (Test-Path $ImagePath)) { Fail "image not found: $ImagePath" }
    if ($ImagePath -like '*.xz') {
        Fail '.img.xz is not supported natively on Windows - decompress with 7-Zip first, or flash with Raspberry Pi Imager.'
    }
    $disk = Get-EmmcDisk

    Log "Taking disk $($disk.Number) offline for a raw write..."
    Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
        Get-Volume -ErrorAction SilentlyContinue | Out-Null
    Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction SilentlyContinue
    Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction SilentlyContinue

    Log "Writing $Label -> Disk $($disk.Number) ..."
    $src = [System.IO.File]::OpenRead($ImagePath)
    if ($ImagePath -like '*.gz') {
        $src = New-Object System.IO.Compression.GZipStream($src, [System.IO.Compression.CompressionMode]::Decompress)
        $total = 0
    } else {
        $total = (Get-Item $ImagePath).Length
    }
    $raw = Open-RawDisk $disk.Number ([System.IO.FileAccess]::Write)
    try     { Copy-Stream $src $raw $total "Writing $Label" | Out-Null }
    finally { $raw.Dispose(); $src.Dispose() }

    Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction SilentlyContinue
    Log "$Label written. Disconnect USB, restore normal boot, and power-cycle."
}

Assert-Admin
switch ($Command) {
    'install-rpiboot' { Install-Rpiboot }
    'backup'          { Invoke-Backup $Path }
    'flash' {
        if (-not $Path) { $Path = Join-Path $PSScriptRoot '..\images\openastro-touptek-stellavita.img' }
        Write-Host 'This OVERWRITES the eMMC with the OpenAstro image.'
        Write-Host "Run '.\openastro-flash.ps1 backup' first if you have not - it is the only way back to stock."
        if ((Read-Host 'Continue? [y/N]') -notmatch '^[yY]$') { exit 1 }
        Invoke-Write $Path 'OpenAstro image'
    }
    'restore' {
        Write-Host "This OVERWRITES the eMMC with the stock ToupTek backup: $Path"
        if ((Read-Host 'Continue? [y/N]') -notmatch '^[yY]$') { exit 1 }
        Invoke-Write $Path 'stock ToupTek backup'
    }
}
