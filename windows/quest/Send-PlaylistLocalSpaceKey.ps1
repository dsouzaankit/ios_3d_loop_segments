<#
.SYNOPSIS
  Press Space in the visible 3d_playlist_local PowerShell window (pause / resume the leaf DLNA export).

.DESCRIPTION
  The 3d_playlist_local batch launchers (run_batch_*.ps1, Run-TranscodeOrchestrator.ps1, ...) read
  [Console]::ReadKey while a clip runs; Space toggles Toggle-LeafFfmpegExportSuspend. This script
  writes one Space key-down + key-up into that console's input buffer (AttachConsole +
  WriteConsoleInput on CONIN$), so the window does not need focus and nothing else is typed.

  Target: pwsh.exe / powershell.exe processes whose command line runs a script from a
  3d_playlist_local folder. Hidden children (-WindowStyle Hidden, started by the batch) are mapped
  to their visible parent shell, so a launcher typed into an interactive pwsh is found while a clip
  runs. One Space per console (a console shared by several matches gets one key).

  Used by the Quest control page (Serve-QuestControlPage.ps1, POST /playlist/space). Prints one JSON
  line: { ok, sent, consoles: [ { pid, script, ok, error } ], error }. Exit 0 when at least one
  console got the key, 2 when no shell was found, 1 on errors.
#>
[CmdletBinding()]
param(
    # Only list what would get the key.
    [switch] $WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPattern = '(?i)\\3d_playlist_local\\[^"]*\.ps1|run_batch_(vr_hybrid|fisheye_v360|convert_streamTo3D)\.ps1|Run-TranscodeOrchestrator\.ps1'
$hiddenPattern = '(?i)-WindowStyle\s+Hidden|-NonInteractive'

function Get-ShellLabel {
    param([string] $CommandLine)
    $m = [regex]::Match([string]$CommandLine, '(?i)([^\\/"]+\.ps1)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'pwsh'
}

$all = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue)
$byPid = @{}
foreach ($p in $all) { $byPid[[int]$p.ProcessId] = $p }

# Visible shells to press Space in, keyed by pid (label = the script it runs, or the matching child's).
$targets = [System.Collections.Generic.Dictionary[int, string]]::new()
foreach ($p in $all) {
    $cl = [string]$p.CommandLine
    if ($cl -notmatch $scriptPattern) { continue }
    if ([int]$p.ProcessId -eq $PID) { continue }
    $label = Get-ShellLabel -CommandLine $cl
    $cur = $p
    $guard = 0
    # Walk up from hidden children to the first visible PowerShell ancestor.
    while ($cur -and ([string]$cur.CommandLine) -match $hiddenPattern -and $guard -lt 8) {
        $cur = $byPid[[int]$cur.ParentProcessId]
        $guard++
    }
    if (-not $cur -or ([string]$cur.CommandLine) -match $hiddenPattern) { continue }
    $id = [int]$cur.ProcessId
    if (-not $targets.ContainsKey($id)) {
        $own = [string]$cur.CommandLine
        $targets[$id] = $(if ($own -match $scriptPattern) { Get-ShellLabel -CommandLine $own } else { $label })
    }
}

function Write-Result { param($Object, [int] $Code) ($Object | ConvertTo-Json -Compress -Depth 4) | Write-Output; exit $Code }

if ($targets.Count -eq 0) {
    Write-Result ([ordered]@{ ok = $false; sent = 0; consoles = @(); error = 'no 3d_playlist_local PowerShell window found' }) 2
}
if ($WhatIf) {
    Write-Result ([ordered]@{ ok = $true; sent = 0; consoles = @($targets.Keys | ForEach-Object { [ordered]@{ pid = $_; script = $targets[$_] } }) }) 0
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LsConsoleKey {
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    struct KEY_EVENT_RECORD {
        [FieldOffset(0)] public int bKeyDown;
        [FieldOffset(4)] public ushort wRepeatCount;
        [FieldOffset(6)] public ushort wVirtualKeyCode;
        [FieldOffset(8)] public ushort wVirtualScanCode;
        [FieldOffset(10)] public char UnicodeChar;
        [FieldOffset(12)] public uint dwControlKeyState;
    }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] recs, uint n, out uint written);

    // "" on success, else the error. consoleId gets the console window handle (dedupe).
    public static string SendSpace(uint pid, out long consoleId) {
        consoleId = 0;
        FreeConsole();
        if (!AttachConsole(pid)) return "AttachConsole failed (" + Marshal.GetLastWin32Error() + ")";
        try {
            consoleId = GetConsoleWindow().ToInt64();
            IntPtr h = CreateFileW("CONIN$", 0xC0000000u, 3u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
            if (h == new IntPtr(-1)) return "CONIN$ open failed (" + Marshal.GetLastWin32Error() + ")";
            try {
                var recs = new INPUT_RECORD[2];
                for (int i = 0; i < 2; i++) {
                    recs[i].EventType = 1; // KEY_EVENT
                    recs[i].KeyEvent.bKeyDown = i == 0 ? 1 : 0;
                    recs[i].KeyEvent.wRepeatCount = 1;
                    recs[i].KeyEvent.wVirtualKeyCode = 0x20;  // VK_SPACE
                    recs[i].KeyEvent.wVirtualScanCode = 0x39;
                    recs[i].KeyEvent.UnicodeChar = ' ';
                }
                uint written;
                if (!WriteConsoleInputW(h, recs, 2, out written) || written != 2) return "WriteConsoleInput failed (" + Marshal.GetLastWin32Error() + ")";
                return "";
            } finally { CloseHandle(h); }
        } finally { FreeConsole(); }
    }
    public static long ConsoleOf(uint pid) {
        FreeConsole();
        if (!AttachConsole(pid)) return 0;
        long id = GetConsoleWindow().ToInt64();
        FreeConsole();
        return id;
    }
}
'@

# Dedupe consoles first (one key per console), then send.
$seen = @{}
$results = [System.Collections.Generic.List[object]]::new()
foreach ($id in @($targets.Keys)) {
    $cid = [LsConsoleKey]::ConsoleOf([uint32]$id)
    if ($cid -ne 0 -and $seen.ContainsKey($cid)) { continue }
    $outId = [long]0
    $err = [LsConsoleKey]::SendSpace([uint32]$id, [ref]$outId)
    if ($outId -ne 0) { $seen[$outId] = $true }
    $results.Add([ordered]@{ pid = $id; script = $targets[$id]; ok = ($err -eq ''); error = $err })
}
$sent = @($results | Where-Object { $_.ok }).Count
$out = [ordered]@{ ok = ($sent -gt 0); sent = $sent; consoles = @($results) }
if ($sent -eq 0) { $out.error = 'could not press Space in any 3d_playlist_local window' }
Write-Result $out $(if ($sent -gt 0) { 0 } else { 1 })
