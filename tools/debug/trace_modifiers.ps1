# Ctrl+Alt+Tab diagnostic launcher for Windows PowerShell 5.1+.
# Always exports a fresh, isolated diagnostics EXE; never runs or overwrites
# the user's normal build\Pixelorama.exe or changes .pxo file associations.
param(
    [string]$GodotPath = "E:\app\Godot\Godot_v4.7.1-stable_win64.exe",
    [ValidateRange(20, 1000)][int]$PollMilliseconds = 60
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$projectFile = Join-Path $projectRoot "project.godot"
$diagnosticSource = Join-Path $projectRoot "src\Debug\ModifierDiagnostics.gd"
if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
    throw "Pixelorama project.godot not found: $projectFile"
}
if (-not (Test-Path -LiteralPath $diagnosticSource -PathType Leaf)) {
    throw "Modifier diagnostics source is missing. Run git pull --ff-only in D:\Pixelorama first."
}
if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
    $godotCommand = Get-Command -Name "godot", "godot4" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $godotCommand) {
        $GodotPath = $godotCommand.Source
    }
}
if (-not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
    throw "Godot 4.7.1 not found: $GodotPath. Supply -GodotPath with your Godot editor EXE path."
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logDirectory = Join-Path $projectRoot "build\modifier_diagnostics\$stamp"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$diagnosticExe = Join-Path $logDirectory "PixeloramaModifierDiagnostics.exe"

# The EXE is exported from the CURRENT source on every run. This prevents a
# stale installed EXE from silently quitting due to an old CLI parser.
Write-Host "Exporting a fresh diagnostics-only Pixelorama EXE..."
Write-Host "Godot: $GodotPath"
$buildArgs = '--headless --path "{0}" --export-release "Windows Desktop 64-bit" "{1}"' -f $projectRoot, $diagnosticExe
$build = Start-Process -FilePath $GodotPath -ArgumentList $buildArgs -WorkingDirectory $projectRoot -NoNewWindow -Wait -PassThru
if ($build.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $diagnosticExe -PathType Leaf)) {
    throw "Godot export failed (exit code $($build.ExitCode)). Review the output above; no old EXE was launched."
}

if (-not ("PixeloramaModifierWin32" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PixeloramaModifierWin32 {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
}
"@
}

function Test-WindowsKeyDown([int]$virtualKey) {
    $result = [PixeloramaModifierWin32]::GetAsyncKeyState($virtualKey)
    return (($result -band 0x8000) -ne 0)
}

$env:PXO_MODIFIER_DIAG_DIR = $logDirectory
$windowsLog = Join-Path $logDirectory "windows_modifiers.log"
$writer = $null
$launchedProcess = $null
$lastSample = ""
$lastHeartbeat = [DateTime]::MinValue
try {
    $writer = [System.IO.StreamWriter]::new(
        $windowsLog, $false, [System.Text.UTF8Encoding]::new($false)
    )
    $writer.AutoFlush = $true
    $writer.WriteLine("# UTC time, Windows GetAsyncKeyState, foreground process ID")
    $launchedProcess = Start-Process -FilePath $diagnosticExe -ArgumentList @("--", "--modifier-diagnostics") -PassThru

    # Fail instead of claiming the diagnostics started if the Godot log is missing.
    $godotLog = $null
    for ($i = 0; $i -lt 120; $i++) {
        $godotLog = Get-ChildItem -LiteralPath $logDirectory -Filter "godot_modifiers_*.log" -File |
            Select-Object -First 1
        if ($null -ne $godotLog) { break }
        $launchedProcess.Refresh()
        if ($launchedProcess.HasExited) {
            throw "Pixelorama exited before starting diagnostics. Check the Godot output above."
        }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $godotLog) {
        throw "Godot diagnostics log did not appear. The launcher will not silently record Windows-only data."
    }

    Write-Host ""
    Write-Host "Both Godot and Windows diagnostics are active."
    Write-Host "Perform Ctrl+Alt+Tab, release all keys, then return to Pixelorama."
    Write-Host "When finished, close the diagnostic Pixelorama window."
    Write-Host "Logs: $logDirectory"

    while ($true) {
        $launchedProcess.Refresh()
        if ($launchedProcess.HasExited) { break }

        [uint32]$foregroundPid = 0
        $foregroundWindow = [PixeloramaModifierWin32]::GetForegroundWindow()
        [void][PixeloramaModifierWin32]::GetWindowThreadProcessId(
            $foregroundWindow, [ref]$foregroundPid
        )
        $sample = "foreground_pid=$foregroundPid" +
            " ctrl=$(Test-WindowsKeyDown 0x11)" +
            " lctrl=$(Test-WindowsKeyDown 0xA2)" +
            " rctrl=$(Test-WindowsKeyDown 0xA3)" +
            " alt=$(Test-WindowsKeyDown 0x12)" +
            " lalt=$(Test-WindowsKeyDown 0xA4)" +
            " ralt=$(Test-WindowsKeyDown 0xA5)" +
            " shift=$(Test-WindowsKeyDown 0x10)" +
            " tab=$(Test-WindowsKeyDown 0x09)"
        $now = [DateTime]::UtcNow
        if ($sample -ne $lastSample -or ($now - $lastHeartbeat).TotalSeconds -ge 1) {
            $writer.WriteLine("$($now.ToString('o')) $sample")
            $lastSample = $sample
            $lastHeartbeat = $now
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
}
finally {
    if ($null -ne $writer) { $writer.Dispose() }
    Remove-Item Env:\PXO_MODIFIER_DIAG_DIR -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "Trace finished. Share the two log files in:"
    Write-Host $logDirectory
}
