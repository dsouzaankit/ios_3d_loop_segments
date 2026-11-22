# Restarting the PC's adb server, including when it is stuck. Dot-sourced by
# Watch-LoopSegmentsQuestLanTab.ps1 and QuestWrapperCommon.ps1.
#
# Stuck server (seen 2026-11-22): two adb.exe running, one listening on 127.0.0.1:5037, and every
# adb command - `adb devices`, `adb connect`, even `adb kill-server` - never returned, while the
# headset was on USB and advertising over mDNS. `kill-server` is itself a request to that server,
# so it cannot end it; only killing the process does. After that the next adb command starts a
# fresh server and finds the headset at once.

# adb <Arguments> with a timeout; { Code; Out; Err } (Code -1 = timed out, the client is killed).
function Invoke-QuestAdbTimed {
    param([string] $AdbExe, [string[]] $Arguments, [int] $TimeoutSec = 10)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $AdbExe
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    } else {
        # Windows PowerShell 5.1 (.NET Framework): no ArgumentList; adb arguments here have no quotes.
        $psi.Arguments = (@($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        # Only the client: the server it may have started is detached and is Reset-QuestAdbServer's job.
        try { $p.Kill() } catch {}
        return [pscustomobject]@{ Code = -1; Out = ''; Err = 'timeout' }
    }
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}

# Full path with links resolved (WinGet\Links\adb.exe is a symlink; a running adb.exe reports
# its real path).
function Resolve-QuestAdbPath {
    param([string] $Path)
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $t = [System.IO.File]::ResolveLinkTarget($full, $true)
        if ($t) { return $t.FullName }
        return $full
    } catch { return $Path }
}

# PIDs of the adb.exe listening on 127.0.0.1:5037 (the adb server), or none.
function Get-QuestAdbServerPids {
    $ids = @()
    try {
        foreach ($c in @(Get-NetTCPConnection -LocalPort 5037 -State Listen -ErrorAction Stop)) {
            $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -eq 'adb') { $ids += $p.Id }
        }
    } catch {}
    return @($ids | Select-Object -Unique)
}

# PIDs of the adb.exe processes to kill for a stuck server: the one listening on 127.0.0.1:5037
# (the server every adb client talks to, whichever install it came from - e.g. Meta Quest
# Developer Hub's), plus every adb.exe started from -AdbExe (its stuck clients, and a second server).
# adb.exe from other installs that are not the server are left alone.
function Get-QuestAdbStuckPids {
    param([string] $AdbExe)
    $pids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in @(Get-QuestAdbServerPids)) { [void]$pids.Add($id) }
    $mine = Resolve-QuestAdbPath $AdbExe
    foreach ($p in @(Get-Process -Name adb -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch {}
        if ($path -and ((Resolve-QuestAdbPath $path) -ieq $mine)) { [void]$pids.Add($p.Id) }
    }
    return @($pids)
}

# Restart the adb server: `adb kill-server` (5 s). Only if that does not return, or the server
# that was listening before is still alive 1 s after it, kill the adb.exe processes
# (Get-QuestAdbStuckPids) - after a normal kill-server, adb calls other scripts have in flight are
# left alone. Then `adb start-server` (15 s). -Log { param($m) ... } gets one line per step.
# Returns 'restarted' (kill-server worked) or 'killed' (processes had to be killed).
function Reset-QuestAdbServer {
    param([string] $AdbExe, [scriptblock] $Log = { param($m) })
    $how = 'restarted'
    $before = @(Get-QuestAdbServerPids)
    $k = Invoke-QuestAdbTimed -AdbExe $AdbExe -Arguments @('kill-server') -TimeoutSec 5
    if ($k.Code -eq -1) { & $Log 'adb kill-server did not return in 5 s - the adb server is stuck.' }
    Start-Sleep -Seconds 1
    $alive = @($before | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($k.Code -ne -1 -and $alive.Count -gt 0) { & $Log ('adb kill-server returned but the server (PID {0}) is still running.' -f ($alive -join ', ')) }
    $left = @()
    if ($k.Code -eq -1 -or $alive.Count -gt 0) { $left = @(Get-QuestAdbStuckPids -AdbExe $AdbExe) }
    if ($left.Count -gt 0) {
        $how = 'killed'
        & $Log ('killing adb.exe (PID {0}).' -f ($left -join ', '))
        foreach ($id in $left) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {} }
        Start-Sleep -Milliseconds 500
    }
    if (-not (Start-QuestAdbServerDetached -AdbExe $AdbExe -TimeoutSec 15)) { & $Log 'adb start-server did not return in 15 s.' }
    return $how
}

# `adb start-server` without handing this process's handles down. The server it starts inherits
# every inheritable handle of the adb client, and a client started with redirected output (or
# from a script whose output is piped, as QuestWrapperCommon.ps1 reads the watcher's) inherits
# that pipe: the server then holds it open for its whole life, and whoever reads the pipe waits
# for an end that never comes (seen: the caller hung after the script had finished). ShellExecute
# starts the client without inherited handles. $true when it returned within -TimeoutSec.
function Start-QuestAdbServerDetached {
    param([string] $AdbExe, [int] $TimeoutSec = 15)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $AdbExe
    $psi.Arguments = 'start-server'
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {}; return $false }
    return $true
}
