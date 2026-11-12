# SKYBOX VR Player on the Quest: add / update / remove the phone as a WebDAV server over adb.
# Dot-sourced by Watch-LoopSegmentsQuestLanTab.ps1 (needs its Invoke-Adb, Write-QuestLog).
#
# SKYBOX (xyz.skybox.player.ovr) keeps its Network servers in an SQLite file on shared storage,
# /sdcard/Android/data/xyz.skybox.player.ovr/files/SkyboxDataBase, table DeviceDataTable. A WebDAV
# server it saves itself looks like:
#   Url='webdav://10.0.100.10:8765/'  FileName='Loop Segments'  Status='Status_Online'
#   Username='admin'  Password=<plain text>  Credential_Saved_Time=<.NET ticks>
# The headset has no sqlite3, and the adb shell can read that folder and create files in it but not
# write SKYBOX's own file in place. So: pull to %TEMP% (SKYBOX still running) -> check with sqlite3
# on the PC -> nothing to do: stop here, SKYBOX untouched. Else stop SKYBOX (it holds the file open
# and would keep writing the old copy) -> pull again only if size/mtime moved -> edit -> push to a
# temp name -> mv over the original (atomic) -> chmod 660 (SKYBOX keeps writing it fine afterwards).
# The %TEMP% copy is always deleted.
# The SQL (with the password) goes to sqlite3 on stdin: never on a command line, never logged.
#
# Every server URL this PC added is listed in %TEMP%\loopsegments-skybox-webdav.json (URLs only, no
# password), so a later update or the close-time clear also removes servers left at an old phone
# address.

$script:SkyboxPackage = 'xyz.skybox.player.ovr'
$script:SkyboxDbPath = "/sdcard/Android/data/$($script:SkyboxPackage)/files/SkyboxDataBase"
$script:SkyboxServerName = 'Loop Segments'
$script:SkyboxStatePath = Join-Path $env:TEMP 'loopsegments-skybox-webdav.json'

# sqlite3.exe ships next to adb.exe in Google platform-tools; else one on PATH.
function Find-QuestSqliteExe {
    if ($script:Adb) {
        $p = Join-Path (Split-Path -Parent $script:Adb) 'sqlite3.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command -Name sqlite3.exe -ErrorAction SilentlyContinue
    if ($cmd) { return [string]$cmd.Source }
    return $null
}

function Invoke-QuestSqlite {
    param([string] $Exe, [string] $DbFile, [string] $Sql)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    [void]$psi.ArgumentList.Add('-batch')
    [void]$psi.ArgumentList.Add('-bail')
    [void]$psi.ArgumentList.Add($DbFile)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.Write($Sql)
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(30000)) {
        try { $p.Kill($true) } catch {}
        return [pscustomobject]@{ Code = -1; Out = ''; Err = 'timeout' }
    }
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $outTask.Result.Trim(); Err = $errTask.Result.Trim() }
}

function ConvertTo-QuestSqlText { param([string] $S) "'" + ($S -replace "'", "''") + "'" }

# http://host:port/... -> webdav://host:port/ (the form SKYBOX saves).
function Get-QuestSkyboxWebDavUrl {
    param([string] $LanUrl)
    $u = [Uri]$LanUrl
    return ('webdav://{0}:{1}/' -f $u.Host, $u.Port)
}

# http://<phoneLanHost>:<lanPort>/ from the companion's lan_config.json (re-read on every call, so a
# phone address change during the session is picked up), or $null.
function Get-QuestSkyboxLanUrlFromConfig {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $h = ([string]$c.phoneLanHost).Trim()
        if ([string]::IsNullOrWhiteSpace($h)) { return $null }
        $port = 8765
        if ($null -ne $c.lanPort -and [int]$c.lanPort -gt 0) { $port = [int]$c.lanPort }
        return "http://${h}:${port}/"
    } catch {
        return $null
    }
}

