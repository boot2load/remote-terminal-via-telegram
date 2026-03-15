# Send the Escape key to the Claude Code terminal window
# Usage: powershell.exe -ExecutionPolicy Bypass -File send-escape.ps1 [-WindowMatch "pattern"]

param(
    [string]$WindowMatch = ""
)

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class EscapeHelper {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    public const int SW_RESTORE = 9;
}
"@

Add-Type -AssemblyName System.Windows.Forms

$procs = Get-Process | Where-Object {
    $_.MainWindowHandle -ne 0 -and (
        $_.MainWindowTitle -like "*Claude Code*" -or
        $_.MainWindowTitle -like "*claude*"
    )
}

if ($WindowMatch) {
    $procs = $procs | Where-Object { $_.MainWindowTitle -like "*$WindowMatch*" }
}

$proc = $procs | Select-Object -First 1
if (-not $proc) { exit 0 }

$hwnd = $proc.MainWindowHandle

if ([EscapeHelper]::IsIconic($hwnd)) {
    [EscapeHelper]::ShowWindow($hwnd, [EscapeHelper]::SW_RESTORE)
    Start-Sleep -Milliseconds 300
}

[EscapeHelper]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 200

[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
