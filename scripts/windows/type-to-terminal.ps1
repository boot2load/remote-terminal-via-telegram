# Type a message into the Claude Code terminal window and press Enter
# Uses Win32 SendInput for reliable keystroke injection
# Usage: powershell.exe -ExecutionPolicy Bypass -File type-to-terminal.ps1 -Message "text" [-WindowMatch "pattern"]

param(
    [Parameter(Mandatory=$true)]
    [string]$Message,
    [string]$WindowMatch = ""
)

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class WindowHelper {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    public const int SW_RESTORE = 9;
    public const int SW_SHOW = 5;
}
"@

Add-Type -AssemblyName System.Windows.Forms

function Find-ClaudeWindow {
    param([string]$Match)

    $procs = Get-Process | Where-Object {
        $_.MainWindowHandle -ne 0 -and (
            $_.MainWindowTitle -like "*Claude Code*" -or
            $_.MainWindowTitle -like "*claude*"
        )
    }

    if ($Match) {
        $procs = $procs | Where-Object { $_.MainWindowTitle -like "*$Match*" }
    }

    if (-not $procs) {
        $procs = Get-Process -Name "WindowsTerminal", "powershell", "pwsh", "cmd" -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -like "*Claude*" -and $_.MainWindowHandle -ne 0 }
    }

    return $procs | Select-Object -First 1
}

$proc = Find-ClaudeWindow -Match $WindowMatch
if (-not $proc) {
    Write-Error "No Claude Code terminal window found"
    exit 1
}

$hwnd = $proc.MainWindowHandle

# Restore if minimized
if ([WindowHelper]::IsIconic($hwnd)) {
    [WindowHelper]::ShowWindow($hwnd, [WindowHelper]::SW_RESTORE)
    Start-Sleep -Milliseconds 300
}

# Bring to foreground
[WindowHelper]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 200

# Verify it's foreground
$fg = [WindowHelper]::GetForegroundWindow()
if ($fg -ne $hwnd) {
    # Retry once
    [WindowHelper]::ShowWindow($hwnd, [WindowHelper]::SW_SHOW)
    Start-Sleep -Milliseconds 200
    [WindowHelper]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 200
}

# Type the message using SendKeys (handles special characters safely)
# Escape SendKeys special characters: +, ^, %, ~, {, }, (, )
$escaped = $Message -replace '([+^%~{}()\[\]])', '{$1}'
[System.Windows.Forms.SendKeys]::SendWait($escaped)
Start-Sleep -Milliseconds 100

# Press Enter
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