# Server URLs this PC added to SKYBOX and has not removed yet.
function Get-QuestSkyboxAddedUrls {
    if (-not (Test-Path -LiteralPath $script:SkyboxStatePath)) { return @() }
    try { return @((Get-Content -LiteralPath $script:SkyboxStatePath -Raw | ConvertFrom-Json).urls | Where-Object { $_ }) } catch { return @() }
}

function Set-QuestSkyboxAddedUrls {
    param([string[]] $Urls)
    $list = @($Urls | Where-Object { $_ } | Select-Object -Unique)
    if ($list.Count -eq 0) { Remove-Item -LiteralPath $script:SkyboxStatePath -Force -ErrorAction SilentlyContinue; return }
    try { Set-Content -LiteralPath $script:SkyboxStatePath -Value (@{ urls = $list } | ConvertTo-Json -Compress) -Encoding utf8 } catch {}
}

function Test-QuestSkyboxRunning {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', 'pidof', $script:SkyboxPackage)
    return ($r.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Out))
}

# "<size> <mtime>" of SKYBOX's database on the headset, or $null.
function Get-QuestSkyboxDbStat {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', "stat -c '%s %Y' '$($script:SkyboxDbPath)'")
    $o = ([string]$r.Out).Trim()
    if ($r.Code -eq 0 -and $o -match '^\d+ \d+$') { return $o }
    return $null
}

function Copy-QuestSkyboxDb {
    param([string] $DeviceSerial, [string] $LocalPath)
    $pull = Invoke-Adb -TimeoutSec 90 -Arguments @('-s', $DeviceSerial, 'pull', $script:SkyboxDbPath, $LocalPath)
    if ($pull.Code -ne 0 -or -not (Test-Path -LiteralPath $LocalPath)) {
        Write-QuestLog "SKYBOX: could not copy the database from the headset: $(Get-AdbMessage $pull)"
        return $false
    }
    return $true
}

# What the edit would do to the local copy: 'added' / 'updated' / 'unchanged' (with -DavUrl),
# 'removed' / 'absent' (only -RemoveUrls), or 'failed' when the copy cannot be read.
function Get-QuestSkyboxChange {
    param([string] $Sqlite, [string] $DbFile, [string] $DavUrl, [string] $Want, [string[]] $RemoveUrls)
    $sql = ''
    if ($DavUrl) {
        $sql += "SELECT 'row:'||COALESCE(FileName,'')||'|'||COALESCE(Username,'')||'|'||COALESCE(Password,'')||'|'||COALESCE(Status,'') FROM DeviceDataTable WHERE Url=$(ConvertTo-QuestSqlText $DavUrl);`n"
    }
    $old = @($RemoveUrls | Where-Object { $_ -and $_ -ne $DavUrl })
    if ($old.Count -gt 0) {
        $sql += "SELECT 'old:'||count(*) FROM DeviceDataTable WHERE Url IN ($((@($old | ForEach-Object { ConvertTo-QuestSqlText $_ })) -join ','));`n"
    }
    if (-not $sql) { return 'absent' }
    $r = Invoke-QuestSqlite -Exe $Sqlite -DbFile $DbFile -Sql $sql
    if ($r.Code -ne 0) { Write-QuestLog "SKYBOX: database read failed: $($r.Err)"; return 'failed' }
    $row = $null
    $oldCount = 0
    foreach ($l in @($r.Out -split "`r?`n")) {
        if ($l.StartsWith('row:')) { $row = $l.Substring(4) }
        elseif ($l -match '^old:(\d+)$') { $oldCount = [int]$Matches[1] }
    }
    if ($DavUrl) {
        if ($null -eq $row) { return 'added' }
        if ($row -ne $Want -or $oldCount -gt 0) { return 'updated' }
        return 'unchanged'
    }
    if ($oldCount -gt 0) { return 'removed' }
    return 'absent'
}

