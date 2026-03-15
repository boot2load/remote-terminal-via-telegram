# Read the content of a Windows Terminal / PowerShell window running Claude Code
# Returns the visible text content to stdout
# Usage: powershell.exe -ExecutionPolicy Bypass -File read-terminal.ps1 [-WindowMatch "pattern"]

param(
    [string]$WindowMatch = ""
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class ConsoleReader {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AttachConsole(uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleScreenBufferInfo(IntPtr hConsoleOutput, out CONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadConsoleOutput(IntPtr hConsoleOutput, [Out] CHAR_INFO[] lpBuffer, COORD dwBufferSize, COORD dwBufferCoord, ref SMALL_RECT lpReadRegion);

    [StructLayout(LayoutKind.Sequential)]
    public struct COORD {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SMALL_RECT {
        public short Left;
        public short Top;
        public short Right;
        public short Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CONSOLE_SCREEN_BUFFER_INFO {
        public COORD dwSize;
        public COORD dwCursorPosition;
        public ushort wAttributes;
        public SMALL_RECT srWindow;
        public COORD dwMaximumWindowSize;
    }

    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    public struct CHAR_INFO {
        [FieldOffset(0)] public char UnicodeChar;
        [FieldOffset(2)] public ushort Attributes;
    }

    public static string ReadFromProcess(uint pid, int maxLines) {
        if (!AttachConsole(pid)) return "";
        try {
            IntPtr handle = GetStdHandle(-11); // STD_OUTPUT_HANDLE
            CONSOLE_SCREEN_BUFFER_INFO info;
            if (!GetConsoleScreenBufferInfo(handle, out info)) return "";

            int width = info.dwSize.X;
            int startRow = Math.Max(0, info.dwCursorPosition.Y - maxLines);
            int rows = info.dwCursorPosition.Y - startRow + 1;
            if (rows <= 0) return "";

            CHAR_INFO[] buffer = new CHAR_INFO[width * rows];
            COORD bufferSize = new COORD { X = (short)width, Y = (short)rows };
            COORD bufferCoord = new COORD { X = 0, Y = 0 };
            SMALL_RECT readRegion = new SMALL_RECT {
                Left = 0, Top = (short)startRow,
                Right = (short)(width - 1), Bottom = (short)info.dwCursorPosition.Y
            };

            if (!ReadConsoleOutput(handle, buffer, bufferSize, bufferCoord, ref readRegion)) return "";

            StringBuilder sb = new StringBuilder();
            for (int row = 0; row < rows; row++) {
                StringBuilder line = new StringBuilder();
                for (int col = 0; col < width; col++) {
                    line.Append(buffer[row * width + col].UnicodeChar);
                }
                sb.AppendLine(line.ToString().TrimEnd());
            }
            return sb.ToString();
        } finally {
            FreeConsole();
        }
    }
}
"@

function Find-ClaudeProcess {
    param([string]$Match)

    $procs = Get-Process | Where-Object {
        ($_.MainWindowTitle -like "*Claude Code*" -or $_.MainWindowTitle -like "*claude*") -and
        $_.MainWindowHandle -ne 0
    }

    if ($Match) {
        $procs = $procs | Where-Object { $_.MainWindowTitle -like "*$Match*" }
    }

    if (-not $procs) {
        # Fallback: look for node/claude processes with console
        $procs = Get-Process -Name "node", "claude", "WindowsTerminal", "powershell", "pwsh" -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -like "*Claude*" -and $_.MainWindowHandle -ne 0 }
    }

    return $procs | Select-Object -First 1
}

$proc = Find-ClaudeProcess -Match $WindowMatch
if (-not $proc) {
    Write-Output ""
    exit 0
}

# Try reading console buffer directly
$content = [ConsoleReader]::ReadFromProcess([uint32]$proc.Id, 200)
if ($content) {
    Write-Output $content
    exit 0
}

# Fallback: use UI Automation to read the window text
try {
    Add-Type -AssemblyName UIAutomationClient
    $element = [System.Windows.Automation.AutomationElement]::FromHandle($proc.MainWindowHandle)
    $textPattern = $element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    if ($textPattern) {
        $text = $textPattern.DocumentRange.GetText(-1)
        Write-Output $text
    }
} catch {
    Write-Output ""
}
