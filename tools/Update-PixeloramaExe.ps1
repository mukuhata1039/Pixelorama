# Rebuild the EXE actually used by Windows Explorer to open .pxo files.
# Keep this script ASCII-only for compatibility with Windows PowerShell 5.1.
# This script does not edit, reset or stash any Pixelorama source files.
# Run while Pixelorama is closed.
param([string]$GodotPath = "")

$ErrorActionPreference = "Stop"
$project = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $project "build"
$outputExe = Join-Path $buildDir "Pixelorama.exe"
$preset = "Windows Desktop 64-bit"

function Read-RegDefault([string]$keyPath) {
    $key = Get-Item -LiteralPath $keyPath -ErrorAction SilentlyContinue
    if ($null -eq $key) { return "" }
    return [string]$key.GetValue("", "")
}

function Get-PxoAssociation {
    $choicePath = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.pxo\UserChoice"
    $choice = Get-ItemProperty -LiteralPath $choicePath -ErrorAction SilentlyContinue
    $progId = [string]$choice.ProgId
    if ([string]::IsNullOrWhiteSpace($progId)) {
        $progId = Read-RegDefault "Registry::HKEY_CLASSES_ROOT\.pxo"
    }
    if ([string]::IsNullOrWhiteSpace($progId)) {
        return @{ ProgId = ""; Command = ""; Exe = "" }
    }
    $command = Read-RegDefault ("Registry::HKEY_CLASSES_ROOT\" + $progId + "\shell\open\command")
    $exe = ""
    if ($command -match '^\s*"([^"]+\.exe)"') {
        $exe = $matches[1]
    }
    elseif ($command -match '^\s*([^\s]+\.exe)') {
        $exe = $matches[1]
    }
    return @{ ProgId = $progId; Command = $command; Exe = $exe }
}

function Find-Godot {
    $candidates = New-Object System.Collections.Generic.List[string]
    $savedFiles = @(
        (Join-Path $project "Pixelorama_Godot_Path.txt"),
        (Join-Path (Split-Path $project -Parent) "Pixelorama_Godot_Path.txt"),
        (Join-Path $env:USERPROFILE "Pixelorama_Godot_Path.txt")
    )
    foreach ($saved in $savedFiles) {
        if (Test-Path -LiteralPath $saved) {
            $val = (Get-Content -LiteralPath $saved -Raw).Trim().Trim('"')
            if ($val) { $candidates.Add($val) }
        }
    }
    foreach ($name in @("godot", "godot4")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd -and $cmd.Source) { $candidates.Add($cmd.Source) }
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $gui = $candidate -replace '_console\.exe$', '.exe'
        if (Test-Path -LiteralPath $gui -PathType Leaf) { return $gui }
        return $candidate
    }
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select the Godot 4.7.1 editor executable"
    $dialog.Filter = "Executable (*.exe)|*.exe"
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "Godot editor executable was not selected."
    }
    return $dialog.FileName
}

Write-Host "=== Pixelorama EXE / .pxo file-association updater ==="
$before = Get-PxoAssociation
Write-Host ("Explorer's .pxo ProgID: " + $before.ProgId)
Write-Host ("Explorer's .pxo command: " + $before.Command)

if ([string]::IsNullOrWhiteSpace($GodotPath)) { $GodotPath = Find-Godot }
$GodotPath = (Resolve-Path -LiteralPath $GodotPath).Path
Write-Host ("Godot editor: " + $GodotPath)
if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
    throw "Godot editor EXE not found."
}