# A run that was force-killed (the companion cleanup stops the session job that way) skips its
# finally block: its %TEMP% copy of SKYBOX's database (library + saved logins) and a half-pushed
# temp file on the headset stay behind. Every run deletes those first. Only one run edits at a
# time (the cleanup stops the session job before its own run), so nothing in use is removed.
function Remove-QuestSkyboxLeftovers {
    param([string] $DeviceSerial)
    $left = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'loopsegments-skybox-*' -ErrorAction SilentlyContinue)
    foreach ($d in $left) { try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop } catch {} }
    $tmp = $script:SkyboxDbPath + '.loopsegments-new'
    $r = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', "if [ -e '$tmp' ]; then rm -f '$tmp' && echo removed; fi")
    $onHeadset = ([string]$r.Out) -match 'removed'
    if ($left.Count -gt 0 -or $onHeadset) {
        Write-QuestLog ("SKYBOX: removed leftovers of an interrupted run ({0} local database cop{1}{2})." -f $left.Count, $(if ($left.Count -eq 1) { 'y' } else { 'ies' }), $(if ($onHeadset) { ', 1 temp file on the headset' } else { '' }))
    }
}

# With -DavUrl (webdav://host:port/): add or update server 'Loop Segments' there with -User /
# -Password, and delete -RemoveUrls rows in the same edit. Without -DavUrl: only delete -RemoveUrls.
# Returns 'added', 'updated', 'unchanged', 'removed', 'absent', 'not installed', or 'failed'.
# SKYBOX is stopped only when something has to change (and started again after an add/update if it
# was open).
function Invoke-QuestSkyboxWebDav {
    param(
        [string] $DeviceSerial,
        [string] $DavUrl = '',
        [string] $User = '',
        [string] $Password = '',
        [string[]] $RemoveUrls = @()
    )
    $sqlite = Find-QuestSqliteExe
    if (-not $sqlite) { Write-QuestLog 'SKYBOX: sqlite3.exe not found (it ships with adb in platform-tools) - skipped.'; return 'failed' }
    Remove-QuestSkyboxLeftovers -DeviceSerial $DeviceSerial
    $stat = Get-QuestSkyboxDbStat -DeviceSerial $DeviceSerial
    if (-not $stat) {
        $pm = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', 'pm', 'path', $script:SkyboxPackage)
        if ($pm.Out -notmatch 'package:') { Write-QuestLog 'SKYBOX: not installed on the headset - skipped.'; return 'not installed' }
        Write-QuestLog 'SKYBOX: no database yet (open SKYBOX once) - skipped.'
        return 'failed'
    }
    $remove = @($RemoveUrls | Where-Object { $_ -and $_ -ne $DavUrl } | Select-Object -Unique)
    $want = '{0}|{1}|{2}|Status_Online' -f $script:SkyboxServerName, $User, $Password
    $wasRunning = $false
    $stopped = $false

    $work = Join-Path $env:TEMP ('loopsegments-skybox-' + [Guid]::NewGuid().ToString('N'))
    $local = Join-Path $work 'SkyboxDataBase'
    try {
        [void](New-Item -ItemType Directory -Path $work -Force)
        # 1. Copy and check while SKYBOX keeps running: runs that need nothing end here.
        if (-not (Copy-QuestSkyboxDb -DeviceSerial $DeviceSerial -LocalPath $local)) { return 'failed' }
        $result = Get-QuestSkyboxChange -Sqlite $sqlite -DbFile $local -DavUrl $DavUrl -Want $want -RemoveUrls $remove
        if ($result -in @('added', 'updated', 'removed')) {
            # 2. A change is needed: stop SKYBOX (it holds the file open). Copy again only if the
            #    file moved since the first copy (same size and modified time = reuse it).
            $wasRunning = Test-QuestSkyboxRunning -DeviceSerial $DeviceSerial
            [void](Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'am', 'force-stop', $script:SkyboxPackage))
            $stopped = $true
            # SKYBOX uses SQLite's default rollback journal, written only during a save. A -wal
            # (WAL mode) or a hot -journal next to the stopped file means the main file alone is
            # not its current data: editing it could lose changes or corrupt it, so do not.
            $j = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', "ls '$($script:SkyboxDbPath)-wal' '$($script:SkyboxDbPath)-journal' 2>/dev/null")
            if (-not [string]::IsNullOrWhiteSpace([string]$j.Out)) {
                Write-QuestLog ("SKYBOX: database has a journal file next to it ({0}) - not editing it (see quest\README.md, 'If SKYBOX changes')." -f (([string]$j.Out).Trim() -replace '.*/', '' -replace '\s+', ', '))
                return 'failed'
            }
            if ((Get-QuestSkyboxDbStat -DeviceSerial $DeviceSerial) -ne $stat) {
                Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
                if (-not (Copy-QuestSkyboxDb -DeviceSerial $DeviceSerial -LocalPath $local)) { return 'failed' }
                $result = Get-QuestSkyboxChange -Sqlite $sqlite -DbFile $local -DavUrl $DavUrl -Want $want -RemoveUrls $remove
            }
        }
        if ($result -eq 'failed') { return 'failed' }
        if ($result -in @('added', 'updated', 'removed')) {
            $sql = ''
            if ($remove.Count -gt 0) {
                $sql += "DELETE FROM DeviceDataTable WHERE Url IN ($((@($remove | ForEach-Object { ConvertTo-QuestSqlText $_ })) -join ','));`n"
            }
            if ($DavUrl) {
                $ticks = [DateTime]::Now.Ticks
                $sql += "INSERT INTO DeviceDataTable(Url,FileName,Status,Username,Password,Credential_Saved_Time) VALUES($(ConvertTo-QuestSqlText $DavUrl),$(ConvertTo-QuestSqlText $script:SkyboxServerName),'Status_Online',$(ConvertTo-QuestSqlText $User),$(ConvertTo-QuestSqlText $Password),$ticks) " +
                        "ON CONFLICT(Url) DO UPDATE SET FileName=excluded.FileName,Status=excluded.Status,Username=excluded.Username,Password=excluded.Password,Credential_Saved_Time=excluded.Credential_Saved_Time;`n"
            }
            $w = Invoke-QuestSqlite -Exe $sqlite -DbFile $local -Sql ($sql + 'PRAGMA integrity_check;')
            if ($w.Code -ne 0 -or $w.Out -ne 'ok') { Write-QuestLog "SKYBOX: database edit failed: $($w.Err) $($w.Out)"; return 'failed' }
            $tmp = $script:SkyboxDbPath + '.loopsegments-new'
            $push = Invoke-Adb -TimeoutSec 90 -Arguments @('-s', $DeviceSerial, 'push', $local, $tmp)
            if ($push.Code -ne 0) { Write-QuestLog "SKYBOX: could not copy the database to the headset: $(Get-AdbMessage $push)"; return 'failed' }
            $mv = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', "mv -f '$tmp' '$($script:SkyboxDbPath)' && chmod 660 '$($script:SkyboxDbPath)' && echo done")
            if ($mv.Out -notmatch 'done') {
                Write-QuestLog "SKYBOX: could not replace the database: $(Get-AdbMessage $mv)"
                [void](Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'rm', '-f', $tmp))
                return 'failed'
            }
        }
        $what = if ($DavUrl) { "'{0}' ({1})" -f $script:SkyboxServerName, $DavUrl } else { "'{0}' ({1})" -f $script:SkyboxServerName, ($remove -join ', ') }
        $verb = @{ added = 'added'; updated = 'updated'; unchanged = 'already up to date'; removed = 'removed'; absent = 'was not there' }[$result]
        if ($DavUrl -and $remove.Count -gt 0 -and $result -in @('added', 'updated')) { $verb += " (old address(es) removed: $($remove -join ', '))" }
        $note = if ($stopped) { '' } else { ', SKYBOX not touched' }
        Write-QuestLog ("SKYBOX: WebDAV server {0} {1}{2}." -f $what, $verb, $note)
        return $result
    } finally {
        # The local copy holds SKYBOX's library and saved logins: never leave it behind.
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        # Bring SKYBOX back only if this call stopped it while adding/updating (not at the clear).
        if ($stopped -and $wasRunning -and $DavUrl) {
            [void](Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'monkey', '-p', $script:SkyboxPackage, '-c', 'android.intent.category.LAUNCHER', '1'))
        }
    }
}
