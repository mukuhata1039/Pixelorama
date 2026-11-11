# Pixelorama Ctrl+Alt+Tab modifier-state diagnostics (Windows PowerShell 5.1+).
# Run after rebuilding Pixelorama.exe:
# powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Pixelorama\tools\debug\trace_modifiers.ps1"
# Close the launched Pixelorama instance to end the trace.
param(
    [string]$Executable = "",
    [ValidateRange(20, 1000)][int]$PollMilliseconds = 60
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $Executable = Join-Path $projectRoot "build\Pixelorama.exe"
}
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    throw "Pixelorama.exe not found: $Executable. Rebuild the EXE first."
}
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logDirectory = Join-Path $projectRoot "build\modifier_diagnostics\$stamp"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

# This variable is inherited only by the child Pixelorama process.
$env:PXO_MODIFIER_DIAG_DIR = $logDirectory

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

$windowsLog = Join-Path $logDirectory "windows_modifiers.log"
$writer = [System.IO.StreamWriter]::new(
    $windowsLog, $false, [System.Text.UTF8Encoding]::new($false)
)
$writer.AutoFlush = $true
$launchedProcess = $null
$lastSample = ""
$lastHeartbeat = [DateTime]::MinValue
try {
    $writer.WriteLine("# UTC time, Windows GetAsyncKeyState, foreground process ID")
    $launchedProcess = Start-Process -FilePath $Executable -ArgumentList @("--", "--modifier-diagnostics") -PassThru
    Write-Host "Pixelorama modifier diagnostics started."
    Write-Host "Perform Ctrl+Alt+Tab and return to Pixelorama."
    Write-Host "When finished, close the launched Pixelorama window."
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
    $writer.Dispose()
    Remove-Item Env:\PXO_MODIFIER_DIAG_DIR -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "Trace finished. Please share the files in:"
    Write-Host $logDirectory
}