$running = @(Get-CimInstance Win32_Process -Filter "Name='Pixelorama.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and [string]::Equals($_.ExecutablePath, $outputExe, [StringComparison]::OrdinalIgnoreCase) })
if ($running.Count -gt 0) {
    throw "D:\Pixelorama\build\Pixelorama.exe is running. Close Pixelorama before rebuilding."
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Write-Host "Exporting the latest checked-out source as a RELEASE EXE..."

# A Godot Windows GUI executable can return control to PowerShell before
# export is finished. Use Start-Process -Wait to await it explicitly, and
# -PassThru to obtain a reliable exit code on Windows PowerShell 5.1.
$exportArguments = @(
    "--headless",
    "--path", ('"' + $project + '"'),
    "--export-release", ('"' + $preset + '"'),
    ('"' + $outputExe + '"')
)
$godotProcess = Start-Process -FilePath $GodotPath -ArgumentList $exportArguments -WorkingDirectory $project -Wait -PassThru -ErrorAction Stop
$exportExitCode = $godotProcess.ExitCode
if ($null -eq $exportExitCode -or $exportExitCode -ne 0) {
    throw ("Godot export failed (exit code: " + $exportExitCode + "). Check the export templates and errors above.")
}
if (-not (Test-Path -LiteralPath $outputExe -PathType Leaf)) {
    throw "Godot returned success, but Pixelorama.exe was not produced."
}
$pck = [IO.Path]::ChangeExtension($outputExe, ".pck")
if (-not (Test-Path -LiteralPath $pck -PathType Leaf)) {
    throw "Pixelorama.pck missing. Do not run the outdated EXE."
}
Write-Host ("Export complete: " + $outputExe)

# Only change an existing association if it clearly belongs to Pixelorama.
# Do not tamper with another editor, AppX handler or a protected UserChoice.
$after = Get-PxoAssociation
$owned = ($after.ProgId -match '(?i)pixelorama') -or
    ($after.Exe -match '(?i)[\\/]Pixelorama[^\\/]*\.exe$')
if ($owned -and $after.Exe -and (Test-Path -LiteralPath $after.Exe -PathType Leaf)) {
    # Preserve Explorer and the taskbar icon: update the EXE they already use.
    # Keep dated copies of both binaries for rollback.
    $targetExe = (Resolve-Path -LiteralPath $after.Exe).Path
    $targetPck = [IO.Path]::ChangeExtension($targetExe, ".pck")
    if (-not [string]::Equals($targetExe, $outputExe, [StringComparison]::OrdinalIgnoreCase)) {
        $runningTarget = @(Get-CimInstance Win32_Process -Filter "Name='Pixelorama.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and [string]::Equals($_.ExecutablePath, $targetExe, [StringComparison]::OrdinalIgnoreCase) })
        if ($runningTarget.Count -gt 0) {
            throw ("Close the Pixelorama window using: " + $targetExe)
        }
        $backupDir = Join-Path $buildDir ("before-exe-update-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Copy-Item -LiteralPath $targetExe -Destination (Join-Path $backupDir (Split-Path $targetExe -Leaf)) -ErrorAction Stop
        if (Test-Path -LiteralPath $targetPck) {
            Copy-Item -LiteralPath $targetPck -Destination (Join-Path $backupDir (Split-Path $targetPck -Leaf)) -ErrorAction Stop
        }
        Copy-Item -LiteralPath $outputExe -Destination $targetExe -Force -ErrorAction Stop
        Copy-Item -LiteralPath $pck -Destination $targetPck -Force -ErrorAction Stop
        Write-Host ("Updated existing Explorer EXE and PCK: " + $targetExe)
        Write-Host ("Old versions backed up at: " + $backupDir)
    } else {
        Write-Host ".pxo already points to the rebuilt EXE."
    }
} elseif ($owned -and $after.ProgId) {
    $newCommand = '"' + $outputExe + '" "%1"'
    if ($after.Command -ne $newCommand) {
        $backup = Join-Path $buildDir ("pxo-association-before-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
        @("ProgID=" + $after.ProgId, "Command=" + $after.Command) |
            Set-Content -LiteralPath $backup -Encoding UTF8
        $registryPath = "Registry::HKEY_CURRENT_USER\Software\Classes\" +
            $after.ProgId + "\shell\open\command"
        New-Item -Path $registryPath -Force | Out-Null
        (Get-Item -LiteralPath $registryPath).SetValue("", $newCommand,
            [Microsoft.Win32.RegistryValueKind]::String)
        Write-Host ("Updated .pxo open command to: " + $newCommand)
        Write-Host ("Previous association backed up at: " + $backup)
    } else {
        Write-Host ".pxo already points to the rebuilt EXE."
    }
} else {
    Write-Warning "The current .pxo association is not identifiable as Pixelorama. It was not modified."
    Write-Host "Choose the newly exported build\Pixelorama.exe as the default .pxo app in Windows."
}

$final = Get-PxoAssociation
Write-Host ("Final .pxo association: " + $final.Command)
Write-Host "Source and EXE are now in sync. Test double-clicking a .pxo file."
