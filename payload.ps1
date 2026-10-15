#Requires -Version 5.1
<#
  OTC OPTI v7  -  Windows tuning for Rust and other CPU-bound games

  Start it with Run-RomOpti.bat (or right-click this file > Run with PowerShell).
  It asks for administrator rights once.

  How it works
    - Before any change is made, the previous value is written to a journal
      (C:\ProgramData\OTCOpti\journal.json). Revert restores YOUR old values,
      not hard-coded defaults.
    - Every toggle says what it does, how much it can realistically matter,
      and what the tradeoff is. Most Windows tweaks are worth a few percent at
      best; the Dashboard tells you which bigger problems your PC actually has.
    - Nothing here injects into the game process or edits game binaries.
#>

# ---- elevation --------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($PSCommandPath) {
        try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath) } catch { }
        exit
    }
    # Started from memory (irm ... | iex): there is no file to relaunch, so fetch the same script
    # from the public repo into %TEMP% and start that copy elevated. Nothing else is downloaded.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $romTmp = Join-Path ([IO.Path]::GetTempPath()) 'OTC-Opti.ps1'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/RomOpti/RomOpti/main/Rom-Opti.ps1' -OutFile $romTmp -UseBasicParsing
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $romTmp)
    } catch {
        Write-Host 'OTC OPTI нужны права администратора, и перезапуститься самостоятельно не удалось. Откройте PowerShell от имени администратора и повторите команду.' -ForegroundColor Yellow
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$script:Version = '7.1'

# ---- native helpers ---------------------------------------------------------
$NativeSrc = @'
using System;
using System.Runtime.InteropServices;

public static class RomNative {
    [DllImport("ntdll.dll")] static extern uint NtSetTimerResolution(uint desired, bool set, out uint current);
    [DllImport("ntdll.dll")] static extern uint NtQueryTimerResolution(out uint min, out uint max, out uint current);
    [DllImport("ntdll.dll")] static extern uint NtSetSystemInformation(int cls, ref int info, int len);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES np, int len, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool GetDeviceGammaRamp(IntPtr hdc, [Out] ushort[] ramp);
    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] static extern bool SetDeviceGammaRamp(IntPtr hdc, [In] ushort[] ramp);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);

    // Pack=4 matters: the real TOKEN_PRIVILEGES has the LUID at offset 4. With the default
    // packing the LUID lands at offset 8, the privilege is never enabled and the standby
    // purge fails with STATUS_PRIVILEGE_NOT_HELD.
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TOKEN_PRIVILEGES { public int Count; public long Luid; public int Attr; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight; public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
        public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
    }

    static bool EnablePrivilege(string name) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
        try {
            long luid;
            if (!LookupPrivilegeValue(null, name, out luid)) return false;
            TOKEN_PRIVILEGES tp; tp.Count = 1; tp.Luid = luid; tp.Attr = 2;
            if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
            return Marshal.GetLastWin32Error() == 0;   // 1300 = not all assigned
        } finally { CloseHandle(tok); }
    }

    // ---- timer resolution: ask for the finest the hardware offers ----
    public static double HoldFinestTimer() {
        uint a, b, cur;
        NtQueryTimerResolution(out a, out b, out cur);
        uint finest = Math.Min(a, b);          // smaller value = finer resolution (5000 = 0.5 ms)
        uint r = NtSetTimerResolution(finest, true, out cur);
        if (r != 0) return -1;
        NtQueryTimerResolution(out a, out b, out cur);
        return cur / 10000.0;
    }
    public static void ReleaseTimer() { uint cur; NtSetTimerResolution(156250, false, out cur); }
    public static double TimerMs() { uint min, max, cur; NtQueryTimerResolution(out min, out max, out cur); return cur / 10000.0; }

    // ---- standby list purge (what ISLC does) ----
    public static uint PurgeStandby() {
        if (!EnablePrivilege("SeProfileSingleProcessPrivilege")) return 0xC0000061;
        int cmd = 4;                                        // MemoryPurgeStandbyList
        return NtSetSystemInformation(80, ref cmd, 4);      // SystemMemoryListInformation
    }

    // ---- primary display: { current Hz, max Hz at same resolution, width, height } ----
    public static int[] DisplayInfo() {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(null, -1, ref dm)) return new int[] { 0, 0, 0, 0 };
        int cur = dm.dmDisplayFrequency, w = dm.dmPelsWidth, h = dm.dmPelsHeight, bpp = dm.dmBitsPerPel, max = cur;
        for (int i = 0; ; i++) {
            DEVMODE m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(null, i, ref m)) break;
            if (m.dmPelsWidth == w && m.dmPelsHeight == h && m.dmBitsPerPel == bpp && m.dmDisplayFrequency > max) max = m.dmDisplayFrequency;
        }
        return new int[] { cur, max, w, h };
    }

    public static ushort[] ReadDisplayGammaRamp() {
        IntPtr dc = GetDC(IntPtr.Zero);
        if (dc == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not access the primary display.");
        try {
            ushort[] ramp = new ushort[768];
            if (!GetDeviceGammaRamp(dc, ramp)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "The display driver does not support reading its gamma ramp.");
            return ramp;
        } finally { ReleaseDC(IntPtr.Zero, dc); }
    }

    public static void SetDisplayGammaRamp(ushort[] ramp) {
        if (ramp == null || ramp.Length != 768) throw new ArgumentException("A display gamma ramp must contain 768 values.", "ramp");
        IntPtr dc = GetDC(IntPtr.Zero);
        if (dc == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not access the primary display.");
        try {
            if (!SetDeviceGammaRamp(dc, ramp)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "The display driver rejected the gamma ramp.");
        } finally { ReleaseDC(IntPtr.Zero, dc); }
    }

    public static void HideConsole() { IntPtr h = GetConsoleWindow(); if (h != IntPtr.Zero) ShowWindow(h, 0); }
}
'@
try { Add-Type -TypeDefinition $NativeSrc -ErrorAction Stop; $script:NativeOk = $true; if ($PSCommandPath) { [RomNative]::HideConsole() } }
catch { $script:NativeOk = $false }

# ---- paths, logging ---------------------------------------------------------
$script:AppDir      = Join-Path $env:ProgramData 'OTCOpti'
$script:JournalFile = Join-Path $script:AppDir 'journal.json'
$script:SessionFile = Join-Path $script:AppDir 'session.json'
$script:LogFile     = Join-Path $script:AppDir 'otc-opti.log'
if (-not (Test-Path -LiteralPath $script:AppDir)) { $romOld = Join-Path $env:ProgramData 'RomOpti'; if (Test-Path -LiteralPath $romOld) { Copy-Item -LiteralPath $romOld -Destination $script:AppDir -Recurse -Force } else { [void](New-Item -ItemType Directory -Path $script:AppDir -Force) } }
try { if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -gt 2MB)) { Remove-Item -LiteralPath $script:LogFile -Force } } catch { }

$script:UI     = $null
$script:AnimOn = $true
$script:Brushes = @{}
$script:ColorValues = @{ Brightness = 0.0; Contrast = 100.0; Saturation = 100.0; Exposure = 0.0; Gamma = 1.0 }
$script:ColorOriginalRamp = $null
$script:ColorRampRecoveryFile = Join-Path $script:AppDir 'display-ramp-recovery.json'

function Get-Brush {
    param([string]$Hex, [double]$Opacity = 1.0)
    $key = "$Hex|$Opacity"
    if (-not $script:Brushes.ContainsKey($key)) {
        $c = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
        $c.A = [byte][math]::Round(255 * $Opacity)
        $b = New-Object Windows.Media.SolidColorBrush $c
        $b.Freeze()
        $script:Brushes[$key] = $b
    }
    return $script:Brushes[$key]
}

function Write-TextFile {
    # UTF-8 *without* BOM. Windows PowerShell's Set-Content -Encoding UTF8 writes a BOM, which
    # can corrupt the first line of a game .cfg or break a JSON parser.
    param([string]$Path, [string]$Text)
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Delete($Path) }
    [System.IO.File]::Move($tmp, $Path)
}

function Write-Log {
    param([string]$Message, [string]$Kind = 'info')
    try { Add-Content -LiteralPath $script:LogFile -Value ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Kind, $Message) -ErrorAction SilentlyContinue } catch { }
    if (-not $script:UI -or -not $script:UI.logList) { return }
    $color = switch ($Kind) { 'ok' { '#2ED3A0' } 'warn' { '#FFB547' } 'err' { '#FF5C7A' } 'accent' { '#FFFFFF' } default { '#98A2C3' } }
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
    $tb.TextWrapping = 'Wrap'
    $tb.FontFamily = 'Consolas'
    $tb.FontSize = 11.5
    $tb.Margin = '0,1,0,1'
    $tb.Foreground = Get-Brush $color
    [void]$script:UI.logList.Items.Add($tb)
    while ($script:UI.logList.Items.Count -gt 400) { $script:UI.logList.Items.RemoveAt(0) }
    $script:UI.logList.ScrollIntoView($tb)
    $script:UI.lastLog.Text = $Message
    $script:UI.lastLog.Foreground = Get-Brush $color
    if (Get-Command Start-FadeSlide -ErrorAction SilentlyContinue) { Start-FadeSlide $tb 0 5 0 200; Start-FadeSlide $script:UI.lastLog 0 0 0 240 }
}

function Invoke-UiPump {
    # Lets WPF repaint during a synchronous loop. Only called from code paths where the
    # buttons are disabled, so re-entrancy is not a concern.
    if (-not $script:UI -or -not $script:UI.Win) { return }
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void]$script:UI.Win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Wait-Ui {
    # Sleep without freezing the window: keeps painting and animating while it waits.
    param([int]$Ms)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) { Invoke-UiPump; Start-Sleep -Milliseconds 12 }
}

function Invoke-Blocking {
    # Runs slow work in a background runspace and keeps the UI alive while waiting.
    # The script block must be self-contained. -Functions copies named functions into the worker.
    param([scriptblock]$Script, [object[]]$ArgList = @(), [string[]]$Functions = @(), [int]$TimeoutSec = 180)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    try {
        $pre = "function Invoke-UiPump {}`n"
        foreach ($fn in $Functions) { $pre += ("function {0} {{`n{1}`n}}`n" -f $fn, (Get-Item -LiteralPath "function:$fn").ScriptBlock.ToString()) }
        [void]$ps.AddScript($pre)
        [void]$ps.Invoke()
        $ps.Commands.Clear()
        [void]$ps.AddScript($Script.ToString())
        foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
        $h = $ps.BeginInvoke()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $h.IsCompleted) {
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { $ps.Stop(); throw 'The operation timed out.' }
            Invoke-UiPump
            Start-Sleep -Milliseconds 15
        }
        $out = $ps.EndInvoke($h)
        if ($ps.Streams.Error.Count -gt 0 -and -not $out) { throw $ps.Streams.Error[0].ToString() }
        return $out
    } finally { try { $ps.Dispose(); $rs.Dispose() } catch { } }
}

function Stop-ServicesFast {
    param([string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return }
    [void](Invoke-Blocking -ArgList @(,$Names) -Script { param($n) foreach ($s in $n) { try { Stop-Service -Name $s -Force -ErrorAction Stop } catch { } } })
}

function Start-ServicesFast {
    param([string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return }
    [void](Invoke-Blocking -ArgList @(,$Names) -Script { param($n) foreach ($s in $n) { try { Start-Service -Name $s -ErrorAction Stop } catch { } } })
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

# ---- async helper (keeps the window responsive during slow work) -------------
$script:Jobs = New-Object System.Collections.ArrayList

function Invoke-Async {
    # $Work runs in its own runspace and must be self-contained. It may push progress objects
    # into $Q (a ConcurrentQueue) which are handed to $OnProgress on the UI thread.
    # Callbacks must use $script: state - they run later, in a different scope.
    param([scriptblock]$Work, [object[]]$ArgList = @(), [scriptblock]$OnProgress, [scriptblock]$OnDone)
    $q  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Q', $q)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Work.ToString())
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    $job = [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Q = $q; OnProgress = $OnProgress; OnDone = $OnDone; Timer = $null }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(60)
    $timer.Tag = $job
    $job.Timer = $timer
    $timer.Add_Tick({
        param($s, $e)
        $j = $s.Tag
        $item = $null
        while ($j.Q.TryDequeue([ref]$item)) { if ($j.OnProgress) { & $j.OnProgress $item } }
        if ($j.Handle.IsCompleted) {
            $s.Stop()
            $result = $null; $failure = $null
            try { $result = $j.PS.EndInvoke($j.Handle) } catch { $failure = $_.Exception.Message }
            if (-not $failure -and $j.PS.Streams.Error.Count -gt 0) { $failure = $j.PS.Streams.Error[0].ToString() }
            try { $j.PS.Dispose(); $j.RS.Dispose() } catch { }
            [void]$script:Jobs.Remove($j)
            if ($j.OnDone) { & $j.OnDone $result $failure }
        }
    })
    [void]$script:Jobs.Add($job)
    $timer.Start()
}

# ---- registry / service / task primitives ------------------------------------
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -Path $Path -Force) }
    switch ($Type) {
        'DWord'       { $n = [int64]$Value; if ($n -gt [int]::MaxValue) { $n -= 4294967296 }; $Value = [int]$n }
        'QWord'       { $Value = [int64]$Value }
        'Binary'      { $Value = [byte[]]@($Value) }
        'MultiString' { $Value = [string[]]@($Value) }
        default       { $Value = [string]$Value }
    }
    [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force)
}

function Get-RegValue {
    param([string]$Path, [string]$Name, $Default = $null)
    try { $k = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $Default }
    if ($k.GetValueNames() -notcontains $Name) { return $Default }
    return $k.GetValue($Name, $Default, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Remove-RegValue {
    param([string]$Path, [string]$Name)
    if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
}

function New-RegSnapshot {
    param($It)
    $snap = @{ Path = $It.P; Name = $It.N; Existed = $false }
    try { $k = Get-Item -LiteralPath $It.P -ErrorAction Stop } catch { return $snap }
    if ($k.GetValueNames() -notcontains $It.N) { return $snap }
    $val = $k.GetValue($It.N, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($val -is [byte[]]) { $val = [int[]]$val }
    $snap.Existed = $true
    $snap.Kind    = $k.GetValueKind($It.N).ToString()
    $snap.Value   = $val
    return $snap
}

function Restore-RegSnapshot {
    param($S)
    if ($S.Existed) { Set-Reg $S.Path $S.Name $S.Value $S.Kind } else { Remove-RegValue $S.Path $S.Name }
}

function Test-RegItem {
    param($It)
    $cur = Get-RegValue $It.P $It.N $null
    if ($null -eq $cur) { return $false }
    $type = if ($It.T) { $It.T } else { 'DWord' }
    if ($type -in 'DWord', 'QWord') { try { return ([int64]$cur) -eq ([int64]$It.V) } catch { return $false } }
    return ("$cur" -eq "$($It.V)")
}

function RegItem { param($P, $N, $V, $T = 'DWord') @{ P = $P; N = $N; V = $V; T = $T } }   # tweak shorthand (not 'R': that is an alias for Invoke-History)

function Get-ServiceStartup {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    return [string]$svc.StartType
}

function Set-SvcStartup {
    param([string]$Name, [string]$Mode, [bool]$Delayed = $false)
    if ($Mode -eq 'Automatic' -and $Delayed) {
        $out = & sc.exe config $Name start= delayed-auto 2>&1
        if ($LASTEXITCODE -ne 0) { throw "sc config $Name failed: $out" }
    } else {
        Set-Service -Name $Name -StartupType $Mode -ErrorAction Stop
    }
}

function New-SvcSnapshot {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $delayed = ((Get-RegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" 'DelayedAutostart' 0) -eq 1)
    return @{ Name = $Name; Start = [string]$svc.StartType; Running = ($svc.Status -eq 'Running'); Delayed = $delayed }
}

function Restore-SvcSnapshot {
    param($S)
    if ($S.Start -in 'Automatic', 'Manual', 'Disabled') { Set-SvcStartup $S.Name $S.Start ([bool]$S.Delayed) }
    if ($S.Running) { Start-ServicesFast @($S.Name) }
}

function Split-TaskPath {
    param([string]$Full)
    $i = $Full.LastIndexOf('\')
    return @{ Path = $Full.Substring(0, $i + 1); Name = $Full.Substring($i + 1) }
}

function Get-TaskEnabled {
    param([string]$Full)
    $p = Split-TaskPath $Full
    $t = Get-ScheduledTask -TaskPath $p.Path -TaskName $p.Name -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    return ($t.State -ne 'Disabled')
}

function Set-TaskEnabled {
    param([string]$Full, [bool]$Enabled)
    $p = Split-TaskPath $Full
    if (-not (Get-ScheduledTask -TaskPath $p.Path -TaskName $p.Name -ErrorAction SilentlyContinue)) { return }
    if ($Enabled) { [void](Enable-ScheduledTask -TaskPath $p.Path -TaskName $p.Name -ErrorAction Stop) }
    else          { [void](Disable-ScheduledTask -TaskPath $p.Path -TaskName $p.Name -ErrorAction Stop) }
    Invoke-UiPump
}

# ---- power plan helpers ------------------------------------------------------
function Get-ActivePlan {
    $o = (powercfg /getactivescheme 2>$null | Out-String)
    if ($o -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s+\((.+?)\)') { return [pscustomobject]@{ Guid = $Matches[1]; Name = $Matches[2] } }
    return $null
}

function Invoke-Native {
    # Run a native command; throw with its output on a nonzero exit code.
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try { $out = (& $Command 2>&1 | ForEach-Object { "$_" }) -join ' ' } finally { $ErrorActionPreference = $prev }
    Invoke-UiPump
    if ($LASTEXITCODE -ne 0) { throw "$($Command.ToString().Trim()) -> $($out.Trim()) (exit $LASTEXITCODE)" }
}

function Invoke-NativeOut {
    # Like Invoke-Native but returns { Out, Code } instead of throwing, for settings that are
    # allowed to be missing on some machines.
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try { $out = (& $Command 2>&1 | ForEach-Object { "$_" }) -join "`n" } finally { $ErrorActionPreference = $prev }
    Invoke-UiPump
    return [pscustomobject]@{ Out = $out; Code = $global:LASTEXITCODE }
}

# ---- system facts (read once at start) --------------------------------------
function Find-RustClient {
    if ($script:RustExeCache) { return $script:RustExeCache }
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { return $null }
    if (-not $steam) { return $null }
    $steam = $steam -replace '/', '\'
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value.Replace('\\', '\') }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $p = Join-Path $l 'steamapps\common\Rust\RustClient.exe'
        if (Test-Path -LiteralPath $p) { $script:RustExeCache = $p; return $p }
    }
    return $null
}

function Get-SystemFacts {
    $f = @{}
    $f.Build  = [Environment]::OSVersion.Version.Build
    $f.Win11  = ($f.Build -ge 22000)
    $f.OsName = 'Windows'
    try { $f.OsName = (Get-CimInstance Win32_OperatingSystem).Caption -replace '^Microsoft\s+', '' } catch { }
    $f.RamGB = 0
    try { $f.RamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) } catch { }
    $f.CpuName = 'Unknown CPU'; $f.Cores = 0; $f.Threads = 0
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $f.CpuName = ($cpu.Name -replace '\s+', ' ').Trim()
        $f.Cores = [int]$cpu.NumberOfCores; $f.Threads = [int]$cpu.NumberOfLogicalProcessors
    } catch { }
    $f.X3D        = [bool]($f.CpuName -match 'X3D')
    $f.DualCcdX3D = [bool]($f.CpuName -match '(7|9)9[05]0X3D')
    $f.Gpus = @()
    try { $f.Gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -and $_.Name -notmatch 'Basic|Remote|Virtual|Mirage|Parsec|Meta|Hyper' }) } catch { }
    $f.Laptop = $false
    try { $f.Laptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) } catch { }
    $f.RustExe = Find-RustClient
    $f.RustHdd = $false
    try {
        if ($f.RustExe) {
            $m = [string](Get-Partition -DriveLetter $f.RustExe.Substring(0, 1) -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1).MediaType
            $f.RustHdd = ($m -eq 'HDD')
        }
    } catch { }
    return $f
}

# ---- journal -----------------------------------------------------------------
$script:Journal = @{}

function ConvertTo-Plain {
    param($O)
    if ($null -eq $O) { return $null }
    if ($O -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $O.PSObject.Properties) { $h[$p.Name] = ConvertTo-Plain $p.Value }
        return $h
    }
    if (($O -is [System.Collections.IEnumerable]) -and ($O -isnot [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($i in $O) { [void]$list.Add((ConvertTo-Plain $i)) }
        return ,$list.ToArray()
    }
    return $O
}

function Import-Journal {
    $script:Journal = @{}
    if (-not (Test-Path -LiteralPath $script:JournalFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:JournalFile -Raw -Encoding UTF8
        if ($raw -and $raw.Trim()) {
            $h = ConvertTo-Plain (ConvertFrom-Json $raw)
            if ($h -is [hashtable]) { $script:Journal = $h }
        }
    } catch { Write-Log "Journal unreadable, starting fresh: $($_.Exception.Message)" 'warn' }
}

function Save-Journal {
    Write-TextFile $script:JournalFile (ConvertTo-Json -InputObject $script:Journal -Depth 8)
}

function New-JournalEntry { @{ At = (Get-Date).ToString('s'); Regs = @(); Svcs = @(); Tasks = @(); Extra = @{} } }

function Get-Extra {
    param([string]$Id, [string]$Key)
    if ($script:Journal.ContainsKey($Id)) {
        $x = $script:Journal[$Id].Extra
        if ($x -and $x.ContainsKey($Key)) { return $x[$Key] }
    }
    return $null
}

function Set-Extra {
    param([string]$Id, [string]$Key, $Value)
    if (-not $script:Journal.ContainsKey($Id)) { $script:Journal[$Id] = New-JournalEntry }
    if (-not $script:Journal[$Id].Extra) { $script:Journal[$Id].Extra = @{} }
    $script:Journal[$Id].Extra[$Key] = $Value
    Save-Journal
}

# ---- licence (OTC loader) ----------------------------------------------------
# The signed license tier and expiry are passed by the launcher; legacy Premium keys retain ULTRA access.
$script:FreeIds = @('pwr_plan', 'gpu_gamemode', 'gpu_dvr', 'bg_telemetry', 'bg_widgets', 'bg_tips', 'bg_toasts', 'inp_keys',
                    'prv_adid', 'prv_spotlight', 'pref_dark', 'pref_ext', 'pref_hidden', 'pref_thispc', 'pref_context', 'pref_endtask', 'net_qos')
$script:PlusTweakIds = @()

function Get-PremiumUntil {
    $u = [long]0
    [void][long]::TryParse([string]$env:OTC_PREMIUM_UNTIL, [ref]$u)
    return $u
}

function Test-Premium {
    return ((Get-LicenseTier) -in @('PLUS', 'ULTRA'))
}

function Get-LicenseTier {
    $expiry = Get-PremiumUntil
    if ($expiry -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { return 'FREE' }
    $tier = ([string]$env:OTC_LICENSE_TIER).ToUpperInvariant()
    if ($tier -in @('PLUS', 'ULTRA')) { return $tier }
    return 'ULTRA'
}

function Test-Ultra {
    return ((Get-LicenseTier) -eq 'ULTRA')
}

function Test-TweakLocked {
    param($T)
    $id = [string]$T.Id
    if ($script:FreeIds -contains $id) { return $false }
    switch (Get-LicenseTier) {
        'ULTRA' { return $false }
        'PLUS' { return ($script:PlusTweakIds -notcontains $id) }
        default { return $true }
    }
}

function Invoke-LicenseRevert {
    # No (valid) key: undo every tweak that is locked for the current tier.
    $n = 0
    foreach ($t in @($script:Tweaks)) {
        if (-not (Test-TweakLocked $t)) { continue }
        if (-not ($script:Journal -and $script:Journal.ContainsKey($t.Id))) { continue }
        try {
            Invoke-TweakUndo $t
            $n++
            try { Write-Log "Тариф истёк или понижен, откачено: $($t.Name)" 'accent' } catch { }
        } catch { }
    }
    return $n
}


function Test-LicenseKey {
    # Verifies the ECDSA P-256 signature of a key made by keygen.py.
    # Returns expiry (unix s), 0 = invalid key, -1 = key belongs to another Discord account.
    param([string]$Key)
    try {
        $k = ($Key -replace '\s', '').Replace('-', '+').Replace('_', '/')
        switch ($k.Length % 4) { 2 { $k += '==' } 3 { $k += '=' } }
        $raw = [Convert]::FromBase64String($k)
        if ($raw.Length -ne 80) { return [long]0 }
        $payload = [byte[]]$raw[0..15]
        $sig = [byte[]]$raw[16..79]
        $verified = $false
        foreach ($encodedPub in ([string]$env:OTC_PUBKEY -split ',')) {
            try {
                $pub = [Convert]::FromBase64String($encodedPub)
                if ($pub.Length -ne 64) { continue }
                $blob = New-Object System.Collections.Generic.List[byte]
                $blob.AddRange([byte[]](0x45, 0x43, 0x53, 0x31, 0x20, 0x00, 0x00, 0x00))
                $blob.AddRange([byte[]]$pub)
                $cng = [Security.Cryptography.CngKey]::Import($blob.ToArray(), [Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
                $ec = New-Object Security.Cryptography.ECDsaCng($cng)
                try {
                    $ec.HashAlgorithm = [Security.Cryptography.CngAlgorithm]::Sha256
                    if ($ec.VerifyData($payload, $sig)) { $verified = $true; break }
                } finally { $ec.Dispose() }
            } catch { continue }
        }
        if (-not $verified) { return [long]0 }
        $bound = [uint64]0
        for ($i = 8; $i -lt 16; $i++) { $bound = ($bound -shl 8) -bor [uint64]$payload[$i] }
        if ($bound -ne 0 -and $bound.ToString() -ne [string]$env:OTC_DISCORD_ID) { return [long]-1 }
        $marker = [Text.Encoding]::ASCII.GetString([byte[]]$payload[4..7])
        $script:VerifiedLicenseTier = if ($marker -eq 'PLUS') { 'PLUS' } else { 'ULTRA' }
        return (([long]$payload[0] -shl 24) -bor ([long]$payload[1] -shl 16) -bor ([long]$payload[2] -shl 8) -bor [long]$payload[3])
    } catch { return [long]0 }
}

function Read-KeyDialog {
    $w = New-Object Windows.Window
    $w.Title = 'Активация PLUS / ULTRA'
    $w.Width = 480; $w.Height = 230
    $w.ResizeMode = 'NoResize'
    $w.WindowStartupLocation = 'CenterOwner'
    try { $w.Owner = $script:UI.Win } catch { }
    try { $w.Background = Get-Res 'Bg1' } catch { }
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '18'
    [void]$sp.Children.Add((New-Tb ("Discord: {0} (ID {1})" -f $env:OTC_DISCORD_NAME, $env:OTC_DISCORD_ID) 11.5 'Muted'))
    $lb = New-Tb 'Введите лицензионный ключ:' 13 'Text' $true
    $lb.Margin = '0,12,0,0'
    [void]$sp.Children.Add($lb)
    $tb = New-Object Windows.Controls.TextBox
    $tb.Margin = '0,10,0,16'; $tb.Padding = '6'
    [void]$sp.Children.Add($tb)
    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'
    $ok = New-Object Windows.Controls.Button
    $ok.Content = 'Активировать'; $ok.Padding = '16,6'; $ok.Margin = '0,0,8,0'; $ok.IsDefault = $true
    $cn = New-Object Windows.Controls.Button
    $cn.Content = 'Отмена'; $cn.Padding = '16,6'; $cn.IsCancel = $true
    [void]$row.Children.Add($ok); [void]$row.Children.Add($cn)
    [void]$sp.Children.Add($row)
    $w.Content = $sp
    $script:KeyDlgResult = $null
    $ok.Add_Click({ $script:KeyDlgResult = [string]$tb.Text; $w.DialogResult = $true }.GetNewClosure())
    $w.Add_ContentRendered({ $tb.Focus() | Out-Null }.GetNewClosure())
    [void]$w.ShowDialog()
    return $script:KeyDlgResult
}

function Update-AccountChip {
    $ui = $script:UI
    if (-not $ui.accName) { return }
    $n = [string]$env:OTC_DISCORD_NAME
    if (-not $n) { $n = 'Гость' }
    $ui.accName.Text = $n
    $ui.accInitial.Text = $n.Substring(0, 1).ToUpper()
    $tier = Get-LicenseTier
    $ui.accTier.Text = $tier
    $ui.accTier.Foreground = if ($tier -eq 'ULTRA') {
        (New-Object Windows.Media.BrushConverter).ConvertFromString('#FBBF24')
    } elseif ($tier -eq 'PLUS') {
        (New-Object Windows.Media.BrushConverter).ConvertFromString('#74E9F5')
    } else { Get-Res 'Muted' }
}

function Open-Link {
    param([string]$Url, [string]$What)
    if (-not $Url -or $Url -notmatch '^https?://') { Show-Toast "Ссылка на $What ещё не задана." 'warn'; return }
    try { Start-Process $Url } catch { Show-Toast 'Не удалось открыть ссылку.' 'warn' }
}

function Update-KeyButton {
    try {
        if ($script:UI.btnOptKey) {
            if (Test-Premium) { $script:UI.btnOptKey.Content = "$(Get-LicenseTier) активен" } else { $script:UI.btnOptKey.Content = 'Ввести ключ (PLUS / ULTRA)' }
        }
    } catch { }
    try { Update-AccountChip } catch { }
}

function Update-ColorPremiumState {
    if (-not $script:UI) { return }
    $premium = Test-Premium
    $ultra = Test-Ultra
    $script:UI.pnlColorControls.IsEnabled = $premium
    $script:UI.slColorSaturation.IsEnabled = $ultra
    $script:UI.btnColorVivid.IsEnabled = $ultra
    $script:UI.btnColorApply.IsEnabled = $premium
    $script:UI.btnColorSaveProfile.IsEnabled = $premium
    $script:UI.cmbColorProfiles.IsEnabled = $premium
    $script:UI.btnColorLoadProfile.IsEnabled = $premium
    $script:UI.btnColorDeleteProfile.IsEnabled = $premium
    $script:UI.pnlColorLocked.Visibility = if ($premium) { 'Collapsed' } else { 'Visible' }
    $script:UI.chkRustHolo.IsEnabled = $ultra
    $script:UI.btnRustHoloPremium.Visibility = if ($ultra) { 'Collapsed' } else { 'Visible' }
    if (-not $ultra) {
        $script:ColorValues.Saturation = 100.0
        $script:UI.slColorSaturation.Value = 100
        $script:UI.txtColorSaturation.Text = '100'
    }
    if (-not $ultra) {
        $script:UI.chkRustHolo.IsChecked = $false
        $script:UI.pnlRustHolo.Visibility = 'Collapsed'
        Stop-Anim $script:UI.rustHoloRingRot ([Windows.Media.RotateTransform]::AngleProperty)
    }
    if (-not $premium -and $script:UI.navColor.IsChecked) {
        $script:UI.txtColorStatus.Text = 'Цвета и конфиги доступны в PLUS и ULTRA; насыщенность — только в ULTRA. Восстановление доступно всегда.'
        $script:UI.txtColorStatus.Foreground = Get-Res 'Muted'
    }
}

function Invoke-KeyActivation {
    $key = Read-KeyDialog
    if (-not $key -or -not $key.Trim()) { return }
    $script:VerifiedLicenseTier = $null
    $exp = Test-LicenseKey $key
    if ($exp -eq -1) { [void][Windows.MessageBox]::Show('Этот ключ выдан для другого Discord-аккаунта.', 'PREMIUM'); return }
    if ($exp -le 0) { [void][Windows.MessageBox]::Show('Неверный ключ.', 'PREMIUM'); return }
    if ($exp -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { [void][Windows.MessageBox]::Show('Срок действия этого ключа уже истёк.', 'PREMIUM'); return }
    $previousTier = Get-LicenseTier
    if ($previousTier -eq 'ULTRA' -and $script:VerifiedLicenseTier -ne 'ULTRA') {
        try { [void](Restore-ColorFilter) }
        catch {
            [void][Windows.MessageBox]::Show(
                "Не удалось восстановить цвета дисплея перед переходом на PLUS. Лицензия не была изменена.`n`n$($_.Exception.Message)",
                'OTC OPTI', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error)
            return
        }
    }
    try {
        $dir = Join-Path $env:APPDATA 'OtcLoader'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [IO.File]::WriteAllText((Join-Path $dir 'license.dat'), $key.Trim())
    } catch { Write-Log "Не удалось сохранить ключ: $($_.Exception.Message)" 'warn' }
    $env:OTC_PREMIUM_UNTIL = [string]$exp
    $env:OTC_LICENSE_TIER = [string]$script:VerifiedLicenseTier
    try { [void](Invoke-LicenseRevert) } catch { Write-Log "Не удалось полностью применить ограничения тарифа: $($_.Exception.Message)" 'err' }
    $script:WasPremium = $true
    $script:OptBuilt = $false
    $script:Cards = @{}
    Build-OptPage
    Update-KeyButton
    Update-ColorPremiumState
    Update-ColorProfiles
    try { Update-DashStats } catch { }
    $until = if ($exp -ge 4294967295) { 'Навсегда' } else { [DateTimeOffset]::FromUnixTimeSeconds($exp).ToLocalTime().ToString('dd.MM.yyyy HH:mm') }
    Write-Log "$($script:VerifiedLicenseTier) активирован до $until" 'ok'
    Show-Toast "$($script:VerifiedLicenseTier) активирован до $until" 'ok'
}


# ---- settings page -----------------------------------------------------------
function Invoke-Logout {
    $r = [Windows.MessageBox]::Show('Выйти из аккаунта? Приложение закроется, при следующем запуске нужно снова войти через Discord.', 'Выход', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    try { Remove-Item -LiteralPath (Join-Path $env:APPDATA 'OtcLoader\session.dat') -Force -ErrorAction SilentlyContinue } catch { }
    try { $script:UI.Win.Close() } catch { [Environment]::Exit(0) }
}

function Update-SettingsPage {
    $ui = $script:UI
    if (-not $ui.sName) { return }
    $ui.sName.Text = $(if ($env:OTC_DISCORD_NAME) { [string]$env:OTC_DISCORD_NAME } else { 'Вход не выполнен' })
    $ui.sId.Text = "Discord ID: $($env:OTC_DISCORD_ID)"

    $all = @($script:Tweaks)
    $total = $all.Count
    $free = @($all | Where-Object { $script:FreeIds -contains [string]$_.Id }).Count
    $pct = 0; if ($total -gt 0) { $pct = [int][math]::Round(100 * $free / $total) }

    if (Test-Premium) {
        $until = if ((Get-PremiumUntil) -ge 4294967295) { 'Навсегда' } else { [DateTimeOffset]::FromUnixTimeSeconds((Get-PremiumUntil)).ToLocalTime().ToString('dd.MM.yyyy HH:mm') }
        $ui.sLic.Text = "$(Get-LicenseTier) активен до $until"
        $ui.sLic.Foreground = Get-Res 'Good'
        $ui.sLicSub.Text = if (Test-Ultra) { 'Все оптимизации и функции доступны. После окончания лицензии применённые изменения автоматически откатываются.' } else { 'Доступна подборка PLUS и цветовые настройки без насыщенности. ULTRA открывает все оптимизации.' }
        $ui.btnSetKey.Content = 'Продлить / ввести другой ключ'
        $ui.btnQuick.Content = "Быстрая оптимизация ($(Get-LicenseTier))"
        $ui.sQuick.Text = if (Test-Ultra) { 'Применяет все безопасные оптимизации для этого ПК одним кликом. Перед этим создаётся точка восстановления.' } else { 'Применяет рекомендованные оптимизации, доступные в PLUS. Перед этим создаётся точка восстановления.' }
    } else {
        $ui.sLic.Text = 'Бесплатная версия'
        $ui.sLic.Foreground = Get-Res 'Text'
        $plusCount = @($script:Tweaks | Where-Object { $script:PlusTweakIds -contains [string]$_.Id }).Count
        $plusPct = if ($total -gt 0) { [int][math]::Round(100 * ($free + $plusCount) / $total) } else { 0 }
        $ui.sLicSub.Text = "FREE + PLUS открывают около $plusPct% всех оптимизаций; PLUS добавляет $plusCount оптимизаций без самых мощных и цвета без насыщенности. ULTRA открывает всё."
        $ui.btnSetKey.Content = 'Активация ключа'
        $ui.btnQuick.Content = "Быстрая оптимизация ($pct%)"
        $ui.sQuick.Text = "Бесплатно: $free безопасных оптимизаций одним кликом (около $pct% всех). Перед этим создаётся точка восстановления, всё обратимо."
    }

    # themes
    if ($ui.sThemes) {
        $ui.sThemes.Children.Clear()
        foreach ($tn in @($script:Themes.Keys)) {
            $th = $script:Themes[$tn]
            $b = New-Object Windows.Controls.Button
            $b.Style = Get-Res 'Btn'
            $b.Tag = $tn
            $b.Margin = '0,0,8,8'
            $sp = New-Object Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'
            $dot = New-Object Windows.Shapes.Ellipse
            $dot.Width = 16; $dot.Height = 16; $dot.Margin = '0,0,8,0'
            $gb = New-Object Windows.Media.LinearGradientBrush
            $gb.StartPoint = New-Object Windows.Point 0, 0
            $gb.EndPoint = New-Object Windows.Point 1, 1
            [void]$gb.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($th.Bg3), 0.0))
            [void]$gb.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($th.Accent), 1.0))
            $dot.Fill = $gb
            [void]$sp.Children.Add($dot)
            $label = $tn
            if ($tn -eq $script:ThemeName) { $label = [string][char]0x2713 + ' ' + $tn }
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text = $label
            $tb.VerticalAlignment = 'Center'
            [void]$sp.Children.Add($tb)
            $b.Content = $sp
            $b.Add_Click({ param($s, $e) Invoke-Safe { Set-Theme ([string]$s.Tag) -Save; Update-SettingsPage } 'Theme' })
            [void]$ui.sThemes.Children.Add($b)
        }
    }

    # features list
    $ui.sFeatures.Children.Clear()
    $tier = Get-LicenseTier
    foreach ($grp in $script:Groups) {
        $mine = @($all | Where-Object { $_.Group -eq $grp.Key })
        if ($mine.Count -eq 0) { continue }
        $f = @($mine | Where-Object { $script:FreeIds -contains [string]$_.Id }).Count
        $row = New-Object Windows.Controls.DockPanel
        $row.Margin = '0,0,0,8'
        $chips = New-Object Windows.Controls.StackPanel
        $chips.Orientation = 'Horizontal'
        [Windows.Controls.DockPanel]::SetDock($chips, 'Right')
        $open = @($mine | Where-Object { -not (Test-TweakLocked $_) }).Count
        if ($tier -eq 'ULTRA') { [void]$chips.Children.Add((New-Chip "ОТКРЫТО $open/$($mine.Count)" 'Good' 'Bg1')) }
        else {
            if ($f -gt 0) { [void]$chips.Children.Add((New-Chip "FREE $f" 'Good' 'Bg1')) }
            if ($open -gt $f) { [void]$chips.Children.Add((New-Chip "PLUS $($open - $f)" 'AccentHi' 'Bg1')) }
            if ($mine.Count - $open -gt 0) { [void]$chips.Children.Add((New-Chip "ULTRA $($mine.Count - $open)" 'Warn' 'Bg1')) }
        }
        [void]$row.Children.Add($chips)
        $nm = New-Tb ("{0}  ({1})" -f $grp.Title, $mine.Count) 13 'Text'
        [void]$row.Children.Add($nm)
        [void]$ui.sFeatures.Children.Add($row)
    }
    foreach ($x in @('Быстрая оптимизация', 'Игровая сессия', 'Rust: параметры запуска', 'Интернет и TCP', 'Удаление лишнего', 'Автозапуск', 'Очистка диска', 'Журнал и откат изменений')) {
        $row = New-Object Windows.Controls.DockPanel
        $row.Margin = '0,0,0,8'
        $chips = New-Object Windows.Controls.StackPanel
        $chips.Orientation = 'Horizontal'
        [Windows.Controls.DockPanel]::SetDock($chips, 'Right')
        [void]$chips.Children.Add((New-Chip 'FREE' 'Good' 'Bg1'))
        [void]$row.Children.Add($chips)
        [void]$row.Children.Add((New-Tb $x 13 'Text'))
        [void]$ui.sFeatures.Children.Add($row)
    }
}


# ---- themes ------------------------------------------------------------------
$script:Themes = [ordered]@{
    'Фиолет'   = @{ Bg0 = '#0A0714'; Bg1 = '#110B22'; Bg2 = '#181033'; Bg3 = '#21164A'; Line = '#32225F'; Text = '#F6F2FF'; Muted = '#B4A6DB'; Dim = '#7A6AA8'; Accent = '#C4B5FD'; AccentHi = '#DDD6FE' }
    'Океан'    = @{ Bg0 = '#040E14'; Bg1 = '#07161F'; Bg2 = '#0B2030'; Bg3 = '#102C40'; Line = '#17405A'; Text = '#ECF8FF'; Muted = '#8FB8CE'; Dim = '#4F7F99'; Accent = '#7DD3FC'; AccentHi = '#BAE6FD' }
    'Огонь'    = @{ Bg0 = '#0F0807'; Bg1 = '#170D0B'; Bg2 = '#201210'; Bg3 = '#2B1815'; Line = '#43241E'; Text = '#FFF3EE'; Muted = '#D0A89C'; Dim = '#8A645A'; Accent = '#FDBA74'; AccentHi = '#FED7AA' }
    'Классика' = @{ Bg0 = '#070914'; Bg1 = '#0C0F1F'; Bg2 = '#121629'; Bg3 = '#191E36'; Line = '#242A47'; Text = '#F4F4F4'; Muted = '#98A2C3'; Dim = '#5F6A8E'; Accent = '#FFFFFF'; AccentHi = '#E6E6E6' }
}
$script:ThemeName = 'Фиолет'

function Get-ThemeFile { return (Join-Path $env:APPDATA 'OtcLoader\theme.txt') }

function Set-Theme {
    param([string]$Name, [switch]$Save)
    $th = $script:Themes[$Name]
    if (-not $th) { return }
    foreach ($k in $th.Keys) {
        try {
            $b = Get-Res $k
            $b.Color = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($th[$k])
        } catch { }
    }
    try {
        $c2 = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($th['Bg2'])
        (Get-Res 'CardBg').Color = [Windows.Media.Color]::FromArgb(0xDC, $c2.R, $c2.G, $c2.B)
    } catch { }
    $script:ThemeName = $Name
    if ($Save) {
        try {
            $dir = Join-Path $env:APPDATA 'OtcLoader'
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            [IO.File]::WriteAllText((Get-ThemeFile), $Name)
        } catch { }
    }
}

function Restore-Theme {
    $n = $script:ThemeName
    try { if (Test-Path -LiteralPath (Get-ThemeFile)) { $n = ([IO.File]::ReadAllText((Get-ThemeFile))).Trim() } } catch { }
    if (-not $script:Themes.Contains($n)) { $n = 'Фиолет' }
    Set-Theme $n
}


# ---- animated background -----------------------------------------------------
$script:BgB64 = @'
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
'@

function Set-BgImage {
    try {
        $bytes = [Convert]::FromBase64String(($script:BgB64 -replace '\s', ''))
        $ms = New-Object IO.MemoryStream (, $bytes)
        $bi = New-Object Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.StreamSource = $ms
        $bi.EndInit()
        $bi.Freeze()
        $script:UI.bgMask.ImageSource = $bi
    } catch { }
}

function Update-BgMotion {
    $ui = $script:UI
    if (-not $ui.bgMove) { return }
    $xp = [Windows.Media.TranslateTransform]::XProperty
    $yp = [Windows.Media.TranslateTransform]::YProperty
    $sx = [Windows.Media.ScaleTransform]::ScaleXProperty
    $sy = [Windows.Media.ScaleTransform]::ScaleYProperty
    if (-not $script:AnimOn) {
        $ui.bgMove.BeginAnimation($xp, $null); $ui.bgMove.BeginAnimation($yp, $null)
        $ui.bgScale.BeginAnimation($sx, $null); $ui.bgScale.BeginAnimation($sy, $null)
        return
    }
    $mk = {
        param([double]$From, [double]$To, [double]$Sec)
        $a = New-Object Windows.Media.Animation.DoubleAnimation
        $a.From = $From; $a.To = $To
        $a.Duration = [Windows.Duration][TimeSpan]::FromSeconds($Sec)
        $a.AutoReverse = $true
        $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $e = New-Object Windows.Media.Animation.SineEase
        $e.EasingMode = [Windows.Media.Animation.EasingMode]::EaseInOut
        $a.EasingFunction = $e
        return $a
    }
    $ui.bgMove.BeginAnimation($xp, (& $mk -60 60 19))
    $ui.bgMove.BeginAnimation($yp, (& $mk -40 40 25))
    $ui.bgScale.BeginAnimation($sx, (& $mk 1.10 1.26 31))
    $ui.bgScale.BeginAnimation($sy, (& $mk 1.10 1.26 31))
}

# ---- tweak engine ------------------------------------------------------------
function Get-TweakRegItems {
    param($T)
    if (-not $T.Reg) { return @() }
    if ($T.Reg -is [scriptblock]) { return @(& $T.Reg | Where-Object { $_ }) }
    return @($T.Reg)
}

function Get-TweakBlock {
    # $null when the tweak can run on this PC, otherwise the reason it can't.
    param($T)
    if ($T.When) {
        $r = & $T.When $T
        if (($r -is [string]) -and $r) { return $r }
    }
    return $null
}

function Test-TweakApplied {
    param($T)
    if ($T.Check) { return [bool](& $T.Check $T) }
    $regs = Get-TweakRegItems $T
    $svcs = @($T.Svc | Where-Object { $_ })
    $tasks = @($T.Tasks | Where-Object { $_ })
    if (-not $regs -and -not $svcs -and -not $tasks) { return $false }
    foreach ($it in $regs) { if (-not (Test-RegItem $it)) { return $false } }
    foreach ($s in $svcs) {
        $cur = Get-ServiceStartup $s.N
        if ($null -ne $cur -and $cur -ne $s.S) { return $false }
    }
    foreach ($tk in $tasks) {
        $en = Get-TaskEnabled $tk
        if ($null -ne $en -and $en) { return $false }
    }
    return $true
}

function Invoke-TweakUndo {
    param($T)
    $e = if ($script:Journal.ContainsKey($T.Id)) { $script:Journal[$T.Id] } else { $null }
    if ($T.Undo) { & $T.Undo $T }
    if ($e) {
        for ($i = @($e.Regs).Count - 1; $i -ge 0; $i--) { Restore-RegSnapshot @($e.Regs)[$i] }
        foreach ($s in @($e.Svcs)) { if ($s) { Restore-SvcSnapshot $s } }
        foreach ($tk in @($e.Tasks)) { if ($tk) { if ($tk.Enabled) { Set-TaskEnabled $tk.Name $true } } }
    } else {
        # Applied outside this tool (e.g. by an older version): fall back to removing our values.
        foreach ($it in (Get-TweakRegItems $T)) { Remove-RegValue $it.P $it.N }
        foreach ($s in @($T.Svc | Where-Object { $_ })) { if ($s.D) { Set-SvcStartup $s.N $s.D } }
        foreach ($tk in @($T.Tasks | Where-Object { $_ })) { Set-TaskEnabled $tk $true }
    }
    if ($script:Journal.ContainsKey($T.Id)) { $script:Journal.Remove($T.Id); Save-Journal }
}

function Invoke-TweakApply {
    param($T)
    if (Test-TweakLocked $T) { throw "$(Get-TweakRequiredTier $T): требуется соответствующая лицензия." }
    if (-not $script:Journal.ContainsKey($T.Id)) {
        # Snapshot only once: re-applying must never overwrite the true original values.
        $e = New-JournalEntry
        foreach ($it in (Get-TweakRegItems $T)) { $e.Regs += ,(New-RegSnapshot $it) }
        foreach ($s in @($T.Svc | Where-Object { $_ })) { $snap = New-SvcSnapshot $s.N; if ($snap) { $e.Svcs += ,$snap } }
        foreach ($tk in @($T.Tasks | Where-Object { $_ })) {
            $en = Get-TaskEnabled $tk
            if ($null -ne $en) { $e.Tasks += ,@{ Name = $tk; Enabled = $en } }
        }
        $script:Journal[$T.Id] = $e
        Save-Journal
    }
    try {
        foreach ($it in (Get-TweakRegItems $T)) {
            $type = if ($it.T) { $it.T } else { 'DWord' }
            Set-Reg $it.P $it.N $it.V $type
        }
        $stopNames = @()
        foreach ($s in @($T.Svc | Where-Object { $_ })) {
            $svc = Get-Service -Name $s.N -ErrorAction SilentlyContinue
            if (-not $svc) { continue }
            if ($s.Stop -and $svc.Status -ne 'Stopped') { $stopNames += $s.N }
            Set-SvcStartup $s.N $s.S
        }
        if ($stopNames.Count -gt 0) { Stop-ServicesFast $stopNames }
        foreach ($tk in @($T.Tasks | Where-Object { $_ })) { Set-TaskEnabled $tk $false }
        if ($T.Apply) { & $T.Apply $T }
    } catch {
        $msg = $_.Exception.Message
        try { Invoke-TweakUndo $T } catch { }
        throw $msg
    }
}
# ---- tweak catalog -----------------------------------------------------------
# Fields
#   Impact  0 = no FPS effect (comfort/stability), 1 = small, 2 = noticeable, 3 = large *when the condition applies*
#   Gain    FPS | Lows | Latency | Ping | Stability | Background | Comfort
#   Reg     declarative registry values (snapshotted automatically)   Svc / Tasks   same for services and tasks
#   When    returns $true, or a string explaining why this PC can't use the tweak
#   Rec     recommended (bool or scriptblock). Preferences are never recommended.

$script:Groups = @(
    @{ Key = 'Power';   Title = 'Питание и процессор' }
    @{ Key = 'Sched';   Title = 'Планировщик CPU и память' }
    @{ Key = 'Gpu';     Title = 'Видеокарта и дисплей' }
    @{ Key = 'Rust';    Title = 'Rust (RustClient.exe)' }
    @{ Key = 'Input';   Title = 'Ввод' }
    @{ Key = 'Network'; Title = 'Сеть' }
    @{ Key = 'Svc';     Title = 'Службы и задачи планировщика' }
    @{ Key = 'Bg';      Title = 'Фоновая нагрузка' }
    @{ Key = 'Priv';    Title = 'Приватность, ИИ и реклама' }
    @{ Key = 'Vis';     Title = 'Визуальные эффекты' }
    @{ Key = 'Stab';    Title = 'Стабильность' }
    @{ Key = 'Adv';     Title = 'Расширенные (компромисс с безопасностью)' }
    @{ Key = 'Prefs';   Title = 'Настройки Windows' }
)

function Set-PlanValue {
    param([string]$Guid, [string]$Sub, [string]$Setting, $Value)
    $a = Invoke-NativeOut { powercfg -setacvalueindex $Guid $Sub $Setting $Value }
    $null = Invoke-NativeOut { powercfg -setdcvalueindex $Guid $Sub $Setting $Value }
    return ($a.Code -eq 0)
}

function Find-PlanGuid {
    param([string]$Name)
    foreach ($line in ((powercfg /list 2>$null | Out-String) -split "`r?`n")) {
        if ($line -match ('([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\s+\(' + [regex]::Escape($Name) + '\)')) { return $Matches[1] }
    }
    return $null
}

function Get-TweakCatalog {
    $F = $script:Facts
    $prefAdv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $personal = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $gfx      = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'

    $list = New-Object System.Collections.ArrayList

    # ======================= POWER & CPU =======================
    [void]$list.Add(@{
        Id = 'pwr_plan'; Group = 'Power'; Name = 'Профиль производительности'; Impact = 2; Gain = @('FPS', 'Lows', 'Latency')
        Desc = 'Создаёт отдельный план на основе «Максимальной производительности» (или «Высокой», если её нет): процессор не простаивает ниже 100%, агрессивный буст, отключены энергосбережение USB, PCIe и дисков, Wi-Fi на максимуме. Текущий план запоминается и при откате возвращается.'
        Rec = { -not $script:Facts.Laptop }
        Note = { if ($script:Facts.Laptop) { 'Обнаружен ноутбук: больше нагрева и расход батареи. Используйте только от сети.' }
                 elseif ($script:Facts.DualCcdX3D) { 'Двухчиплетный X3D: парковка ядер не трогается, чтобы планировщик AMD работал.' } }
        Check = { param($t) $p = Get-ActivePlan; return ($p -and $p.Name -eq 'OTC OPTI Performance') }
        Apply = {
            param($t)
            $name = 'OTC OPTI Performance'
            $prev = Get-ActivePlan
            if ($prev -and $prev.Name -ne $name) { Set-Extra $t.Id 'PrevPlan' $prev.Guid }
            $guid = Find-PlanGuid $name
            if (-not $guid) {
                foreach ($src in 'e9a42b02-d5df-448d-aa00-03f14749eb61', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') {
                    $r = Invoke-NativeOut { powercfg -duplicatescheme $src }
                    if ($r.Code -eq 0 -and $r.Out -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { $guid = $Matches[1]; break }
                }
            }
            if (-not $guid) { throw 'Windows would not create a performance plan on this PC (common on Modern Standby laptops).' }
            Invoke-Native { powercfg -changename $guid $name 'Created by OTC OPTI' }
            Set-Extra $t.Id 'PlanGuid' $guid
            $sub = 'SUB_PROCESSOR'
            [void](Set-PlanValue $guid $sub 'PROCTHROTTLEMIN' 100)
            [void](Set-PlanValue $guid $sub 'PROCTHROTTLEMAX' 100)
            [void](Set-PlanValue $guid $sub 'PERFBOOSTMODE' 2)
            [void](Set-PlanValue $guid $sub 'PERFEPP' 0)
            if (-not $script:Facts.DualCcdX3D) { [void](Set-PlanValue $guid $sub 'CPMINCORES' 100) }
            [void](Set-PlanValue $guid '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0)
            [void](Set-PlanValue $guid 'SUB_DISK' 'DISKIDLE' 0)
            [void](Set-PlanValue $guid '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1' '12bbebe6-58d6-4636-95bb-3217ef867c1a' 0)
            if (-not $script:Facts.Laptop) { [void](Set-PlanValue $guid '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 0) }
            Invoke-Native { powercfg -setactive $guid }
        }
        Undo = {
            param($t)
            $guid = Get-Extra $t.Id 'PlanGuid'
            if (-not $guid) { $guid = Find-PlanGuid 'OTC OPTI Performance' }
            $prev = Get-Extra $t.Id 'PrevPlan'
            if (-not $prev -or ((powercfg /list 2>$null | Out-String) -notmatch [regex]::Escape($prev))) { $prev = '381b4222-f694-41f0-9685-ff5bb260df2e' }
            Invoke-Native { powercfg -setactive $prev }
            if ($guid) { $null = Invoke-NativeOut { powercfg -delete $guid } }
        }
    })
    [void]$list.Add(@{
        Id = 'pwr_throttle'; Group = 'Power'; Name = 'Отключить Power Throttling'; Impact = 1; Gain = @('Lows')
        Desc = 'Не даёт Windows загонять потоки, которые она считает фоновыми, на экономичные частоты. Важнее всего на ноутбуках и гибридных процессорах Intel, где вспомогательный поток игры может быть понижен.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1) )
    })

    # ======================= GPU & DISPLAY =======================
    [void]$list.Add(@{
        Id = 'gpu_gamemode'; Group = 'Gpu'; Name = 'Игровой режим включён'; Impact = 1; Gain = @('Lows')
        Desc = 'Windows откладывает установку драйверов и часть фоновой работы, пока игра в фокусе. На большинстве систем уже включено, это просто гарантирует. (Двухчиплетным X3D он необходим.)'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1), (RegItem 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1) )
    })
    [void]$list.Add(@{
        Id = 'gpu_dvr'; Group = 'Gpu'; Name = 'Отключить захват игры'; Impact = 1; Gain = @('FPS', 'Lows')
        Desc = 'Отключает фоновые хуки записи (Game DVR / захват приложений). Имеет смысл, только если вы не пользуетесь клипами Xbox Game Bar; для записи берите OBS или ShadowPlay.'
        Rec = $true
        When = { if ($script:Facts.DualCcdX3D) { 'Пропущено: планировщик двухчиплетных X3D опирается на компоненты Game Bar' } else { $true } }
        Reg = @( (RegItem 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0),
                 (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0) )
    })

    # ======================= RUST =======================
    [void]$list.Add(@{
        Id = 'gpu_pref'; Group = 'Rust'; Name = 'Использовать мощную видеокарту'; Impact = 3; Gain = @('FPS')
        Desc = 'Закрепляет RustClient.exe за быстрой видеокартой в графических настройках Windows. Важно только на ПК со встроенной графикой (ноутбуки и процессоры со встроенным GPU), где Windows может запустить игру не на той.'
        Rec = $true
        When = { if (-not $script:Facts.RustExe) { 'RustClient.exe не найден в библиотеках Steam' }
                 elseif (@($script:Facts.Gpus).Count -lt 2) { 'Обнаружена одна видеокарта, выбирать не из чего' } else { $true } }
        Reg = { $exe = $script:Facts.RustExe; if ($exe) { RegItem 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' $exe 'GpuPreference=2;' 'String' } }
    })
    [void]$list.Add(@{
        Id = 'gpu_fso'; Group = 'Rust'; Name = 'Отключить оптимизацию полного экрана для Rust'; Impact = 1; Gain = @('Latency')
        Desc = 'Флаг совместимости для приложения: Windows считает Rust настоящим эксклюзивным полноэкранным вместо flip-модели. Эффект небольшой и зависит от железа: у одних ниже задержка ввода, у других ничего. Проверяйте.'
        Rec = $false
        When = { if ($script:Facts.RustExe) { $true } else { 'RustClient.exe не найден в библиотеках Steam' } }
        Reg = {
            $exe = $script:Facts.RustExe; if (-not $exe) { return }
            $p = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
            $flags = @(([string](Get-RegValue $p $exe '')) -split '\s+' | Where-Object { $_ -and $_ -ne '~' })
            if ($flags -notcontains 'DISABLEDXMAXIMIZEDWINDOWEDMODE') { $flags += 'DISABLEDXMAXIMIZEDWINDOWEDMODE' }
            RegItem $p $exe ('~ ' + ($flags -join ' ')) 'String'
        }
    })
    [void]$list.Add(@{
        Id = 'rust_defender'; Group = 'Rust'; Name = 'Исключить папку Rust из сканирования Defender'; Impact = 1; Gain = @('Lows')
        Desc = 'Defender в реальном времени не проверяет каждый ресурс, который подгружает Rust, а это вызывает подвисания на медленных накопителях.'
        Note = 'Компромисс: файлы в этой папке больше не проверяются в реальном времени.'
        Rec = $false
        When = {
            if (-not $script:Facts.RustExe) { return 'RustClient.exe не найден в библиотеках Steam' }
            if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { return 'Командлеты Defender недоступны' }
            try { if (-not (Get-MpComputerStatus).RealTimeProtectionEnabled) { return 'Защита Defender в реальном времени выключена (возможно, работает другой антивирус)' } } catch { return 'Defender недоступен' }
            return $true
        }
        Check = { param($t) $dir = Split-Path $script:Facts.RustExe -Parent; return (@((Get-MpPreference).ExclusionPath) -contains $dir) }
        Apply = { param($t) Add-MpPreference -ExclusionPath (Split-Path $script:Facts.RustExe -Parent) }
        Undo  = { param($t) Remove-MpPreference -ExclusionPath (Split-Path $script:Facts.RustExe -Parent) }
    })

    # ======================= INPUT =======================
    [void]$list.Add(@{
        Id = 'inp_keys'; Group = 'Input'; Name = 'Отключить горячие клавиши залипания, фильтрации и переключения'; Impact = 0; Gain = @('Comfort')
        Desc = 'Пятикратное нажатие Shift в бою (спринт) открывает окно залипания клавиш и может свернуть полноэкранную игру. Это отключает такие горячие клавиши. Действует после выхода и повторного входа в систему.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'),
                 (RegItem 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'),
                 (RegItem 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String') )
    })
    [void]$list.Add(@{
        Id = 'inp_mouse'; Group = 'Input'; Name = 'Отключить ускорение мыши'; Impact = 0; Gain = @('Comfort')
        Desc = 'Выключает «Повышенную точность указателя», курсор движется 1:1. Игры с сырым вводом и так её игнорируют, так что эффект в основном в меню и на рабочем столе.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'),
                 (RegItem 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'),
                 (RegItem 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String') )
    })
    [void]$list.Add(@{
        Id = 'inp_timer'; Group = 'Input'; Name = 'Разрешить глобальные запросы разрешения таймера'; Impact = 1; Gain = @('Lows', 'Latency'); Reboot = $true
        Desc = 'Windows 11 игнорирует запросы высокого разрешения таймера от фоновых программ. Это возвращает старое поведение, чтобы таймер 0,5 мс из игровой сессии доходил до игры. Нужна перезагрузка.'
        Rec = $true
        When = { if ($script:Facts.Win11) { $true } else { 'В Windows 10 это уже работает так' } }
        Reg = @( (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1) )
    })

    # ======================= NETWORK =======================
    [void]$list.Add(@{
        Id = 'net_nic'; Group = 'Network'; Name = 'Отключить энергосбережение сетевого адаптера'; Impact = 1; Gain = @('Ping', 'Stability')
        Desc = 'Выключает управление питанием и Energy-Efficient Ethernet на подключённых физических адаптерах: они могут вызывать повторное согласование линка и скачки задержки посреди матча. Больше всего помогает на проводе.'
        Note = 'Подключение пропадёт на секунду-две, пока применяются настройки адаптера.'
        Rec = $true
        Check = { param($t)
            $r = @(Invoke-Blocking -Script {
                $ads = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
                if (-not $ads) { return $false }
                foreach ($a in $ads) {
                    $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
                    if ($pm -and "$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') { return $false }
                }
                return $true })
            return ($r.Count -gt 0 -and [bool]$r[0])
        }
        Apply = { param($t)
            $rows = @(Invoke-Blocking -Script {
                foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
                    try { $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop
                          if ("$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') { [pscustomobject]@{ Kind = 'pm'; Adapter = $a.Name; Kw = ''; Old = 'Enabled' } } } catch { }
                    foreach ($kw in '*EEE', 'EEE', 'EeePhyEnable', 'GreenEthernet', 'AdvancedEEE') {
                        $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -ErrorAction SilentlyContinue
                        if ($p -and $p.RegistryValue -and ("$($p.RegistryValue[0])" -ne '0')) { [pscustomobject]@{ Kind = 'adv'; Adapter = $a.Name; Kw = $kw; Old = "$($p.RegistryValue[0])" } }
                    }
                } })
            if ($rows.Count -eq 0) { Write-Log 'Adapters already had power saving off, or do not expose these settings.' 'info'; return }
            foreach ($r in $rows) { Set-Extra $t.Id ("{0}|{1}|{2}" -f $r.Kind, $r.Adapter, $r.Kw) $r.Old }
            [void](Invoke-Blocking -ArgList @(,$rows) -Script {
                param($rows)
                foreach ($r in $rows) {
                    try {
                        if ($r.Kind -eq 'pm') { Set-NetAdapterPowerManagement -Name $r.Adapter -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop }
                        else { Set-NetAdapterAdvancedProperty -Name $r.Adapter -RegistryKeyword $r.Kw -RegistryValue '0' -ErrorAction Stop }
                    } catch { }
                } })
        }
        Undo = { param($t)
            $x = if ($script:Journal.ContainsKey($t.Id)) { $script:Journal[$t.Id].Extra } else { $null }
            if (-not $x) { return }
            $rows = @(foreach ($k in @($x.Keys)) { $p = $k -split '\|'; [pscustomobject]@{ Kind = $p[0]; Adapter = $p[1]; Kw = $p[2]; Old = [string]$x[$k] } })
            [void](Invoke-Blocking -ArgList @(,$rows) -Script {
                param($rows)
                foreach ($r in $rows) {
                    try {
                        if ($r.Kind -eq 'pm') { Set-NetAdapterPowerManagement -Name $r.Adapter -AllowComputerToTurnOffDevice Enabled -ErrorAction Stop }
                        else { Set-NetAdapterAdvancedProperty -Name $r.Adapter -RegistryKeyword $r.Kw -RegistryValue $r.Old -ErrorAction Stop }
                    } catch { }
                } })
        }
    })
    [void]$list.Add(@{
        Id = 'net_p2p'; Group = 'Network'; Name = 'Запретить Windows Update раздавать обновления другим ПК'; Impact = 1; Gain = @('Ping')
        Desc = 'Отключает одноранговую раздачу Delivery Optimization, чтобы Windows не тратила ваш исходящий канал на обновления во время игры.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0) )
    })
    [void]$list.Add(@{
        Id = 'net_nagle'; Group = 'Network'; Name = 'Отключить алгоритм Нагла и задержку ACK (TCP NoDelay)'; Impact = 2; Gain = @('Ping', 'Latency')
        Desc = 'Отключает задержку подтверждений (TcpAckFrequency = 1, TCPNoDelay = 1, TcpDelAckTicks = 0). Пакеты в онлайн-играх отправляются немедленно без ожидания буфера в 200 мс.'
        Note = 'Применяется ко всем активным сетевым интерфейсам IPv4.'
        Rec = $true
        Check = {
            $ok = $true
            try {
                $sub = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue
                if (-not $sub) { return $false }
                foreach ($k in $sub) {
                    $p = $k.PSPath
                    $af = (Get-ItemProperty -Path $p -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue).TcpAckFrequency
                    $nd = (Get-ItemProperty -Path $p -Name 'TCPNoDelay' -ErrorAction SilentlyContinue).TCPNoDelay
                    if ($af -ne 1 -or $nd -ne 1) { $ok = $false; break }
                }
            } catch { $ok = $false }
            return $ok
        }
        Apply = {
            try {
                $sub = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue
                foreach ($k in $sub) {
                    $p = $k.PSPath
                    Set-ItemProperty -Path $p -Name 'TcpAckFrequency' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $p -Name 'TCPNoDelay' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $p -Name 'TcpDelAckTicks' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                }
                Write-Log 'Nagle algorithm & TCP NoDelay disabled across interfaces.' 'ok'
            } catch { }
        }
        Undo = {
            try {
                $sub = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue
                foreach ($k in $sub) {
                    $p = $k.PSPath
                    Remove-ItemProperty -Path $p -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $p -Name 'TCPNoDelay' -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $p -Name 'TcpDelAckTicks' -ErrorAction SilentlyContinue
                }
                Write-Log 'Nagle algorithm restored to Windows defaults.' 'info'
            } catch { }
        }
    })
    [void]$list.Add(@{
        Id = 'net_throttling'; Group = 'Network'; Name = 'Снять ограничение сетевого троттлинга MMCSS'; Impact = 2; Gain = @('Ping', 'Stability')
        Desc = 'Отключает сетевой троттлинг Windows (NetworkThrottlingIndex = 0xFFFFFFFF, SystemResponsiveness = 0), гарантируя 100% ресурсов CPU для сетевых пакетов в играх.'
        Rec = $true
        Reg = @(
            (RegItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 4294967295),
            (RegItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 0)
        )
    })
    [void]$list.Add(@{
        Id = 'net_qos'; Group = 'Network'; Name = 'Разблокировать 20% резерва полосы пропускания QoS'; Impact = 1; Gain = @('Ping', 'Stability')
        Desc = 'Windows по умолчанию оставляет до 20% сетевого канала под фоновые службы QoS. Твик снимает это ограничение.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0) )
    })
    [void]$list.Add(@{
        Id = 'net_netbios'; Group = 'Network'; Name = 'Отключить широковещательный трафик NetBIOS over TCP/IP'; Impact = 1; Gain = @('Ping', 'Stability')
        Desc = 'Отключает устаревший протокол NetBIOS (NetbiosOptions = 2), устраняя лишний широковещательный сетевой шум и микрофризы.'
        Rec = $true
        Check = {
            $ok = $true
            try {
                $sub = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -ErrorAction SilentlyContinue
                if (-not $sub) { return $false }
                foreach ($k in $sub) {
                    $nb = (Get-ItemProperty -Path $k.PSPath -Name 'NetbiosOptions' -ErrorAction SilentlyContinue).NetbiosOptions
                    if ($nb -ne 2) { $ok = $false; break }
                }
            } catch { $ok = $false }
            return $ok
        }
        Apply = {
            try {
                $sub = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -ErrorAction SilentlyContinue
                foreach ($k in $sub) {
                    Set-ItemProperty -Path $k.PSPath -Name 'NetbiosOptions' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
                }
                Write-Log 'NetBIOS disabled across interfaces.' 'ok'
            } catch { }
        }
        Undo = {
            try {
                $sub = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -ErrorAction SilentlyContinue
                foreach ($k in $sub) {
                    Set-ItemProperty -Path $k.PSPath -Name 'NetbiosOptions' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                }
                Write-Log 'NetBIOS restored.' 'info'
            } catch { }
        }
    })
    [void]$list.Add(@{
        Id = 'net_lso'; Group = 'Network'; Name = 'Отключить аппаратную выгрузку LSO (Large Send Offload)'; Impact = 1; Gain = @('Ping', 'Latency')
        Desc = 'Выключает LSO (Large Send Offload v4/v6) на физических адаптерах, предотвращая задержки пакетов при багах драйверов сетевых карт.'
        Rec = $true
        Check = {
            $r = @(Invoke-Blocking -Script {
                $ads = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
                if (-not $ads) { return $false }
                foreach ($a in $ads) {
                    $lso = Get-NetAdapterLso -Name $a.Name -ErrorAction SilentlyContinue
                    if ($lso -and ($lso.IPv4Enabled -or $lso.IPv6Enabled)) { return $false }
                }
                return $true
            })
            return ($r.Count -gt 0 -and [bool]$r[0])
        }
        Apply = {
            Invoke-Blocking -Script {
                foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
                    try { Disable-NetAdapterLso -Name $a.Name -IPv4 -IPv6 -ErrorAction SilentlyContinue } catch { }
                }
            }
            Write-Log 'LSO disabled on active network adapters.' 'ok'
        }
        Undo = {
            Invoke-Blocking -Script {
                foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
                    try { Enable-NetAdapterLso -Name $a.Name -IPv4 -IPv6 -ErrorAction SilentlyContinue } catch { }
                }
            }
            Write-Log 'LSO re-enabled on active network adapters.' 'info'
        }
    })

    # ======================= BACKGROUND LOAD =======================
    [void]$list.Add(@{
        Id = 'bg_apps'; Group = 'Bg'; Name = 'Запретить приложениям Store работать в фоне'; Impact = 1; Gain = @('Background')
        Desc = 'Пользовательский переключатель, запрещающий UWP-приложениям работать и обновляться в фоне. Освобождает немного ОЗУ и процессорного времени.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0) )
    })
    [void]$list.Add(@{
        Id = 'bg_telemetry'; Group = 'Bg'; Name = 'Отключить службу и задачи телеметрии'; Impact = 1; Gain = @('Background')
        Desc = 'Отключает службу DiagTrack и задачи совместимости / CEIP. Именно они запускают CompatTelRunner и в случайные моменты грузят диск и процессор. Ещё и плюс к приватности.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0) )
        Svc = @( @{ N = 'DiagTrack'; S = 'Disabled'; Stop = $true; D = 'Automatic' }, @{ N = 'dmwappushservice'; S = 'Disabled'; Stop = $true; D = 'Manual' } )
        Tasks = @( '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
                   '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
                   '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
                   '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip' )
    })
    [void]$list.Add(@{
        Id = 'bg_widgets'; Group = 'Bg'; Name = 'Отключить виджеты'; Impact = 1; Gain = @('Background'); Explorer = $true
        Desc = 'Скрывает кнопку «Виджеты» и останавливает панель виджетов и её веб-процессы.'
        Rec = $true
        When = { if ($script:Facts.Win11) { $true } else { 'Только для Windows 11' } }
        Reg = @( (RegItem $prefAdv 'TaskbarDa' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0) )
    })
    [void]$list.Add(@{
        Id = 'bg_edge'; Group = 'Bg'; Name = 'Отключить ускоренный запуск и фоновый режим Edge'; Impact = 1; Gain = @('Background')
        Desc = 'Edge не предзагружается при входе и не висит в памяти после закрытия. Сам Edge не удаляется.'
        Note = 'Используется политика Edge, поэтому edge://policy и настройки Edge скажут «управляется вашей организацией».'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0) )
    })
    [void]$list.Add(@{
        Id = 'bg_tips'; Group = 'Bg'; Name = 'Отключить рекламу, подсказки и автоустановку приложений'; Impact = 0; Gain = @('Background', 'Comfort')
        Desc = 'Выключает рекомендации в меню «Пуск», советы на экране блокировки и тихую установку рекламных приложений.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0),
                 (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1) )
    })

    # ======================= STABILITY =======================
    [void]$list.Add(@{
        Id = 'mem_pagefile'; Group = 'Stab'; Name = 'Вернуть файл подкачки под управлением системы'; Impact = 0; Gain = @('Stability'); Reboot = $true
        Desc = 'Rust может занимать памяти больше, чем у вас есть ОЗУ. Без файла подкачки Windows некуда это деть, и игра может вылететь по нехватке памяти, даже когда ОЗУ кажется свободной. Нужна перезагрузка.'
        Rec = $true
        When = { if (@(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue).Count -gt 0) { 'Файл подкачки уже настроен' } else { $true } }
        Check = { param($t) return (@(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue).Count -gt 0) }
        Apply = { param($t) $cs = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges; $cs.AutomaticManagedPagefile = $true; [void]$cs.Put() }
        Undo  = { param($t) Write-Log 'Page file setting left as is. Change it under System > Advanced > Performance if you really want it off.' 'warn' }
    })
    [void]$list.Add(@{
        Id = 'gpu_tdr'; Group = 'Stab'; Name = 'Увеличить тайм-аут GPU (TDR) до 10 с'; Impact = 0; Gain = @('Stability'); Reboot = $true
        Desc = 'Занятая видеокарта получает 10 секунд вместо 2, прежде чем Windows сбросит драйвер. Имеет смысл только если вы видели «драйвер дисплея перестал отвечать» при компиляции шейдеров. Настоящее зависание будет восстанавливаться дольше.'
        Rec = $false
        Reg = @( (RegItem $gfx 'TdrDelay' 10), (RegItem $gfx 'TdrDdiDelay' 10) )
    })

    # ======================= ADVANCED =======================
    [void]$list.Add(@{
        Id = 'adv_vbs'; Group = 'Adv'; Name = 'Отключить целостность памяти / VBS'; Impact = 3; Gain = @('FPS', 'Lows'); Reboot = $true
        Desc = 'Безопасность на основе виртуализации запускает ядро под гипервизором, это стоит процессорного времени в играх: обычно несколько процентов, иногда больше. Отключение убирает слой защиты Windows (защита ядра от эксплойтов). Делайте это, только если принимаете такой риск.'
        Note = 'Компромисс с безопасностью. Нужна перезагрузка. Не рекомендуется на ПК, где вы работаете с банками или рабочими данными.'
        Rec = $false
        Live = { try {
                    $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
                    if ([int]$dg.VirtualizationBasedSecurityStatus -eq 2) { 'Сейчас: безопасность на основе виртуализации работает' + $(if (@($dg.SecurityServicesRunning) -contains 2) { ' (Целостность памяти включена).' } else { '.' }) }
                    else { 'Сейчас: безопасность на основе виртуализации не работает, поэтому выигрывать здесь нечего.' }
                 } catch { $null } }
        Reg = @( (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0),
                 (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0) )
        Check = { param($t)
            $set = $true
            foreach ($it in (Get-TweakRegItems $t)) { if (-not (Test-RegItem $it)) { $set = $false } }
            if ($set) { return $true }
            try { return ([int](Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop).VirtualizationBasedSecurityStatus -ne 2) } catch { return $false }
        }
    })

    # ======================= WINDOWS PREFERENCES (never in "Recommended") =======================
    [void]$list.Add(@{ Id = 'pref_dark'; Group = 'Prefs'; Name = 'Тёмная тема'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Тёмное оформление приложений и системного интерфейса.'
        Reg = @( (RegItem $personal 'AppsUseLightTheme' 0), (RegItem $personal 'SystemUsesLightTheme' 0) ) })
    [void]$list.Add(@{ Id = 'pref_ext'; Group = 'Prefs'; Name = 'Показывать расширения файлов'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Показывает .exe, .cfg, .txt и т. д. в проводнике. Сложнее попасться на «document.pdf.exe».'
        Reg = @( (RegItem $prefAdv 'HideFileExt' 0) ) })
    [void]$list.Add(@{ Id = 'pref_hidden'; Group = 'Prefs'; Name = 'Показывать скрытые файлы'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Открывает скрытые папки вроде AppData, где лежат конфиги многих игр.'
        Reg = @( (RegItem $prefAdv 'Hidden' 1) ) })
    [void]$list.Add(@{ Id = 'pref_thispc'; Group = 'Prefs'; Name = 'Проводник открывается на «Этот компьютер»'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Проводник стартует с «Этого компьютера», а не с «Главной».'
        Reg = @( (RegItem $prefAdv 'LaunchTo' 1) ) })
    [void]$list.Add(@{ Id = 'pref_tbleft'; Group = 'Prefs'; Name = 'Значки панели задач слева'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Переносит значки панели задач Windows 11 и кнопку «Пуск» влево.'
        When = { if ($script:Facts.Win11) { $true } else { 'Только для Windows 11' } }
        Reg = @( (RegItem $prefAdv 'TaskbarAl' 0) ) })
    [void]$list.Add(@{ Id = 'pref_context'; Group = 'Prefs'; Name = 'Классическое контекстное меню'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Возвращает полное контекстное меню Windows 10 в Windows 11.'
        When = { if ($script:Facts.Win11) { $true } else { 'Только для Windows 11' } }
        Check = { param($t) Test-Path -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' }
        Apply = { param($t) $k = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; [void](New-Item -Path $k -Force); Set-ItemProperty -LiteralPath $k -Name '(default)' -Value '' }
        Undo  = { param($t) Remove-Item -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -ErrorAction SilentlyContinue } })
    [void]$list.Add(@{ Id = 'pref_bing'; Group = 'Prefs'; Name = 'Без веб-результатов в поиске «Пуск»'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Поиск в «Пуск» ищет только на вашем ПК, без Bing.'
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0), (RegItem 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1) ) })
    [void]$list.Add(@{ Id = 'pref_trans'; Group = 'Prefs'; Name = 'Отключить эффекты прозрачности'; Impact = 0; Gain = @('Comfort')
        Desc = 'Убирает акриловое размытие панели задач и окон. Чуть экономит GPU на встроенной графике.'
        Reg = @( (RegItem $personal 'EnableTransparency' 0) ) })
    [void]$list.Add(@{ Id = 'pref_endtask'; Group = 'Prefs'; Name = '«Снять задачу» в меню панели задач'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Добавляет «Снять задачу» в правый клик по панели задач, удобно для зависшей игры.'
        When = { if ($script:Facts.Build -ge 22631) { $true } else { 'Нужна Windows 11 23H2 или новее' } }
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\TaskbarDeveloperSettings' 'TaskbarEndTask' 1) ) })

    $retired = @('sch_pagexec', 'sch_games', 'sch_fth', 'sch_tick', 'svc_wer')   # no measurable benefit or a stability cost
    return @((@($list.ToArray()) + @(Get-ExtraTweaks)) | Where-Object { ($retired -notcontains $_.Id) -or ($script:Journal -and $script:Journal.ContainsKey($_.Id)) })
}

function Test-TweakRecommended {
    param($T)
    if ($null -eq $T.Rec) { return $false }
    if ($T.Rec -is [scriptblock]) { return [bool](& $T.Rec) }
    return [bool]$T.Rec
}
# ---- extra tweaks (v7) ---------------------------------------------------------
function Get-BcdValue {
    param([string]$Name)
    $r = Invoke-NativeOut { bcdedit /enum '{current}' }
    if ($r.Out -match ('(?im)^\s*' + [regex]::Escape($Name) + '\s+(\S+)')) { return $Matches[1] }
    return $null
}

function Get-IntelGen {
    # 2..14 for Intel Core iX-NNNN / NNNNN, otherwise $null
    $n = $script:Facts.CpuName
    if ($n -match 'Core\(TM\)\s+i[3579]-(\d{4,5})') {
        $d = $Matches[1]
        if ($d.Length -eq 5) { return [int]$d.Substring(0, 2) } else { return [int]$d.Substring(0, 1) }
    }
    return $null
}

function Get-NicTweakRows {
    param([string[]]$Keywords, [string]$WantValue = '0')
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ([string]$_.PhysicalMediaType) -match '802\.3' })) {
        foreach ($kw in $Keywords) {
            $p = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -ErrorAction SilentlyContinue
            if ($p -and $p.RegistryValue -and ("$($p.RegistryValue[0])" -ne $WantValue)) { [pscustomobject]@{ Adapter = $a.Name; Kw = $kw; Old = "$($p.RegistryValue[0])" } }
        }
    }
}

function Set-NicRows {
    param($Rows, [string]$Value = '')
    foreach ($r in @($Rows)) {
        try { $v = if ($Value -ne '') { $Value } else { $r.Old }; Set-NetAdapterAdvancedProperty -Name $r.Adapter -RegistryKeyword $r.Kw -RegistryValue $v -ErrorAction Stop } catch { }
    }
}

function Get-ExtraTweaks {
    $list = New-Object System.Collections.ArrayList
    $mm   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $memk = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $gfx  = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $cdm  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

    # ======================= CPU SCHEDULING & MEMORY =======================
    [void]$list.Add(@{ Id = 'sch_prio'; Group = 'Sched'; Name = 'Приоритет активного окна (короткие фиксированные кванты)'; Impact = 1; Gain = @('Lows', 'Latency')
        Desc = 'Устанавливает Win32PrioritySeparation в 0x26. Окно, с которым вы работаете, получает больше процессорного времени, чем фон, короткими фиксированными квантами. Значение Windows по умолчанию равно 2. Один из немногих параметров планировщика с реальным, пусть и небольшим, влиянием на ровность frametime.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38) ) })
    [void]$list.Add(@{ Id = 'sch_mmcss'; Group = 'Sched'; Name = 'Мультимедийный планировщик: приоритет переднему плану'; Impact = 1; Gain = @('Lows')
        Desc = 'Резервирует 0% процессора под фоновые мультимедиа-задачи (по умолчанию 20%) и снимает сетевое ограничение. Действует только на программы, использующие MMCSS, а многие игры не используют, поэтому эффект небольшой.'
        Rec = $true
        Reg = @( (RegItem $mm 'SystemResponsiveness' 0), (RegItem $mm 'NetworkThrottlingIndex' 4294967295) ) })
    [void]$list.Add(@{ Id = 'sch_games'; Group = 'Sched'; Name = 'Задача «Games»: высший класс планирования'; Impact = 1; Gain = @('Lows')
        Desc = 'Поднимает профиль MMCSS «Games» до приоритета GPU 8, приоритета CPU 6, высокого класса планирования и высокого приоритета хранилища. Работает для игр с MMCSS, для остальных безвредно.'
        Rec = $true
        Reg = @( (RegItem "$mm\Tasks\Games" 'GPU Priority' 8), (RegItem "$mm\Tasks\Games" 'Priority' 6),
                 (RegItem "$mm\Tasks\Games" 'Scheduling Category' 'High' 'String'), (RegItem "$mm\Tasks\Games" 'SFIO Priority' 'High' 'String') ) })
    [void]$list.Add(@{ Id = 'sch_hags'; Group = 'Sched'; Name = 'Аппаратное планирование GPU включено'; Impact = 1; Gain = @('Latency', 'FPS'); Reboot = $true
        Desc = 'Видеокарта сама управляет очередью памяти вместо процессора. Помогает на новых картах, особенно с генерацией кадров (DLSS / FSR 3). На некоторых GPU и драйверах нейтрально или чуть хуже.'
        Note = 'Проверьте: запустите одну и ту же сцену в Rust до и после. Если 1% low стали хуже, откатите.'
        Rec = $false
        When = { if ($script:Facts.Build -ge 19041) { $true } else { 'Нужна Windows 10 2004 или новее' } }
        Reg = @( (RegItem $gfx 'HwSchMode' 2) ) })
    [void]$list.Add(@{ Id = 'sch_pagexec'; Group = 'Sched'; Name = 'Держать ядро в ОЗУ'; Impact = 1; Gain = @('Lows'); Reboot = $true
        Desc = 'Windows не выгружает код ядра и драйверов в подкачку. При большом объёме ОЗУ это избавляет от редких фризов в несколько миллисекунд, когда кусок драйвера приходится подгружать обратно.'
        Rec = { $script:Facts.RamGB -ge 15 }
        When = { if ($script:Facts.RamGB -ge 15) { $true } else { 'Нужно 16 ГБ ОЗУ или больше' } }
        Reg = @( (RegItem $memk 'DisablePagingExecutive' 1) ) })
    [void]$list.Add(@{ Id = 'sch_memcomp'; Group = 'Sched'; Name = 'Отключить сжатие памяти'; Impact = 1; Gain = @('Lows'); Reboot = $true
        Desc = 'Windows в фоне сжимает неактивные страницы памяти, на это уходит немного процессорного времени. При 16 ГБ и больше сжатие почти не нужно. При меньшем объёме лучше оставить.'
        Rec = $false
        When = { if (-not (Get-Command Get-MMAgent -ErrorAction SilentlyContinue)) { 'Не поддерживается в этой Windows' } elseif ($script:Facts.RamGB -lt 15) { 'Нужно 16 ГБ ОЗУ или больше' } else { $true } }
        Check = { param($t) return (-not (Get-MMAgent).MemoryCompression) }
        Apply = { param($t) [void](Invoke-Blocking -Script { Disable-MMAgent -MemoryCompression }) }
        Undo  = { param($t) [void](Invoke-Blocking -Script { Enable-MMAgent -MemoryCompression }) } })
    [void]$list.Add(@{ Id = 'sch_tick'; Group = 'Sched'; Name = 'Отключить динамический тик'; Impact = 1; Gain = @('Latency'); Reboot = $true
        Desc = 'Системный таймер тикает с постоянной частотой, а не пропускает тики в простое. На некоторых системах frame pacing становится ровнее. Энергопотребление в простое немного растёт.'
        Note = 'Эффект на многих системах не доказан. Оставляйте, только если замерили разницу.'
        Rec = $false
        Check = { param($t) return ((Get-BcdValue 'disabledynamictick') -eq 'Yes') }
        Apply = { param($t) Invoke-Native { bcdedit /set disabledynamictick yes } }
        Undo  = { param($t) $null = Invoke-NativeOut { bcdedit /deletevalue disabledynamictick } } })
    [void]$list.Add(@{ Id = 'sch_maint'; Group = 'Sched'; Name = 'Отключить автоматическое обслуживание'; Impact = 1; Gain = @('Lows', 'Background')
        Desc = 'Windows не запускает в простое обслуживание (дефрагментацию, проверки, диагностику) посреди сессии. Обновления Windows и проверки Defender по-прежнему можно запускать вручную.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1) ) })
    [void]$list.Add(@{ Id = 'sch_fast'; Group = 'Sched'; Name = 'Отключить быстрый запуск'; Impact = 0; Gain = @('Stability')
        Desc = 'Быстрый запуск сохраняет снимок ядра при выключении, так что «выключение» на деле гибернация. Без него каждое выключение чистое, это сбрасывает зависшие драйверы и странные состояния GPU.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0) ) })
    [void]$list.Add(@{ Id = 'sch_hibernate'; Group = 'Sched'; Name = 'Отключить гибернацию (освободить место)'; Impact = 0; Gain = @('Comfort')
        Desc = 'Удаляет hiberfil.sys, примерно 40% от размера ОЗУ на диске (часто 6-20 ГБ).'
        Rec = $false
        When = { if ($script:Facts.Laptop) { 'Ноутбукам нужна гибернация для защиты данных при разряде' } else { $true } }
        Check = { param($t) return ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 1) -eq 0) }
        Apply = { param($t) Invoke-Native { powercfg /hibernate off } }
        Undo  = { param($t) Invoke-Native { powercfg /hibernate on } } })
    [void]$list.Add(@{ Id = 'sch_defscan'; Group = 'Sched'; Name = 'Проверки Defender с низким приоритетом'; Impact = 1; Gain = @('Background')
        Desc = 'Защита Defender остаётся полностью включённой, но проверки идут с минимальным приоритетом и не более 10% процессора в среднем, поэтому не навредят игре.'
        Rec = $true
        When = {
            if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { return 'Командлеты Defender недоступны' }
            try { if (-not (Get-MpComputerStatus).RealTimeProtectionEnabled) { return 'Защита Defender в реальном времени выключена (возможно, работает другой антивирус)' } } catch { return 'Defender недоступен' }
            return $true }
        Check = { param($t) $p = Get-MpPreference; return ([int]$p.ScanAvgCPULoadFactor -le 10 -and [bool]$p.EnableLowCpuPriority) }
        Apply = { param($t) $p = Get-MpPreference
                  Set-Extra $t.Id 'Load' ([string][int]$p.ScanAvgCPULoadFactor); Set-Extra $t.Id 'Low' ([string][bool]$p.EnableLowCpuPriority)
                  Set-MpPreference -ScanAvgCPULoadFactor 10 -EnableLowCpuPriority $true }
        Undo  = { param($t) $l = Get-Extra $t.Id 'Load'; $w = Get-Extra $t.Id 'Low'
                  if ($l) { Set-MpPreference -ScanAvgCPULoadFactor ([int]$l) }
                  if ($w) { Set-MpPreference -EnableLowCpuPriority ($w -eq 'True') } } })
    [void]$list.Add(@{ Id = 'sch_wudrv'; Group = 'Sched'; Name = 'Windows Update не подменяет драйвер GPU'; Impact = 0; Gain = @('Stability')
        Desc = 'Не даёт Windows Update молча заменять драйвер NVIDIA / AMD более старым, а это классическая причина «вчера всё летало, а сегодня просадка FPS». Драйвер вы по-прежнему обновляете сами у производителя.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1) ) })
    [void]$list.Add(@{ Id = 'sch_mitig'; Group = 'Adv'; Name = 'Отключить защиту от уязвимостей CPU (только старые Intel)'; Impact = 3; Gain = @('FPS', 'Lows'); Reboot = $true
        Desc = 'Отключает программные заплатки Spectre / Meltdown. На Intel 9-го поколения и старше они стоят реальной производительности, у новых процессоров защита аппаратная, поэтому там твик заблокирован.'
        Note = 'Реальный компромисс с безопасностью: открывает атаки по побочным каналам. Нужна перезагрузка.'
        Rec = $false
        When = { $g = Get-IntelGen; if ($null -ne $g -and $g -le 9) { $true } else { 'Доступно только для Intel Core 9-го поколения и старше. У новых процессоров прирост был бы меньше 1%.' } }
        Reg = @( (RegItem $memk 'FeatureSettingsOverride' 3), (RegItem $memk 'FeatureSettingsOverrideMask' 3) ) })

    # ======================= GPU & DISPLAY (more) =======================
    [void]$list.Add(@{ Id = 'gpu_swap'; Group = 'Gpu'; Name = 'Оптимизации для оконных / безрамочных игр'; Impact = 2; Gain = @('FPS', 'Latency')
        Desc = 'Игры DirectX 10/11 в оконном или безрамочном режиме используют быструю flip-модель вывода, как в эксклюзивном полноэкранном режиме. Большой выигрыш только если вы не играете в эксклюзивном полноэкранном.'
        Rec = $true
        When = { if ($script:Facts.Win11) { $true } else { 'Только для Windows 11' } }
        Reg = { RegItem 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' 'SwapEffectUpgradeEnable=1;' 'String' } })
    [void]$list.Add(@{ Id = 'gpu_fsegl'; Group = 'Gpu'; Name = 'Отключить оптимизацию полного экрана (для всех игр)'; Impact = 1; Gain = @('Latency')
        Desc = 'Глобальная версия настройки для игры: игры, запрашивающие эксклюзивный полноэкранный режим, получают его, а не подмену от Windows. На некоторых системах снижает задержку ввода, на других ничего не меняет.'
        Rec = $false
        Reg = @( (RegItem 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2), (RegItem 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1),
                 (RegItem 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1), (RegItem 'HKCU:\System\GameConfigStore' 'GameDVR_EFSEFeatureFlags' 0) ) })
    [void]$list.Add(@{ Id = 'gpu_mpo'; Group = 'Gpu'; Name = 'Отключить Multiplane Overlay (MPO)'; Impact = 1; Gain = @('Stability'); Reboot = $true
        Desc = 'MPO известная причина фризов, мерцания и чёрных экранов на некоторых версиях драйверов NVIDIA и AMD, в основном в безрамочном режиме. Помогает только если у вас есть эти симптомы.'
        Rec = $false
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5) ) })

    # ======================= INPUT (more) =======================
    [void]$list.Add(@{ Id = 'inp_kbd'; Group = 'Input'; Name = 'Максимально быстрый повтор клавиш'; Impact = 0; Gain = @('Comfort')
        Desc = 'Минимальная задержка и максимальная скорость повтора при наборе и в меню. Действует после выхода и повторного входа.'
        Rec = $false
        Reg = @( (RegItem 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' 'String'), (RegItem 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String') ) })

    # ======================= SERVICES & SCHEDULED TASKS =======================
    [void]$list.Add(@{ Id = 'svc_sysmain'; Group = 'Svc'; Name = 'Отключить SysMain (Superfetch)'; Impact = 1; Gain = @('Lows', 'Background')
        Desc = 'SysMain предзагружает приложения в ОЗУ и может вызывать скачки диска и памяти. Он делался для жёстких дисков, а на SSD почти ничего не даёт.'
        Rec = { -not $script:Facts.RustHdd }
        When = { if ($script:Facts.RustHdd) { 'Rust на жёстком диске, где SysMain действительно помогает' } else { $true } }
        Svc = @( @{ N = 'SysMain'; S = 'Disabled'; Stop = $true; D = 'Automatic' } ) })
    [void]$list.Add(@{ Id = 'svc_search'; Group = 'Svc'; Name = 'Отключить индексацию Windows Search'; Impact = 1; Gain = @('Background')
        Desc = 'Индексатор не читает диск в фоне. Поиск файлов из «Пуск» станет медленнее, поиск приложений работает по-прежнему.'
        Rec = $false
        Svc = @( @{ N = 'WSearch'; S = 'Disabled'; Stop = $true; D = 'Automatic' } ) })
    [void]$list.Add(@{ Id = 'svc_misc'; Group = 'Svc'; Name = 'Отключить неиспользуемые фоновые службы'; Impact = 1; Gain = @('Background')
        Desc = 'Загрузчик карт, демо-режим, факс, Insider, служба телефона, геолокация, кошелёк, общий доступ к медиа, удалённый реестр и службы смешанной реальности. Для игр они не нужны.'
        Rec = $true
        Svc = @( @{ N = 'MapsBroker'; S = 'Disabled'; Stop = $true; D = 'Automatic' }, @{ N = 'RetailDemo'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'Fax'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'wisvc'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'PhoneSvc'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'lfsvc'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'WalletService'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'WMPNetworkSvc'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'RemoteRegistry'; S = 'Disabled'; Stop = $true; D = 'Disabled' }, @{ N = 'SharedRealitySvc'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'spectrum'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'perceptionsimulation'; S = 'Disabled'; Stop = $true; D = 'Manual' } ) })
    [void]$list.Add(@{ Id = 'svc_xbox'; Group = 'Svc'; Name = 'Отключить службы Xbox'; Impact = 1; Gain = @('Background')
        Desc = 'Отключает службы авторизации Xbox, синхронизации сохранений, аксессуаров и сети.'
        Note = 'Ломает вход в приложение Xbox, игры Game Pass и облачные сохранения Xbox. Пропустите, если пользуетесь чем-то из этого.'
        Rec = $false
        Svc = @( @{ N = 'XblAuthManager'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'XblGameSave'; S = 'Disabled'; Stop = $true; D = 'Manual' },
                 @{ N = 'XboxNetApiSvc'; S = 'Disabled'; Stop = $true; D = 'Manual' }, @{ N = 'XboxGipSvc'; S = 'Disabled'; Stop = $true; D = 'Manual' } ) })
    [void]$list.Add(@{ Id = 'svc_spooler'; Group = 'Svc'; Name = 'Отключить диспетчер печати'; Impact = 0; Gain = @('Background')
        Desc = 'Останавливает службу печати, у которой долгая история уязвимостей. Предлагается, только если физический принтер не установлен.'
        Rec = $false
        When = { try { $p = @(Get-Printer -ErrorAction Stop | Where-Object { $_.Name -notmatch 'PDF|XPS|OneNote|Fax' }); if ($p.Count -gt 0) { 'Установлен физический принтер' } else { $true } } catch { $true } }
        Svc = @( @{ N = 'Spooler'; S = 'Disabled'; Stop = $true; D = 'Automatic' } ) })
    [void]$list.Add(@{ Id = 'svc_tasks'; Group = 'Svc'; Name = 'Отключить лишние задачи диагностики и отзывов'; Impact = 1; Gain = @('Background')
        Desc = 'Отключает задачи очереди отчётов об ошибках, запросов отзывов, обновления карт, сбора данных диагностики дисков и анализа энергоэффективности. Они просыпаются в случайный момент и грузят диск и процессор.'
        Rec = $true
        Tasks = @( '\Microsoft\Windows\Windows Error Reporting\QueueReporting', '\Microsoft\Windows\Feedback\Siuf\DmClient', '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
                   '\Microsoft\Windows\Maps\MapsUpdateTask', '\Microsoft\Windows\Maps\MapsToastTask', '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
                   '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem', '\Microsoft\Windows\DiskFootprint\Diagnostics', '\Microsoft\Windows\Autochk\Proxy' ) })
    [void]$list.Add(@{ Id = 'svc_wer'; Group = 'Svc'; Name = 'Отключить отчёты об ошибках Windows'; Impact = 0; Gain = @('Background')
        Desc = 'Сбои не собираются и не отправляются. Экономит всплеск диска и процессора после каждого сбоя.'
        Note = 'Вы теряете дампы сбоев Windows, и разбираться со сбоем становится сложнее.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1) )
        Svc = @( @{ N = 'WerSvc'; S = 'Disabled'; Stop = $true; D = 'Manual' } ) })

    # ======================= BACKGROUND LOAD (more) =======================
    [void]$list.Add(@{ Id = 'bg_onedrive'; Group = 'Bg'; Name = 'Отключить синхронизацию OneDrive (политика)'; Impact = 1; Gain = @('Background')
        Desc = 'Запрещает OneDrive синхронизироваться и работать в фоне. Файлы не удаляются. Чтобы удалить программу совсем, используйте вкладку «Удаление лишнего».'
        Rec = $false
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1) ) })
    [void]$list.Add(@{ Id = 'bg_toasts'; Group = 'Bg'; Name = 'Отключить всплывающие уведомления'; Impact = 0; Gain = @('Comfort')
        Desc = 'Больше никаких уведомлений поверх игры, которые перехватывают фокус.'
        Rec = $false
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0) ) })
    [void]$list.Add(@{ Id = 'bg_highlights'; Group = 'Bg'; Name = 'Отключить «Основные моменты» в поиске'; Impact = 0; Gain = @('Background'); Explorer = $true
        Desc = 'Убирает дудл дня и популярное из строки поиска, которые грузят веб-контент в фоне.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0) ) })

    # ======================= PRIVACY, AI & ADS =======================
    [void]$list.Add(@{ Id = 'prv_copilot'; Group = 'Priv'; Name = 'Отключить Windows Copilot'; Impact = 1; Gain = @('Background')
        Desc = 'Отключает боковую панель Copilot и его фоновые компоненты через политику.'
        Rec = $true
        When = { if ($script:Facts.Win11) { $true } else { 'Только для Windows 11' } }
        Reg = @( (RegItem 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1) ) })
    [void]$list.Add(@{ Id = 'prv_recall'; Group = 'Priv'; Name = 'Отключить Recall / анализ данных ИИ'; Impact = 1; Gain = @('Background')
        Desc = 'Отключает снимки Windows AI и анализ данных на устройстве. Они могут грузить NPU, GPU или диск в фоне. Безвредно, если функции на вашем ПК нет.'
        Rec = $true
        When = { if ($script:Facts.Build -ge 22621) { $true } else { 'Нужна Windows 11 22H2 или новее' } }
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1), (RegItem 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1) ) })
    [void]$list.Add(@{ Id = 'prv_cortana'; Group = 'Priv'; Name = 'Отключить Cortana и веб-поиск'; Impact = 0; Gain = @('Background')
        Desc = 'Отключает Cortana, использование местоположения в поиске и веб-результаты в Windows Search.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowSearchToUseLocation' 0),
                 (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1) ) })
    [void]$list.Add(@{ Id = 'prv_activity'; Group = 'Priv'; Name = 'Отключить журнал действий'; Impact = 0; Gain = @('Background')
        Desc = 'Windows не записывает и не синхронизирует то, что вы открываете, а это постоянные записи на диск.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0), (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0) ) })
    [void]$list.Add(@{ Id = 'prv_adid'; Group = 'Priv'; Name = 'Отключить рекламный идентификатор и персональную рекламу'; Impact = 0; Gain = @('Comfort')
        Desc = 'Выключает пользовательский рекламный ID и «персонализированные возможности» на основе диагностических данных.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0), (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0),
                 (RegItem 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1) ) })
    [void]$list.Add(@{ Id = 'prv_input'; Group = 'Priv'; Name = 'Отключить сбор данных ввода и рукописного ввода'; Impact = 0; Gain = @('Comfort')
        Desc = 'Windows не собирает то, что вы печатаете и пишете, для персонализации подсказок.'
        Rec = $true
        Reg = @( (RegItem 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1), (RegItem 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1),
                 (RegItem 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0) ) })
    [void]$list.Add(@{ Id = 'prv_spotlight'; Group = 'Priv'; Name = 'Отключить рекламу на экране блокировки и в Spotlight'; Impact = 0; Gain = @('Comfort')
        Desc = 'Убирает рекламу Spotlight, интересные факты и предлагаемые приложения с экрана блокировки и из параметров.'
        Rec = $true
        Reg = @( (RegItem $cdm 'RotatingLockScreenOverlayEnabled' 0), (RegItem $cdm 'SubscribedContent-338387Enabled' 0), (RegItem $cdm 'SubscribedContent-353694Enabled' 0),
                 (RegItem $cdm 'SubscribedContent-353696Enabled' 0), (RegItem $cdm 'SubscribedContent-310093Enabled' 0), (RegItem $cdm 'ContentDeliveryAllowed' 0), (RegItem $cdm 'OemPreInstalledAppsEnabled' 0), (RegItem $cdm 'PreInstalledAppsEnabled' 0) ) })

    # ======================= VISUAL EFFECTS =======================
    [void]$list.Add(@{ Id = 'vis_snappy'; Group = 'Vis'; Name = 'Более быстрый интерфейс (без анимаций)'; Impact = 0; Gain = @('Comfort'); Explorer = $true
        Desc = 'Убирает задержку меню, анимацию сворачивания и разворачивания окон, анимации панели задач и задержку Aero Peek. Windows работает мгновенно. Чуть экономит GPU на встроенной графике.'
        Rec = $false
        Reg = @( (RegItem 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String'), (RegItem 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0), (RegItem 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0),
                 (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0), (RegItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0) ) })

    # ======================= GAME-CHANGERS (only offered where they apply) =======================
    [void]$list.Add(@{ Id = 'sch_hpet'; Group = 'Sched'; Name = 'Убрать принудительный таймер HPET'; Impact = 2; Gain = @('FPS', 'Lows', 'Latency'); Reboot = $true
        Desc = 'Старые гайды советовали «bcdedit /set useplatformclock true», это принудительно включает медленный таймер HPET на всю ОС и портит frame pacing. Если на вашем ПК такая настройка стоит, твик убирает её и даёт Windows выбрать лучший таймер. Если нет, твик скрыт.'
        Rec = $true
        When = { if ((Get-BcdValue 'useplatformclock') -eq 'Yes') { $true } else { 'Не применимо: ваш ПК не форсирует HPET' } }
        Check = { param($t) return ((Get-BcdValue 'useplatformclock') -ne 'Yes') }
        Apply = { param($t) $null = Invoke-NativeOut { bcdedit /deletevalue useplatformclock } }
        Undo  = { param($t) Invoke-Native { bcdedit /set useplatformclock true } } })
    [void]$list.Add(@{ Id = 'sch_fth'; Group = 'Stab'; Name = 'Отключить Fault Tolerant Heap'; Impact = 2; Gain = @('Lows', 'Stability')
        Desc = 'После нескольких сбоев программы Windows тихо включает для неё медленные «безопасные» прослойки памяти (Fault Tolerant Heap). Игра, которая однажды вылетела, может после этого постоянно работать медленнее, и никто об этом не скажет. Твик отключает функцию, чтобы ничего не замедлялось за вашей спиной.'
        Rec = $true
        Reg = @( (RegItem 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled' 0) ) })
    [void]$list.Add(@{ Id = 'sch_hyper'; Group = 'Adv'; Name = 'Отключить гипервизор (Hyper-V / платформа VBS)'; Impact = 3; Gain = @('FPS', 'Lows'); Reboot = $true
        Desc = 'Отключает гипервизор Windows при загрузке. Пока он работает (Hyper-V, WSL2, Docker, Песочница Windows, целостность памяти), вся ОС стоит поверх него, и это стоит процессорного времени в играх. Без него планирование и таймеры нативные.'
        Note = 'Ломает WSL2, Docker Desktop, Песочницу Windows, подсистему Android и виртуальные машины Hyper-V, пока не откатите. Нужна перезагрузка.'
        Rec = $false
        When = { try { if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent) { $true } else { 'Гипервизор не запущен, выигрывать нечего' } } catch { $true } }
        Check = { param($t) return ((Get-BcdValue 'hypervisorlaunchtype') -eq 'Off') }
        Apply = { param($t) Invoke-Native { bcdedit /set hypervisorlaunchtype off } }
        Undo  = { param($t) $null = Invoke-NativeOut { bcdedit /set hypervisorlaunchtype auto } } })
    [void]$list.Add(@{ Id = 'net_lat'; Group = 'Network'; Name = 'Режим низкой задержки Ethernet'; Impact = 1; Gain = @('Ping', 'Latency')
        Desc = 'Отключает модерацию прерываний, large-send offload и управление потоком на проводном адаптере. Пакеты доходят до процессора сразу, а не пачками, это может снизить джиттер в UDP-играх. Стоит немного процессорного времени, а на слабых процессорах может снизить пик скорости загрузки.'
        Note = 'Только проводные адаптеры. Подключение на мгновение пропадёт. Замерьте результат на вкладке «Интернет».'
        Rec = $false
        When = { try { if (@(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and ([string]$_.PhysicalMediaType) -match '802\.3' }).Count -gt 0) { $true } else { 'Подключённый проводной адаптер не найден' } } catch { 'Сетевые адаптеры недоступны' } }
        Check = { param($t)
            if (-not $script:Journal.ContainsKey($t.Id)) { return $false }
            $n = @(Invoke-Blocking -Functions 'Get-NicTweakRows' -Script { @(Get-NicTweakRows @('*InterruptModeration', '*FlowControl', '*LsoV2IPv4', '*LsoV2IPv6')).Count })
            return ($n.Count -gt 0 -and [int]$n[0] -eq 0)
        }
        Apply = { param($t)
            $rows = @(Invoke-Blocking -Functions 'Get-NicTweakRows' -Script { Get-NicTweakRows @('*InterruptModeration', '*FlowControl', '*LsoV2IPv4', '*LsoV2IPv6') })
            if ($rows.Count -eq 0) { throw 'Your adapter does not expose these settings, or they are already off.' }
            foreach ($r in $rows) { Set-Extra $t.Id ("adv|{0}|{1}" -f $r.Adapter, $r.Kw) $r.Old }
            [void](Invoke-Blocking -Functions 'Set-NicRows' -ArgList @(,$rows) -Script { param($rows) Set-NicRows $rows '0' })
        }
        Undo = { param($t)
            $x = if ($script:Journal.ContainsKey($t.Id)) { $script:Journal[$t.Id].Extra } else { $null }
            if (-not $x) { return }
            $rows = @(foreach ($k in @($x.Keys)) { $p = $k -split '\|'; [pscustomobject]@{ Adapter = $p[1]; Kw = $p[2]; Old = [string]$x[$k] } })
            [void](Invoke-Blocking -Functions 'Set-NicRows' -ArgList @(,$rows) -Script { param($rows) Set-NicRows $rows })
        } })
    [void]$list.Add(@{ Id = 'svc_nvtelem'; Group = 'Svc'; Name = 'Отключить службу телеметрии NVIDIA'; Impact = 1; Gain = @('Background')
        Desc = 'Останавливает контейнер телеметрии NVIDIA, который отправляет данные об использовании и просыпается в фоне. Драйверы, Панель управления и функции GeForce продолжают работать.'
        Rec = $true
        When = { if (Get-Service -Name NvTelemetryContainer -ErrorAction SilentlyContinue) { $true } else { 'Служба телеметрии NVIDIA отсутствует' } }
        Svc = @( @{ N = 'NvTelemetryContainer'; S = 'Disabled'; Stop = $true; D = 'Automatic' } ) })
    [void]$list.Add(@{ Id = 'app_discord'; Group = 'Bg'; Name = 'Отключить аппаратное ускорение Discord'; Impact = 1; Gain = @('FPS', 'Lows')
        Desc = 'По умолчанию Discord рисует интерфейс на видеокарте и конкурирует с игрой за время GPU и VRAM. Отключение переносит эту работу на процессор. Эффект заметнее всего на видеокартах среднего уровня. Голос и трансляция выглядят так же.'
        Note = 'Discord должен быть закрыт на время применения, затем откройте его снова.'
        Rec = $true
        When = { if (-not (Test-Path -LiteralPath (Join-Path $env:APPDATA 'discord\settings.json'))) { 'Файл настроек Discord не найден' } elseif (Get-Process -Name Discord -ErrorAction SilentlyContinue) { 'Сначала закройте Discord, затем откройте страницу заново' } else { $true } }
        Check = { param($t)
            $f = Join-Path $env:APPDATA 'discord\settings.json'
            if (-not (Test-Path -LiteralPath $f)) { return $false }
            try { $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; return (($j.PSObject.Properties.Name -contains 'enableHardwareAcceleration') -and ($j.enableHardwareAcceleration -eq $false)) } catch { return $false } }
        Apply = { param($t)
            $f = Join-Path $env:APPDATA 'discord\settings.json'
            if (Get-Process -Name Discord -ErrorAction SilentlyContinue) { throw 'Close Discord first.' }
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            $has = ($j.PSObject.Properties.Name -contains 'enableHardwareAcceleration')
            Set-Extra $t.Id 'Old' $(if ($has) { [string]$j.enableHardwareAcceleration } else { '(absent)' })
            if (-not (Test-Path -LiteralPath "$f.romopti.bak")) { Copy-Item -LiteralPath $f -Destination "$f.romopti.bak" -Force }
            if ($has) { $j.enableHardwareAcceleration = $false } else { Add-Member -InputObject $j -NotePropertyName 'enableHardwareAcceleration' -NotePropertyValue $false -Force }
            Write-TextFile $f (ConvertTo-Json -InputObject $j -Depth 20) }
        Undo = { param($t)
            $f = Join-Path $env:APPDATA 'discord\settings.json'
            if (-not (Test-Path -LiteralPath $f)) { return }
            if (Get-Process -Name Discord -ErrorAction SilentlyContinue) { throw 'Close Discord first.' }
            $old = Get-Extra $t.Id 'Old'
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($old -eq '(absent)') { [void]$j.PSObject.Properties.Remove('enableHardwareAcceleration') }
            else { $j.enableHardwareAcceleration = ($old -ne 'False') }
            Write-TextFile $f (ConvertTo-Json -InputObject $j -Depth 20) } })

    return $list.ToArray()
}
# ---- findings: what is actually limiting this PC -------------------------------
function Get-Findings {
    param($F = $script:Facts, $NativeOk = $script:NativeOk)
    $out = New-Object System.Collections.ArrayList
    function Add-Finding { param($Level, $Title, $Detail) [void]$out.Add([pscustomobject]@{ Level = $Level; Title = $Title; Detail = $Detail }) }

    # Refresh rate: the most common free win
    try {
        if ($NativeOk) {
            $d = [RomNative]::DisplayInfo()
            if ($d[0] -gt 0) {
                if ($d[1] -gt ($d[0] + 5)) {
                    Add-Finding 'warn' "Монитор работает на $($d[0]) Гц, но поддерживает $($d[1]) Гц" "Windows не использует полную частоту обновления панели при $($d[2])x$($d[3]). Исправьте в Параметры > Система > Дисплей > Расширенный дисплей. Это самое частое бесплатное улучшение."
                } else {
                    Add-Finding 'ok' "Дисплей работает на $($d[0]) Гц" 'Это максимальная частота панели при текущем разрешении.'
                }
            }
        }
    } catch { }

    # RAM size and speed
    try {
        if ($F.RamGB -gt 0 -and $F.RamGB -lt 15) {
            Add-Finding 'warn' "$($F.RamGB) ГБ ОЗУ маловато для Rust" 'Rust регулярно занимает 12 ГБ и больше. С 8 ГБ будут фризы из-за подкачки. Больше памяти лучше любого твика в этом приложении.'
        }
        $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        if ($mods.Count -eq 1 -and -not $F.Laptop -and $F.RamGB -ge 4) { Add-Finding 'warn' 'Установлена только одна планка памяти' 'Одна планка работает в одноканальном режиме, это примерно вдвое снижает пропускную способность памяти. Две одинаковые планки в слотах из руководства к плате дают большой прирост в играх с упором в CPU вроде Rust.' }
        $conf = ($mods | ForEach-Object { [int]$_.ConfiguredClockSpeed } | Where-Object { $_ -gt 0 } | Measure-Object -Minimum).Minimum
        $rated = ($mods | ForEach-Object { [int]$_.Speed } | Where-Object { $_ -gt 0 } | Measure-Object -Maximum).Maximum
        if ($conf) {
            if ($rated -and $rated -gt ($conf + 200)) {
                Add-Finding 'warn' "ОЗУ работает на $conf МТ/с, хотя рассчитана на $rated МТ/с" 'Профиль XMP / EXPO / DOCP почти наверняка выключен. Включите его в BIOS. Скорость памяти один из самых больших бесплатных приростов для Rust, особенно в 1% low.'
            } elseif ($conf -le 2933) {
                Add-Finding 'info' "ОЗУ работает на $conf МТ/с" 'Если на коробке или наклейке указана большая скорость, включите XMP / EXPO / DOCP в BIOS.'
            } else {
                Add-Finding 'ok' "ОЗУ работает на $conf МТ/с" 'Память работает на хорошей частоте.'
            }
        }
    } catch { }

    # Where Rust is installed
    try {
        if ($F.RustExe) {
            $letter = $F.RustExe.Substring(0, 1)
            $media = $null
            try { $media = [string](Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1).MediaType } catch { }
            if ($media -eq 'HDD') {
                Add-Finding 'warn' "Rust установлен на жёстком диске ($letter`:)" 'Это даёт долгие загрузки и фризы подгрузки, которые не исправит ни один твик. Перенесите Rust на SSD (Steam > Свойства > Установленные файлы > Переместить папку установки).'
            } elseif ($media) {
                $bus = ''
                try { $bus = [string](Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1).BusType } catch { }
                $kind = if ($bus -eq 'NVMe') { 'NVMe SSD' } else { 'SSD' }
                Add-Finding 'ok' "Rust установлен на $kind ($letter`:)" 'Хорошо, подгрузка ресурсов не упрётся в накопитель.'
                try {
                    $tr = Invoke-NativeOut { fsutil behavior query DisableDeleteNotify }
                    if ($tr.Out -match 'NTFS DisableDeleteNotify\s*=\s*1') { Add-Finding 'warn' 'TRIM выключен' 'TRIM не даёт скорости записи и ровности кадров со временем падать. Включите его из консоли администратора: fsutil behavior set DisableDeleteNotify 0' }
                } catch { }
            }
            $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$letter`:'" -ErrorAction Stop
            if ($ld.Size -gt 0) {
                $pct = [math]::Round(100 * $ld.FreeSpace / $ld.Size)
                if ($pct -lt 12) { Add-Finding 'warn' "Диск $letter`: заполнен на $(100 - $pct)%" "SSD замедляются и фризят, когда почти заполнены. Держите свободными минимум 10-15% (у вас $(Format-Bytes $ld.FreeSpace)). Поможет вкладка «Очистка диска»." }
            }
        } else {
            Add-Finding 'info' 'Rust не найден в библиотеках Steam' 'Инструменты для Rust (выбор GPU, пресеты, параметры запуска) станут доступны, когда в Steam будет установлен Rust.'
        }
    } catch { }

    # GPUs
    try {
        $gpus = @($F.Gpus)
        if ($gpus.Count -ge 2) {
            Add-Finding 'info' "Обнаружено видеоадаптеров: $($gpus.Count)" ((($gpus | ForEach-Object { $_.Name }) -join '  /  ') + '. Убедитесь, что Rust запускается на мощном: примените «Использовать мощную видеокарту» в разделе «Оптимизация».')
        }
    } catch { }

    foreach ($g in @($F.Gpus)) {
        try {
            if ($g.DriverDate) {
                $age = [int]((Get-Date) - [datetime]$g.DriverDate).TotalDays
                if ($age -gt 240) { Add-Finding 'info' "Драйвер $($g.Name) устарел на $age дн." 'Новые драйверы часто содержат исправления и оптимизацию под игры. Скачайте его у производителя GPU сами: это приложение драйверы не ставит.' }
            }
        } catch { }
    }

    # Power plan
    try {
        $plan = Get-ActivePlan
        if ($plan) {
            if ($plan.Name -match 'Balanced|saver') {
                Add-Finding 'info' "План питания: $($plan.Name)" 'Сбалансированный план повышает частоты с небольшой задержкой. План производительности из раздела «Оптимизация» убирает её ценой энергопотребления в простое.'
            } else {
                Add-Finding 'ok' "План питания: $($plan.Name)" 'Уже ориентирован на производительность.'
            }
        }
    } catch { }

    # VBS
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        if ([int]$dg.VirtualizationBasedSecurityStatus -eq 2) {
            Add-Finding 'info' 'Безопасность на основе виртуализации (VBS) работает' 'Она отнимает часть производительности CPU в играх (часто несколько процентов). Отключение это компромисс с безопасностью, поэтому оно включается вручную в Оптимизация > Расширенные.'
        }
    } catch { }

    # Page file
    try {
        if (@(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop).Count -eq 0) {
            Add-Finding 'warn' 'Файл подкачки не настроен' 'Rust может вылетать с ошибкой нехватки памяти, даже когда ОЗУ кажется свободной. Исправьте в Оптимизация > Стабильность.'
        }
    } catch { }

    if ($F.X3D) { Add-Finding 'info' 'Обнаружен процессор Ryzen X3D' 'Оставьте Игровой режим включённым и не трогайте парковку ядер на двухчиплетных моделях. OTC OPTI уже пропускает конфликтующие твики за вас.' }
    if ($F.Laptop) { Add-Finding 'info' 'Обнаружен ноутбук' 'Играйте от сети. Твики производительности рассчитаны на питание от розетки и повышают нагрев и расход батареи.' }

    return @($out)
}

# ---- disk cleaner --------------------------------------------------------------
function Get-CleanTasks {
    return @(
        @{ Id = 'usertemp'; Name = 'Временные файлы пользователя'; Rec = $true;  Paths = @($env:TEMP, "$env:LOCALAPPDATA\Temp")
           Desc = 'Остатки установщиков и приложений. Используемые файлы пропускаются.' }
        @{ Id = 'wintemp';  Name = 'Временные файлы Windows'; Rec = $true; Paths = @("$env:windir\Temp")
           Desc = 'Общесистемная папка Temp.' }
        @{ Id = 'wu';       Name = 'Кэш загрузок Windows Update'; Rec = $true; Paths = @("$env:windir\SoftwareDistribution\Download"); Stop = @('wuauserv', 'bits')
           Desc = 'Установщики, которые Windows уже использовала. Службы обновления на время очистки приостанавливаются, затем возвращаются.' }
        @{ Id = 'wer';      Name = 'Отчёты об ошибках и дампы сбоев'; Rec = $true; Paths = @("$env:LOCALAPPDATA\Microsoft\Windows\WER", "$env:ProgramData\Microsoft\Windows\WER", "$env:LOCALAPPDATA\CrashDumps", "$env:windir\Minidump")
           Desc = 'Сохранённые данные сбоев. Пропустите, если сейчас разбираетесь со сбоем.' }
        @{ Id = 'thumb';    Name = 'Кэш миниатюр и значков'; Rec = $true; Paths = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer"); Filter = @('thumbcache_*.db', 'iconcache_*.db')
           Desc = 'Пересоздаётся автоматически при необходимости.' }
        @{ Id = 'shader';   Name = 'Шейдерные кэши GPU (только при проблемах)'; Rec = $false; Paths = @("$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache", "$env:LOCALAPPDATA\AMD\DxCache", "$env:LOCALAPPDATA\AMD\DxcCache")
           Desc = 'Очищайте только если игра фризит после обновления драйвера. Кэш пересоберётся при следующем запуске, поэтому первая сессия будет скорее хуже, чем лучше.' }
        @{ Id = 'inet';     Name = 'Интернет-кэш (устаревший)'; Rec = $false; Paths = @("$env:LOCALAPPDATA\Microsoft\Windows\INetCache")
           Desc = 'Кэшированное веб-содержимое старого хранилища WinINet.' }
        @{ Id = 'recycle';  Name = 'Очистить корзину'; Rec = $false; Special = 'recycle'
           Desc = 'Необратимо. Удалённые элементы восстановить не получится.' }
        @{ Id = 'dns';      Name = 'Сбросить кэш DNS'; Rec = $false; Special = 'dns'
           Desc = 'Исправляет устаревшие записи имён. Место на диске не освобождает.' }
    )
}

# Runs in a background runspace, so it is fully self-contained.
$script:CleanWork = {
    param($Tasks, [bool]$DoDelete)
    function Get-Files {
        param($Root, $Filters)
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try { foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                    if ($Filters -and $Filters.Count -gt 0) {
                        $leaf = [System.IO.Path]::GetFileName($f); $hit = $false
                        foreach ($flt in $Filters) { if ($leaf -like $flt) { $hit = $true; break } }
                        if (-not $hit) { continue }
                    }
                    $f } } catch { }
            if ($Filters -and $Filters.Count -gt 0) { continue }
            try { foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) } } catch { }
        }
    }
    $total = 0.0
    foreach ($t in $Tasks) {
        $Q.Enqueue(@{ Kind = 'start'; Id = $t.Id })
        if ($t.Special) {
            if ($DoDelete) {
                if ($t.Special -eq 'recycle') { try { Clear-RecycleBin -Force -ErrorAction Stop; $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Text = 'emptied' }) } catch { $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Text = 'already empty' }) } }
                if ($t.Special -eq 'dns')     { try { & ipconfig.exe /flushdns | Out-Null; $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Text = 'flushed' }) } catch { $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Text = 'failed' }) } }
            } else { $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Text = '-' }) }
            continue
        }
        $stopped = @()
        if ($DoDelete -and $t.Stop) { foreach ($s in $t.Stop) { try { $svc = Get-Service $s -ErrorAction Stop; if ($svc.Status -eq 'Running') { Stop-Service $s -Force -ErrorAction Stop; $stopped += $s } } catch { } } }
        $bytes = 0.0; $n = 0
        foreach ($root in $t.Paths) {
            if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
            foreach ($f in (Get-Files $root $t.Filter)) {
                try {
                    $len = ([System.IO.FileInfo]$f).Length
                    if ($DoDelete) { [System.IO.File]::Delete($f) }
                    $bytes += $len
                } catch { }
                $n++
                if (($n % 300) -eq 0) { $Q.Enqueue(@{ Kind = 'tick'; Id = $t.Id; Bytes = $bytes }) }
            }
            if ($DoDelete -and -not $t.Filter) {
                try { foreach ($d in [System.IO.Directory]::EnumerateDirectories($root)) { try { [System.IO.Directory]::Delete($d, $true) } catch { } } } catch { }
            }
        }
        foreach ($s in $stopped) { try { Start-Service $s -ErrorAction SilentlyContinue } catch { } }
        $total += $bytes
        $Q.Enqueue(@{ Kind = 'done'; Id = $t.Id; Bytes = $bytes })
    }
    $Q.Enqueue(@{ Kind = 'total'; Bytes = $total })
}

# ---- game session -------------------------------------------------------------
$script:SessionSvcNames = @('SysMain', 'WSearch', 'DiagTrack', 'wuauserv', 'BITS', 'DoSvc', 'WerSvc', 'MapsBroker')
$script:KillGroups = [ordered]@{
    'Браузеры'    = @('chrome', 'msedge', 'firefox', 'opera', 'brave', 'vivaldi')
    'OneDrive'        = @('OneDrive')
    'Epic Launcher'   = @('EpicGamesLauncher', 'EpicWebHelper')
    'Spotify'         = @('Spotify')
    'RGB-софт'    = @('iCUE', 'LightingService', 'ArmouryCrate.Service', 'ArmourySwAgent', 'RazerAppEngine', 'SteelSeriesGG', 'Lghub', 'lghub_agent')
    'Discord (голос!)' = @('Discord')
}
$script:Session = @{ Active = $false; Timer = $false; Stopped = @(); Prio = $false; Purge = $false; Counters = $null }

function Get-MemSnapshot {
    if (-not $script:Session.Counters) {
        try {
            $c = @{}
            foreach ($n in 'Standby Cache Normal Priority Bytes', 'Standby Cache Reserve Bytes', 'Standby Cache Core Bytes', 'Free & Zero Page List Bytes') {
                $c[$n] = New-Object System.Diagnostics.PerformanceCounter('Memory', $n)
            }
            $script:Session.Counters = $c
        } catch { return $null }
    }
    try {
        $c = $script:Session.Counters
        $standby = $c['Standby Cache Normal Priority Bytes'].NextValue() + $c['Standby Cache Reserve Bytes'].NextValue() + $c['Standby Cache Core Bytes'].NextValue()
        $free = $c['Free & Zero Page List Bytes'].NextValue()
        return @{ Standby = $standby; Free = $free }
    } catch { return $null }
}

function Invoke-PurgeStandby {
    param([switch]$Quiet)
    if (-not $script:NativeOk) { if (-not $Quiet) { Write-Log 'Native helpers did not load, cannot purge.' 'err' }; return }
    $before = Get-MemSnapshot
    $r = [RomNative]::PurgeStandby()
    if ($r -eq 0) {
        $after = Get-MemSnapshot
        if ($before -and $after) { Write-Log ("Standby list purged, {0} returned to free memory." -f (Format-Bytes ([math]::Max(0, $after.Free - $before.Free)))) 'ok' }
        else { Write-Log 'Standby list purged.' 'ok' }
    } else { Write-Log ("Standby purge failed (NTSTATUS 0x{0:X8})." -f $r) 'err' }
}

function Save-SessionState {
    Write-TextFile $script:SessionFile (ConvertTo-Json -InputObject @{ Services = @($script:Session.Stopped) } -Depth 4)
}

function Restore-OrphanedSession {
    # If the app was killed mid-session, services it stopped must not stay stopped.
    if (-not (Test-Path -LiteralPath $script:SessionFile)) { return }
    try {
        $j = Get-Content -LiteralPath $script:SessionFile -Raw | ConvertFrom-Json
        $n = 0
        $svcList = @($j.Services | Where-Object { $_ })
        if ($svcList.Count -gt 0) { Start-ServicesFast $svcList; $n = $svcList.Count }
        Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction SilentlyContinue
        if ($n -gt 0) { Write-Log "Recovered from an interrupted session: restarted $n service(s)." 'warn' }
    } catch { Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction SilentlyContinue }
}

function Start-GameSession {
    param($Opt)
    if ($script:Session.Active) { return }
    $script:Session.Active = $true
    if ($Opt.Timer -and $script:NativeOk) {
        $ms = [RomNative]::HoldFinestTimer()
        if ($ms -gt 0) { $script:Session.Timer = $true; Write-Log ("Системный таймер удерживается на {0:N3} мс." -f $ms) 'ok' }
        else { Write-Log 'Windows отклонила запрос таймера.' 'err' }
    }
    if ($Opt.Services) {
        $stopped = @()
        foreach ($n in $script:SessionSvcNames) {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') { $stopped += $n }
        }
        $script:Session.Stopped = $stopped
        Save-SessionState
        Stop-ServicesFast $stopped
        Write-Log "Paused $($stopped.Count) background service(s) until the session ends." 'ok'
    }
    $script:Session.Prio  = [bool]$Opt.Priority
    $script:Session.Pin   = [bool]$Opt.Pin
    $script:Session.Purge = [bool]$Opt.Purge
    $script:Session.Tick  = 0
}

function Stop-GameSession {
    if (-not $script:Session.Active) { return }
    if ($script:Session.Timer -and $script:NativeOk) { [RomNative]::ReleaseTimer(); $script:Session.Timer = $false }
    $n = 0
    $n = @($script:Session.Stopped).Count
    Start-ServicesFast @($script:Session.Stopped)
    $script:Session.Stopped = @()
    Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction SilentlyContinue
    Reset-GameAffinity
    $script:Session.Active = $false; $script:Session.Prio = $false; $script:Session.Purge = $false; $script:Session.Pin = $false
    Write-Log "Сессия завершена. Таймер освобождён, служб перезапущено: $n." 'accent'
}

function Close-BackgroundApps {
    param([string[]]$Names)
    $closed = 0; $ram = 0.0
    $procs = @()
    foreach ($n in $Names) { $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue) }
    foreach ($p in $procs) { try { $ram += $p.WorkingSet64; [void]$p.CloseMainWindow() } catch { } }
    Wait-Ui 1500
    foreach ($p in $procs) {
        try { $p.Refresh(); if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction Stop }; $closed++ } catch { }
    }
    if ($closed -gt 0) { Write-Log ("Closed {0} process(es), about {1} of RAM." -f $closed, (Format-Bytes $ram)) 'ok' } else { Write-Log 'Ничего из выбранного не было запущено.' 'info' }
}

# ---- Rust: launch options and client.cfg ---------------------------------------
function Get-RustLaunchOptions {
    param($Opt)
    $F = $script:Facts
    $parts = New-Object System.Collections.ArrayList
    if ($Opt.High)    { [void]$parts.Add('-high') }
    if ($Opt.Exclusive) { [void]$parts.Add('-window-mode exclusive') }
    if ($Opt.Cpu -and $F.Cores -gt 0) { [void]$parts.Add("-cpuCount=$($F.Cores)"); [void]$parts.Add("-exThreads=$($F.Threads)") }
    if ($Opt.D3d)     { [void]$parts.Add('-force-d3d11-no-singlethreaded') }
    if ($Opt.NoLog)   { [void]$parts.Add('-nolog') }
    return ($parts -join ' ')
}

# Convars that exist in the live game. gc.buffer is the one with a measurable stutter effect.
$script:RustPresets = @{
    Max = [ordered]@{ 'gc.buffer' = '4096'; 'graphics.shadowdistance' = '0'; 'graphics.shadowlights' = '0'; 'graphics.parallax' = '0'
        'effects.motionblur' = 'false'; 'effects.dof' = 'false'; 'effects.ao' = 'false'; 'effects.vignet' = 'false'; 'effects.shafts' = 'false'; 'effects.lensdirt' = 'false'; 'grass.displacement' = 'false' }
    Competitive = [ordered]@{ 'gc.buffer' = '4096'; 'graphics.shadowdistance' = '75'; 'graphics.shadowlights' = '1'; 'graphics.parallax' = '0'
        'effects.motionblur' = 'false'; 'effects.dof' = 'false'; 'effects.ao' = 'false'; 'effects.vignet' = 'false'; 'effects.shafts' = 'false'; 'effects.lensdirt' = 'false' }
    Balanced = [ordered]@{ 'gc.buffer' = '2048'; 'graphics.shadowdistance' = '150'; 'graphics.shadowlights' = '2'
        'effects.motionblur' = 'false'; 'effects.dof' = 'false'; 'effects.vignet' = 'false'; 'effects.lensdirt' = 'false' }
}

function Get-RustCfgPath {
    if (-not $script:Facts.RustExe) { return $null }
    return (Join-Path (Split-Path $script:Facts.RustExe -Parent) 'cfg\client.cfg')
}

function Set-RustPreset {
    param([string]$Key)
    if (Get-Process -Name RustClient -ErrorAction SilentlyContinue) { throw 'Rust is running. Close it first, it rewrites client.cfg when it exits.' }
    $cfg = Get-RustCfgPath
    if (-not $cfg) { throw 'Rust не найден в библиотеках Steam.' }
    if (-not (Test-Path -LiteralPath $cfg)) { throw 'client.cfg does not exist yet. Start Rust once and quit it, then try again.' }
    $bak = "$cfg.romopti.bak"
    if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $cfg -Destination $bak -Force }
    $set = $script:RustPresets[$Key]
    $kept = New-Object System.Collections.ArrayList
    foreach ($ln in (Get-Content -LiteralPath $cfg)) {
        $managed = $false
        foreach ($k in $set.Keys) { if ($ln -match ('^\s*' + [regex]::Escape($k) + '\s')) { $managed = $true; break } }
        if (-not $managed) { [void]$kept.Add($ln) }
    }
    foreach ($k in $set.Keys) { [void]$kept.Add(('{0} "{1}"' -f $k, $set[$k])) }
    Write-TextFile $cfg (($kept -join "`r`n") + "`r`n")
    return $set.Count
}

function Restore-RustCfg {
    $cfg = Get-RustCfgPath
    if (-not $cfg) { throw 'Rust не найден в библиотеках Steam.' }
    $bak = "$cfg.romopti.bak"
    if (-not (Test-Path -LiteralPath $bak)) { throw 'No backup exists yet, so nothing has been changed.' }
    if (Get-Process -Name RustClient -ErrorAction SilentlyContinue) { throw 'Close Rust first.' }
    Copy-Item -LiteralPath $bak -Destination $cfg -Force
}

function New-RestorePoint {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $old = Get-RegValue $key 'SystemRestorePointCreationFrequency' $null
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Set-Reg $key 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description 'OTC OPTI' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    } finally {
        if ($null -eq $old) { Remove-RegValue $key 'SystemRestorePointCreationFrequency' } else { Set-Reg $key 'SystemRestorePointCreationFrequency' $old }
    }
}

function New-RestorePointAsync {
    # Checkpoint-Computer can take 10-30 seconds, so it runs in a worker while the window stays alive.
    [void](Invoke-Blocking -TimeoutSec 240 -Functions 'New-RestorePoint', 'Get-RegValue', 'Set-Reg', 'Remove-RegValue' -Script { New-RestorePoint })
}
# ---- debloat -------------------------------------------------------------------
# Safe = recommended removal for nearly everyone. Optional = real apps some people use.
function Get-DebloatCatalog {
    $rows = @(
        # Microsoft apps almost nobody uses
        ,@('3D Viewer',                 'ms',    $true,  @('Microsoft.Microsoft3DViewer'))
        ,@('Mixed Reality Portal',      'ms',    $true,  @('Microsoft.MixedReality.Portal'))
        ,@('Paint 3D',                  'ms',    $true,  @('Microsoft.MSPaint'))
        ,@('Print 3D',                  'ms',    $true,  @('Microsoft.Print3D'))
        ,@('Clipchamp video editor',    'ms',    $true,  @('Clipchamp.Clipchamp'))
        ,@('Cortana',                   'ms',    $true,  @('Microsoft.549981C3F5F10'))
        ,@('Copilot app',               'ms',    $true,  @('Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider'))
        ,@('Feedback Hub',              'ms',    $true,  @('Microsoft.WindowsFeedbackHub'))
        ,@('Get Help',                  'ms',    $true,  @('Microsoft.GetHelp'))
        ,@('Tips / Get Started',        'ms',    $true,  @('Microsoft.Getstarted'))
        ,@('Maps',                      'ms',    $true,  @('Microsoft.WindowsMaps'))
        ,@('News',                      'ms',    $true,  @('Microsoft.BingNews'))
        ,@('Weather',                   'ms',    $true,  @('Microsoft.BingWeather'))
        ,@('Bing Search',               'ms',    $true,  @('Microsoft.BingSearch'))
        ,@('Bing Finance / Sports / Travel / Food', 'ms', $true, @('Microsoft.BingFinance', 'Microsoft.BingSports', 'Microsoft.BingTranslator', 'Microsoft.BingTravel', 'Microsoft.BingFoodAndDrink', 'Microsoft.BingHealthAndFitness'))
        ,@('Solitaire Collection',      'ms',    $true,  @('Microsoft.MicrosoftSolitaireCollection'))
        ,@('Microsoft 365 hub',         'ms',    $true,  @('Microsoft.MicrosoftOfficeHub'))
        ,@('OneNote (Store)',           'ms',    $true,  @('Microsoft.Office.OneNote'))
        ,@('Sway',                      'ms',    $true,  @('Microsoft.Office.Sway'))
        ,@('Skype',                     'ms',    $true,  @('Microsoft.SkypeApp'))
        ,@('Teams (consumer)',          'ms',    $true,  @('MicrosoftTeams', 'MSTeams'))
        ,@('People',                    'ms',    $true,  @('Microsoft.People'))
        ,@('Mail and Calendar',         'ms',    $true,  @('microsoft.windowscommunicationsapps'))
        ,@('New Outlook',               'ms',    $true,  @('Microsoft.OutlookForWindows'))
        ,@('Phone Link',                'ms',    $true,  @('Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice'))
        ,@('Power Automate',            'ms',    $true,  @('Microsoft.PowerAutomateDesktop'))
        ,@('Microsoft To Do',           'ms',    $true,  @('Microsoft.Todos'))
        ,@('Whiteboard',                'ms',    $true,  @('Microsoft.Whiteboard'))
        ,@('Journal',                   'ms',    $true,  @('Microsoft.MicrosoftJournal'))
        ,@('Wallet',                    'ms',    $true,  @('Microsoft.Wallet'))
        ,@('Movies and TV',             'ms',    $true,  @('Microsoft.ZuneVideo'))
        ,@('Microsoft Family',          'ms',    $true,  @('MicrosoftCorporationII.MicrosoftFamily'))
        ,@('Dev Home',                  'ms',    $true,  @('Microsoft.Windows.DevHome'))
        ,@('Messaging / OneConnect',    'ms',    $true,  @('Microsoft.Messaging', 'Microsoft.OneConnect'))
        ,@('Power BI',                  'ms',    $true,  @('Microsoft.MicrosoftPowerBIForWindows'))
        ,@('Network Speed Test',        'ms',    $true,  @('Microsoft.NetworkSpeedTest'))
        ,@('Edge Game Assist',          'ms',    $true,  @('Microsoft.Edge.GameAssist'))
        # Preinstalled third-party promos
        ,@('Spotify',                   'promo', $true,  @('SpotifyAB.SpotifyMusic'))
        ,@('Disney+',                   'promo', $true,  @('Disney.37853FC22B2CE'))
        ,@('Netflix',                   'promo', $true,  @('4DF9E0F8.Netflix'))
        ,@('Prime Video',               'promo', $true,  @('AmazonVideo.PrimeVideo'))
        ,@('Hulu',                      'promo', $true,  @('HULULLC.HULUPLUS'))
        ,@('TikTok',                    'promo', $true,  @('BytedancePte.Ltd.TikTok'))
        ,@('Instagram',                 'promo', $true,  @('Facebook.InstagramBeta'))
        ,@('Facebook',                  'promo', $true,  @('Facebook.Facebook'))
        ,@('Twitter / X',               'promo', $true,  @('9E2F88E3.Twitter'))
        ,@('LinkedIn',                  'promo', $true,  @('7EE7776C.LinkedInforWindows'))
        ,@('Candy Crush and King games','promo', $true,  @('king.com.*'))
        ,@('Duolingo',                  'promo', $true,  @('*Duolingo*'))
        ,@('Adobe Express / Photoshop Express', 'promo', $true, @('*AdobeExpress*', 'AdobeSystemsIncorporated.AdobePhotoshopExpress'))
        ,@('Pandora / iHeartRadio / Shazam', 'promo', $true, @('*Pandora*', '*iHeartRadio*', '*Shazam*'))
        ,@('PicsArt / Flipboard / Viber', 'promo', $true, @('*PicsArt*', '*Flipboard*', '*Viber*'))
        ,@('Gameloft and mobile games', 'promo', $true,  @('*GameloftSA*', '*Asphalt8*', '*MarchofEmpires*', '*RoyalRevolt*', '*HiddenCity*', '*CookingFever*', '*FarmVille*', '*BubbleWitch*'))
        ,@('Eclipse Manager / Actipro / SketchBook', 'promo', $true, @('*EclipseManager*', '*ActiproSoftwareLLC*', '*AutodeskSketchBook*'))
        ,@('McAfee (Store trial)',      'promo', $true,  @('*McAfee*'))
        # Xbox and gaming (needed for Game Pass, Minecraft launcher sign-in, etc.)
        ,@('Xbox app',                  'xbox',  $false, @('Microsoft.GamingApp', 'Microsoft.XboxApp'))
        ,@('Xbox Game Bar overlays',    'xbox',  $false, @('Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxSpeechToTextOverlay'))
        ,@('Xbox identity + Gaming Services', 'xbox', $false, @('Microsoft.XboxIdentityProvider', 'Microsoft.GamingServices', 'Microsoft.Xbox.TCUI'))
        ,@('Minecraft Launcher (Store)', 'xbox', $false, @('Microsoft.MinecraftUWP', 'Microsoft.4297127D64EC6'))
        # Other optional
        ,@('Media Player',              'opt',   $false, @('Microsoft.ZuneMusic'))
        ,@('Sticky Notes',              'opt',   $false, @('Microsoft.MicrosoftStickyNotes'))
        ,@('Alarms and Clock',          'opt',   $false, @('Microsoft.WindowsAlarms'))
        ,@('Camera',                    'opt',   $false, @('Microsoft.WindowsCamera'))
        ,@('Sound Recorder',            'opt',   $false, @('Microsoft.WindowsSoundRecorder'))
        ,@('Quick Assist',              'opt',   $false, @('MicrosoftCorporationII.QuickAssist'))
        ,@('Remote Desktop (Store)',    'opt',   $false, @('Microsoft.RemoteDesktop'))
        ,@('Dolby Access',              'opt',   $false, @('DolbyLaboratories.DolbyAccess'))
        ,@('Widgets provider',          'opt',   $false, @('MicrosoftWindows.Client.WebExperience'))
    )
    $out = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($r in $rows) {
        $i++
        [void]$out.Add(@{ Id = ('d{0:D3}' -f $i); Name = $r[0]; Cat = $r[1]; Safe = $r[2]; Patterns = @($r[3]) })
    }
    [void]$out.Add(@{ Id = 'donedrive'; Name = 'OneDrive (uninstall the program)'; Cat = 'opt'; Safe = $false; Patterns = @(); Special = 'onedrive' })
    return $out.ToArray()
}

$script:DebloatCats = [ordered]@{
    ms    = 'Приложения Microsoft, которыми почти никто не пользуется'
    promo = 'Предустановленная реклама и пробные приложения'
    xbox  = 'Xbox и игровые службы (нужны для Game Pass)'
    opt   = 'Другие необязательные приложения'
}

# Self-contained (runs in a background runspace). Returns installed package names.
$script:DebloatScan = {
    $names = New-Object System.Collections.Generic.List[string]
    try { foreach ($p in (Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) { if (-not $p.NonRemovable -and -not $p.IsFramework) { $names.Add([string]$p.Name) } } } catch { }
    try { foreach ($p in (Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) { $names.Add([string]$p.DisplayName) } } catch { }
    $od = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($od) { $names.Add('__onedrive__') }
    ,($names | Sort-Object -Unique)
}

$script:DebloatWork = {
    param($Items)
    $all  = @(); $prov = @()
    try { $all  = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue) } catch { }
    try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) } catch { }
    foreach ($it in $Items) {
        $Q.Enqueue(@{ Kind = 'start'; Id = $it.Id })
        $removed = 0; $err = $null
        try {
            if ($it.Special -eq 'onedrive') {
                Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                $exe = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if ($exe) { Start-Process -FilePath $exe -ArgumentList '/uninstall' -Wait -WindowStyle Hidden; $removed++ }
            } else {
                foreach ($pat in $it.Patterns) {
                    foreach ($p in @($all | Where-Object { $_.Name -like $pat -and -not $_.NonRemovable -and -not $_.IsFramework })) {
                        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; $removed++ }
                        catch { try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; $removed++ } catch { $err = $_.Exception.Message } }
                    }
                    foreach ($pp in @($prov | Where-Object { $_.DisplayName -like $pat })) {
                        try { [void](Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop) } catch { }
                    }
                }
            }
        } catch { $err = $_.Exception.Message }
        $Q.Enqueue(@{ Kind = 'done'; Id = $it.Id; Removed = $removed; Err = $err })
    }
}

# ---- startup manager -------------------------------------------------------------
$script:StartupKeep = 'SecurityHealth|Windows Defender|Realtek|RtkAud|Audio|NVIDIA|NvBackend|Intel.*Graphics|IgfxTray|AMD|RadeonSoftware|Synaptics|Touchpad|Bluetooth|OneDrive'

function Get-StartupEnabled {
    param([string]$Key, [string]$Name)
    $v = Get-RegValue $Key $Name $null
    # Get-RegValue's return unrolls byte[] into object[], so test for any array
    if ($v -is [System.Array] -and $v.Count -gt 0) { return (([int]$v[0] -band 1) -eq 0) }
    return $true
}

function Set-StartupEnabled {
    param([string]$Key, [string]$Name, [bool]$On)
    if ($On) { $b = [byte[]]@(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
    else     { $b = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc())) }
    Set-Reg $Key $Name $b 'Binary'
}

function Get-StartupItems {
    $items = New-Object System.Collections.ArrayList
    $appr = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $defs = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; App = "HKCU:\$appr\Run"; Scope = 'Ваша учётная запись' }
        @{ Run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; App = "HKLM:\$appr\Run"; Scope = 'Все пользователи' }
        @{ Run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; App = "HKLM:\$appr\Run32"; Scope = 'Все пользователи (32-бит)' }
    )
    foreach ($d in $defs) {
        try {
            $k = Get-Item -LiteralPath $d.Run -ErrorAction Stop
            foreach ($n in $k.GetValueNames()) {
                if (-not $n) { continue }
                [void]$items.Add([pscustomobject]@{ Name = $n; Command = [string]$k.GetValue($n); Scope = $d.Scope; Key = $d.App; Enabled = (Get-StartupEnabled $d.App $n) })
            }
        } catch { }
    }
    $folders = @(
        @{ Dir = [Environment]::GetFolderPath('Startup');       App = "HKCU:\$appr\StartupFolder"; Scope = 'Папка автозапуска' }
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); App = "HKLM:\$appr\StartupFolder"; Scope = 'Папка автозапуска (все)' }
    )
    foreach ($f in $folders) {
        try {
            if (-not $f.Dir -or -not (Test-Path -LiteralPath $f.Dir)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $f.Dir -File -ErrorAction Stop | Where-Object { $_.Name -ne 'desktop.ini' })) {
                [void]$items.Add([pscustomobject]@{ Name = $file.Name; Command = $file.FullName; Scope = $f.Scope; Key = $f.App; Enabled = (Get-StartupEnabled $f.App $file.Name) })
            }
        } catch { }
    }
    return @($items | Sort-Object Name)
}
# ---- internet engine ---------------------------------------------------------------
# Uses Windows' supported NetTCPIP / NetAdapter cmdlets (locale independent), never raw registry hacks.
# The user's real baseline is captured before the first change and restored from, not guessed.
$script:NetBaselineFile = Join-Path $script:AppDir 'network-baseline.json'

function Get-NetPrimary {
    try {
        $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
        if (-not $r) { return $null }
        $ad  = Get-NetAdapter -InterfaceIndex $r.ifIndex -ErrorAction Stop
        $ip  = Get-NetIPAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $dns = @((Get-DnsClientServerAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        $ifc = Get-NetIPInterface -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $type = [string]$ad.PhysicalMediaType
        if ($type -match '802\.11|Wireless|Wi-?Fi') { $type = 'Wi-Fi' } elseif ($type -match '802\.3') { $type = 'Ethernet' } elseif (-not $type) { $type = [string]$ad.MediaType }
        return [pscustomobject]@{
            Name = $ad.Name; Desc = $ad.InterfaceDescription; Speed = [string]$ad.LinkSpeed; Type = $type
            Ip = $(if ($ip) { $ip.IPAddress } else { '' }); Gateway = [string]$r.NextHop; Dns = $dns
            Mtu = $(if ($ifc) { [int]$ifc.NlMtu } else { 0 }); Index = [int]$r.ifIndex
        }
    } catch { return $null }
}

function Get-TcpState {
    $t = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
    $o = Get-NetOffloadGlobalSetting -ErrorAction Stop
    return @{
        AutoTuning = [string]$t.AutoTuningLevelLocal; Heuristics = [string]$t.ScalingHeuristics
        Ecn = [string]$t.EcnCapability; Timestamps = [string]$t.Timestamps
        Rss = [string]$o.ReceiveSideScaling; Rsc = [string]$o.ReceiveSegmentCoalescing
    }
}

function Set-TcpState {
    param($S)
    Set-NetTCPSetting -SettingName Internet -AutoTuningLevelLocal $S.AutoTuning -ScalingHeuristics $S.Heuristics -EcnCapability $S.Ecn -Timestamps $S.Timestamps -ErrorAction Stop
    Set-NetOffloadGlobalSetting -ReceiveSideScaling $S.Rss -ReceiveSegmentCoalescing $S.Rsc -ErrorAction Stop
}

# Background-worker wrappers: the NetTCPIP cmdlets can take seconds, so they never run on the UI thread.
function Get-TcpStateBg   { $x = @(Invoke-Blocking -Functions 'Get-TcpState' -Script { Get-TcpState })[0]; if ($x -is [System.Management.Automation.PSObject]) { $x = $x.BaseObject }; return $x }
function Set-TcpStateBg   { param($S) [void](Invoke-Blocking -Functions 'Set-TcpState' -ArgList @(,$S) -Script { param($s) Set-TcpState $s }) }
function Get-NetPrimaryBg { return @(Invoke-Blocking -Functions 'Get-NetPrimary' -Script { Get-NetPrimary })[0] }

function Save-NetBaseline {
    if (Test-Path -LiteralPath $script:NetBaselineFile) { return }
    $state = Get-TcpStateBg
    Write-TextFile $script:NetBaselineFile (ConvertTo-Json -InputObject @{ At = (Get-Date).ToString('s'); State = $state } -Depth 4)
}

function Get-NetBaseline {
    if (-not (Test-Path -LiteralPath $script:NetBaselineFile)) { return $null }
    try { $h = ConvertTo-Plain (ConvertFrom-Json (Get-Content -LiteralPath $script:NetBaselineFile -Raw)); return $h.State } catch { return $null }
}

function Get-TcpTarget {
    param([string]$Profile, $Base, $Cur)
    $b = if ($Base) { $Base } else { $Cur }
    switch ($Profile) {
        'default'    { return $b }
        'gaming'     { return @{ AutoTuning = 'Normal'; Heuristics = 'Disabled'; Ecn = 'Disabled'; Timestamps = 'Disabled'; Rss = 'Enabled'; Rsc = $b.Rsc } }
        'throughput' { return @{ AutoTuning = 'Normal'; Heuristics = 'Disabled'; Ecn = 'Disabled'; Timestamps = 'Disabled'; Rss = 'Enabled'; Rsc = 'Enabled' } }
    }
    return $b
}

function Compare-TcpState {
    param($From, $To)
    $diff = @()
    foreach ($k in 'AutoTuning', 'Heuristics', 'Ecn', 'Timestamps', 'Rss', 'Rsc') {
        if ("$($From[$k])" -ne "$($To[$k])") { $diff += ("{0}: {1} -> {2}" -f $k, $From[$k], $To[$k]) }
    }
    return $diff
}

function Test-PingStats {
    param([string]$Target, [int]$Count = 10, [int]$Timeout = 1000, [switch]$Pump)
    $res = @{ Sent = $Count; Lost = 0; Avg = 0.0; Min = 0.0; Max = 0.0; Jitter = 0.0 }
    if (-not $Target) { $res.Lost = $Count; return $res }
    $p = New-Object System.Net.NetworkInformation.Ping
    $times = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $task = $p.SendPingAsync($Target, $Timeout)
            while (-not $task.IsCompleted) { Invoke-UiPump; Start-Sleep -Milliseconds 8 }
            $r = $task.Result
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $times.Add([double]$r.RoundtripTime) } else { $res.Lost++ }
        } catch { $res.Lost++ }
        Wait-Ui 70
    }
    if ($times.Count -gt 0) {
        $res.Avg = [math]::Round(($times | Measure-Object -Average).Average, 1)
        $res.Min = ($times | Measure-Object -Minimum).Minimum
        $res.Max = ($times | Measure-Object -Maximum).Maximum
        if ($times.Count -gt 1) {
            $sum = 0.0
            for ($i = 1; $i -lt $times.Count; $i++) { $sum += [math]::Abs($times[$i] - $times[$i - 1]) }
            $res.Jitter = [math]::Round($sum / ($times.Count - 1), 1)
        }
    }
    return $res
}

function Find-PathMtu {
    # Largest unfragmented ICMP payload via binary search, plus 28 bytes of headers.
    param([string]$Target = '1.1.1.1', [switch]$Pump)
    $p = New-Object System.Net.NetworkInformation.Ping
    $opt = New-Object System.Net.NetworkInformation.PingOptions
    $opt.DontFragment = $true
    $try = {
        param([int]$size)
        $buf = New-Object byte[] $size
        try {
            $task = $p.SendPingAsync($Target, 1500, $buf, $opt)
            while (-not $task.IsCompleted) { Invoke-UiPump; Start-Sleep -Milliseconds 8 }
            return ($task.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
        } catch { return $false }
    }
    if (-not (& $try 32)) { return $null }
    if (& $try 1472) { return 1500 }
    $lo = 32; $hi = 1472
    while ($lo -lt $hi) {
        $mid = [int][math]::Ceiling(($lo + $hi) / 2)
        if (& $try $mid) { $lo = $mid } else { $hi = $mid - 1 }
        if ($Pump) { Invoke-UiPump }
    }
    return ($lo + 28)
}

function Test-DnsServers {
    param([string[]]$Servers, [switch]$Pump)
    $names = @('www.google.com', 'store.steampowered.com', 'www.cloudflare.com')
    $out = @()
    foreach ($s in ($Servers | Where-Object { $_ } | Select-Object -Unique)) {
        $ms = New-Object System.Collections.Generic.List[double]; $fail = 0
        foreach ($n in $names) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try { [void](Resolve-DnsName -Name $n -Server $s -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop); $ms.Add($sw.Elapsed.TotalMilliseconds) } catch { $fail++ }
            if ($Pump) { Invoke-UiPump }
        }
        $avg = if ($ms.Count -gt 0) { [math]::Round(($ms | Measure-Object -Average).Average, 1) } else { -1 }
        $out += [pscustomobject]@{ Server = $s; Avg = $avg; Failed = $fail }
    }
    return $out
}

function Invoke-TcpProfile {
    param([string]$Profile, [bool]$Rollback = $true, [switch]$Pump)
    Save-NetBaseline
    $base = Get-NetBaseline
    $cur  = Get-TcpStateBg
    $target = Get-TcpTarget $Profile $base $cur
    $diff = @(Compare-TcpState $cur $target)
    $result = @{ Changes = $diff; RolledBack = $false; Pre = $null; Post = $null }
    if ($diff.Count -eq 0) { return $result }
    $info = Get-NetPrimaryBg
    $result.Pre = Test-PingStats '1.1.1.1' 6 1000 -Pump:$Pump
    Set-TcpStateBg $target
    Wait-Ui 800
    $result.Post = Test-PingStats '1.1.1.1' 6 1000 -Pump:$Pump
    if ($Rollback) {
        $pre = $result.Pre; $post = $result.Post
        $broke = ($post.Lost -ge $post.Sent) -and ($pre.Lost -lt $pre.Sent)
        $lossier = ($post.Lost -gt ($pre.Lost + 1))
        $slower = ($pre.Avg -gt 0 -and $post.Avg -gt (($pre.Avg * 1.5) + 5))
        if ($broke -or $lossier -or $slower) { Set-TcpStateBg $cur; $result.RolledBack = $true }
    }
    return $result
}

# ---- profiles and full revert ---------------------------------------------------------
function Export-OptProfile {
    param([string]$Path)
    $F = $script:Facts
    $applied = @()
    foreach ($id in $script:Cards.Keys) { if ($script:Cards[$id].Applied) { $applied += $id } }
    $tcp = $null; try { $tcp = Get-TcpStateBg } catch { }
    $obj = @{
        Format = 1; App = 'OTC OPTI'; Version = $script:Version; Exported = (Get-Date).ToString('s')
        Windows = $F.OsName; Build = $F.Build; Cpu = $F.CpuName; RamGB = $F.RamGB
        Applied = $applied; Tcp = $tcp; NetBaseline = (Get-NetBaseline); Journal = $script:Journal
    }
    Write-TextFile $Path (ConvertTo-Json -InputObject $obj -Depth 10)
}

function Import-OptProfile {
    param([string]$Path)
    $j = ConvertFrom-Json (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    if ($j.App -notin 'OTC OPTI', 'Daqueece Opti', 'Rom-Opti', 'Daqueece Optimizer') { throw 'That file is not a OTC OPTI profile.' }
    return @($j.Applied)
}
# ---- UI definition (XAML) -----------------------------------------------------
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OTC OPTI" Width="1140" Height="740"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanMinimize" FontFamily="Segoe UI"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg0" Color="#070914"/>
    <SolidColorBrush x:Key="Bg1" Color="#0C0F1F"/>
    <SolidColorBrush x:Key="Bg2" Color="#121629"/>
    <SolidColorBrush x:Key="Bg3" Color="#191E36"/>
    <SolidColorBrush x:Key="CardBg" Color="#DC121629"/>
    <SolidColorBrush x:Key="Line" Color="#242A47"/>
    <SolidColorBrush x:Key="Text" Color="#F4F4F4"/>
    <SolidColorBrush x:Key="Muted" Color="#98A2C3"/>
    <SolidColorBrush x:Key="Dim" Color="#5F6A8E"/>
    <SolidColorBrush x:Key="Accent" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="AccentHi" Color="#E6E6E6"/>
    <SolidColorBrush x:Key="Good" Color="#2ED3A0"/>
    <SolidColorBrush x:Key="Warn" Color="#FFB547"/>
    <SolidColorBrush x:Key="Bad" Color="#FF5C7A"/>

    <!-- sidebar navigation -->
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="10,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" CornerRadius="8" Background="Transparent" Padding="12,8">
              <Grid>
                <Rectangle x:Name="bar" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Fill="{StaticResource Accent}" HorizontalAlignment="Left" Margin="-12,0,0,0" Visibility="Collapsed"/>
                <ContentPresenter VerticalAlignment="Center"><ContentPresenter.RenderTransform><TranslateTransform x:Name="nt" X="0"/></ContentPresenter.RenderTransform></ContentPresenter>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Bg2}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
                <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="nt" Storyboard.TargetProperty="X" To="5" Duration="0:0:0.14"><DoubleAnimation.EasingFunction><QuadraticEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation></Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="nt" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.18"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="Transparent"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- buttons -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource Bg3}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform><ScaleTransform x:Name="bs" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="Opacity" To="0.82" Duration="0:0:0.12"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.18"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="bs" Storyboard.TargetProperty="ScaleX" To="0.965" Duration="0:0:0.07"/>
                  <DoubleAnimation Storyboard.TargetName="bs" Storyboard.TargetProperty="ScaleY" To="0.965" Duration="0:0:0.07"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="bs" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="bs" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="#0C0A1A"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="{StaticResource Bad}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#4A2338"/>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Width" Value="38"/><Setter Property="Height" Value="38"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Focusable" Value="False"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="19" Background="{DynamicResource Bg3}" BorderBrush="{DynamicResource Line}" BorderThickness="1" RenderTransformOrigin="0.5,0.5">
            <Border.RenderTransform><ScaleTransform x:Name="sc" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/>
              <Setter TargetName="b" Property="Background" Value="{DynamicResource Bg2}"/>
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1.12" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1.12" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="AccountBtn" TargetType="Button">
      <Setter Property="Height" Value="38"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Focusable" Value="False"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="19" Background="{DynamicResource Bg3}" BorderBrush="{DynamicResource Line}" BorderThickness="1" Padding="4,3,14,3" RenderTransformOrigin="0.5,0.5">
            <Border.RenderTransform><ScaleTransform x:Name="sc" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
            <ContentPresenter VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/>
              <Setter TargetName="b" Property="Background" Value="{DynamicResource Bg2}"/>
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1.05" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1.05" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="GoldBtn" TargetType="Button">
      <Setter Property="Height" Value="38"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Focusable" Value="False"/>
      <Setter Property="FontSize" Value="12.5"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="Foreground" Value="#2A1D00"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="19" Padding="16,0" RenderTransformOrigin="0.5,0.5">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#FDE68A" Offset="0"/><GradientStop Color="#F5B83D" Offset="0.55"/><GradientStop Color="#D98E04" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <Border.Effect><DropShadowEffect x:Name="gl" Color="#FBBF24" BlurRadius="16" ShadowDepth="0" Opacity="0.3"/></Border.Effect>
            <Border.RenderTransform><ScaleTransform x:Name="sc" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <EventTrigger RoutedEvent="FrameworkElement.Loaded">
              <BeginStoryboard><Storyboard RepeatBehavior="Forever" AutoReverse="True">
                <DoubleAnimation Storyboard.TargetName="gl" Storyboard.TargetProperty="Opacity" From="0.22" To="0.75" Duration="0:0:1.3"/>
              </Storyboard></BeginStoryboard>
            </EventTrigger>
            <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1.07" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1.07" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.8"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Width" Value="38"/><Setter Property="Height" Value="30"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource Bg3}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- the big landing-page button -->
    <Style x:Key="Enter" TargetType="Button">
      <Setter Property="Foreground" Value="#0D0A1F"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="30" Padding="46,17" RenderTransformOrigin="0.5,0.5">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#D2D2D2" Offset="0"/>
                  <GradientStop x:Name="hlStop" Color="#FFFFFF" Offset="0"/>
                  <GradientStop Color="#8F8F8F" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <Border.Effect><DropShadowEffect Color="#FFFFFF" BlurRadius="10" Opacity="0.30" ShadowDepth="0"/></Border.Effect>
              <Border.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Border.RenderTransform>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Effect">
                  <Setter.Value><DropShadowEffect Color="#E6E6E6" BlurRadius="14" Opacity="0.42" ShadowDepth="0"/></Setter.Value>
                </Setter>
                <Setter TargetName="bd" Property="RenderTransform">
                  <Setter.Value><ScaleTransform ScaleX="1.035" ScaleY="1.035"/></Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="RenderTransform">
                  <Setter.Value><ScaleTransform ScaleX="0.98" ScaleY="0.98"/></Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- toggle switch (tweaks, session options) -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="track" Width="38" Height="21" CornerRadius="10.5" VerticalAlignment="Center">
                <Border.Background><SolidColorBrush Color="#2C3354"/></Border.Background>
                <Ellipse x:Name="knob" Width="15" Height="15" Fill="#CBD3EE" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="knob" Property="Fill" Value="#0C0A1A"/>
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <ThicknessAnimation Storyboard.TargetName="knob" Storyboard.TargetProperty="Margin" To="20,0,0,0" Duration="0:0:0.18"><ThicknessAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.35"/></ThicknessAnimation.EasingFunction></ThicknessAnimation>
                  <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="Background.Color" To="#FFFFFF" Duration="0:0:0.18"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <ThicknessAnimation Storyboard.TargetName="knob" Storyboard.TargetProperty="Margin" To="3,0,0,0" Duration="0:0:0.16"/>
                  <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="Background.Color" To="#2C3354" Duration="0:0:0.16"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,5,16,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="#394167" Background="#0E1224" VerticalAlignment="Center">
                <Path x:Name="tick" Data="M 4,9.5 L 7.5,13 L 14,5" Stroke="#0C0A1A" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="FilterChip" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" CornerRadius="14" Background="{StaticResource Bg2}" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="13,5">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="#0C0A1A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Bg1}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="10,6">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18"/>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="{StaticResource Bg3}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="MaxWidth" Value="360"/>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="#1B2140"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border Background="{TemplateBinding Background}" CornerRadius="4">
              <Grid ClipToBounds="True">
                <Border x:Name="PART_Track"/>
                <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="4" Background="{TemplateBinding Foreground}"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="tb" Background="#2A3050" CornerRadius="4" Margin="1"/>
                        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="tb" Property="Background" Value="#3E4870"/></Trigger></ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ColorSliderDecrease" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Height" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border CornerRadius="3">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                  <GradientStop Color="#28DDF5" Offset="0"/>
                  <GradientStop Color="#6685FF" Offset="0.58"/>
                  <GradientStop Color="#B65BFF" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ColorSliderIncrease" TargetType="RepeatButton" BasedOn="{StaticResource ColorSliderDecrease}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ColorSliderThumb" TargetType="Thumb">
      <Setter Property="Width" Value="20"/>
      <Setter Property="Height" Value="20"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="thumb" CornerRadius="10" Background="#11192B" BorderBrush="#B9F7FF" BorderThickness="2"
                    RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform><ScaleTransform x:Name="thumbScale" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
              <Border.Effect><DropShadowEffect Color="#42DFF5" BlurRadius="10" ShadowDepth="0" Opacity="0.55"/></Border.Effect>
              <Ellipse Width="6" Height="6" Fill="#E8FCFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="thumbScale" Storyboard.TargetProperty="ScaleX" To="1.16" Duration="0:0:0.12"/>
                  <DoubleAnimation Storyboard.TargetName="thumbScale" Storyboard.TargetProperty="ScaleY" To="1.16" Duration="0:0:0.12"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="thumbScale" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.16"/>
                  <DoubleAnimation Storyboard.TargetName="thumbScale" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.16"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsDragging" Value="True">
                <Setter TargetName="thumb" Property="BorderBrush" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="thumb" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ColorSlider" TargetType="Slider">
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Height="30" Background="Transparent">
              <Border Height="6" VerticalAlignment="Center" CornerRadius="3" Background="#252B43"/>
              <Track x:Name="PART_Track" VerticalAlignment="Center" IsDirectionReversed="{TemplateBinding IsDirectionReversed}">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Style="{StaticResource ColorSliderDecrease}" Command="{x:Static Slider.DecreaseLarge}"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Style="{StaticResource ColorSliderIncrease}" Command="{x:Static Slider.IncreaseLarge}"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource ColorSliderThumb}"/></Track.Thumb>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="frame" Background="{StaticResource Bg0}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14">
    <Grid>

      <!-- ===================== LANDING ===================== -->
      <Grid x:Name="landing" Background="Transparent">
        <Border CornerRadius="14">
          <Border.Background>
            <RadialGradientBrush x:Name="bgGrad" Center="0.5,0.46" GradientOrigin="0.5,0.46" RadiusX="0.62" RadiusY="0.62">
              <GradientStop Color="#1FFFFFFF" Offset="0"/>
              <GradientStop Color="#0AFFFFFF" Offset="0.45"/>
              <GradientStop Color="#00000000" Offset="1"/>
            </RadialGradientBrush>
          </Border.Background>
        </Border>
        <Canvas x:Name="bokeh" IsHitTestVisible="False" ClipToBounds="True"><Canvas.RenderTransform><TranslateTransform x:Name="parBokeh" X="0" Y="0"/></Canvas.RenderTransform></Canvas>
        <Canvas x:Name="particles" IsHitTestVisible="False" ClipToBounds="True"><Canvas.RenderTransform><TranslateTransform x:Name="parPart" X="0" Y="0"/></Canvas.RenderTransform></Canvas>
        <Rectangle x:Name="scanLine" Width="2" IsHitTestVisible="False" HorizontalAlignment="Left" Opacity="0"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#00FFFFFF" Offset="0"/><GradientStop Color="#99FFFFFF" Offset="0.5"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Rectangle.Fill><Rectangle.RenderTransform><TranslateTransform x:Name="scanT" X="-10"/></Rectangle.RenderTransform></Rectangle>
        <Ellipse x:Name="glow" Width="560" Height="560" IsHitTestVisible="False" Opacity="0.55" Margin="0,0,0,40" RenderTransformOrigin="0.5,0.5">
          <Ellipse.RenderTransform><ScaleTransform x:Name="glowScale" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
          <Ellipse.Fill>
            <RadialGradientBrush>
              <GradientStop Color="#2CFFFFFF" Offset="0"/>
              <GradientStop Color="#00FFFFFF" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
        </Ellipse>

        <StackPanel x:Name="lnChrome" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,10,10,0" Opacity="0">
          <Button x:Name="lnMin" Style="{StaticResource Chrome}" Content="&#xE921;"/>
          <Button x:Name="lnClose" Style="{StaticResource Chrome}" Content="&#xE8BB;"/>
        </StackPanel>

        <StackPanel x:Name="hero" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-10,0,0">
          <Grid x:Name="logoWrap" Width="96" Height="96" HorizontalAlignment="Center" Opacity="0" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><ScaleTransform x:Name="logoScale" ScaleX="0.5" ScaleY="0.5"/></Grid.RenderTransform>
            <Ellipse x:Name="pulseA" Width="96" Height="96" Stroke="#66FFFFFF" StrokeThickness="1" Opacity="0" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><ScaleTransform x:Name="pulseAS" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform></Ellipse>
            <Ellipse x:Name="pulseB" Width="96" Height="96" Stroke="#44FFFFFF" StrokeThickness="1" Opacity="0" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><ScaleTransform x:Name="pulseBS" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform></Ellipse>
            <Ellipse x:Name="ring2" Width="124" Height="124" Stroke="#33FFFFFF" StrokeThickness="1" StrokeDashArray="1 6" RenderTransformOrigin="0.5,0.5">
              <Ellipse.RenderTransform><RotateTransform x:Name="ring2Rot" Angle="0"/></Ellipse.RenderTransform>
            </Ellipse>
            <Grid x:Name="orbit1" Width="114" Height="114" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><RotateTransform x:Name="orbit1Rot" Angle="0"/></Grid.RenderTransform>
              <Ellipse Width="5" Height="5" Fill="{StaticResource AccentHi}" HorizontalAlignment="Center" VerticalAlignment="Top"/>
            </Grid>
            <Grid x:Name="orbit2" Width="136" Height="136" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><RotateTransform x:Name="orbit2Rot" Angle="0"/></Grid.RenderTransform>
              <Ellipse Width="3.5" Height="3.5" Fill="#B8FFFFFF" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <Ellipse x:Name="ring" Width="96" Height="96" Stroke="#66FFFFFF" StrokeThickness="1.4" StrokeDashArray="2.5 5" RenderTransformOrigin="0.5,0.5">
              <Ellipse.RenderTransform><RotateTransform x:Name="ringRot" Angle="0"/></Ellipse.RenderTransform>
            </Ellipse>
            <Border Width="68" Height="68" CornerRadius="18" BorderBrush="#55FFFFFF" BorderThickness="1" Background="#14FFFFFF">
              <Border.Effect><DropShadowEffect x:Name="logoFx" Color="#FFFFFF" BlurRadius="10" Opacity="0.25" ShadowDepth="0"/></Border.Effect>
              <Viewbox Width="30" Height="30">
                <Path x:Name="logoBolt" Data="M 15,1 L 3,17 L 11,17 L 9,29 L 23,11 L 14,11 Z" Fill="{StaticResource Accent}"/>
              </Viewbox>
            </Border>
          </Grid>

          <TextBlock x:Name="lnTag" Opacity="0" Margin="0,26,0,0" HorizontalAlignment="Center" FontSize="11" FontWeight="SemiBold" Foreground="{StaticResource Dim}"/>
          <StackPanel x:Name="lnTitle" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,10,0,0"/>
          <TextBlock x:Name="lnSub" Opacity="0" Margin="0,2,0,0" HorizontalAlignment="Center" FontFamily="Bahnschrift, Segoe UI Semibold" FontSize="22" FontWeight="SemiBold" Foreground="{StaticResource Accent}"/>
          <Rectangle x:Name="lnUnder" Width="0" Height="2" RadiusX="1" RadiusY="1" Fill="{StaticResource Accent}" HorizontalAlignment="Center" Margin="0,10,0,0" Opacity="0.85"/>
          <TextBlock x:Name="lnLine" Opacity="0" Margin="0,16,0,0" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" MaxWidth="500" FontSize="14" LineHeight="22" Foreground="{StaticResource Muted}"
                     Text="Твики Windows, планировщика и видеокарты, удаление лишних приложений и очистка автозапуска. Прирост зависит от железа и часто невелик, а если упор в видеокарту, то и нулевой. Каждое изменение записывается в журнал и обратимо, а у каждого переключателя честно указано, чего он стоит."/>

          <Button x:Name="btnEnter" Opacity="0" Style="{StaticResource Enter}" HorizontalAlignment="Center" Margin="0,36,0,0"/>

          <StackPanel x:Name="lnChips" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,32,0,0">
            <Border x:Name="chipA" Opacity="0" Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14" Padding="12,5" Margin="4,0">
              <TextBlock Text="Полностью обратимо" FontSize="11.5" Foreground="{StaticResource Muted}"/>
            </Border>
            <Border x:Name="chipB" Opacity="0" Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14" Padding="12,5" Margin="4,0">
              <TextBlock Text="Без внедрения в игру" FontSize="11.5" Foreground="{StaticResource Muted}"/>
            </Border>
            <Border x:Name="chipC" Opacity="0" Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14" Padding="12,5" Margin="4,0">
              <TextBlock Text="Честная оценка эффекта" FontSize="11.5" Foreground="{StaticResource Muted}"/>
            </Border>
          </StackPanel>
        </StackPanel>

        <TextBlock x:Name="lnSys" Opacity="0" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,22" FontSize="11.5" Foreground="{StaticResource Dim}"/>
      </Grid>

      <!-- ===================== APP ===================== -->
      <Grid x:Name="app" Visibility="Collapsed" Opacity="0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="238"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- animated topographic background -->
        <Border x:Name="bgWrap" Grid.ColumnSpan="2" ClipToBounds="True" IsHitTestVisible="False">
          <Rectangle x:Name="bgLines" Fill="{DynamicResource Accent}" Opacity="0.17" IsHitTestVisible="False" Margin="-90" RenderTransformOrigin="0.5,0.5">
            <Rectangle.OpacityMask>
              <ImageBrush x:Name="bgMask" Stretch="UniformToFill"/>
            </Rectangle.OpacityMask>
            <Rectangle.RenderTransform>
              <TransformGroup>
                <ScaleTransform x:Name="bgScale" ScaleX="1.12" ScaleY="1.12"/>
                <TranslateTransform x:Name="bgMove" X="0" Y="0"/>
              </TransformGroup>
            </Rectangle.RenderTransform>
          </Rectangle>
        </Border>

        <!-- sidebar -->
        <Border Grid.Column="0" Background="{StaticResource Bg1}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0" CornerRadius="14,0,0,14">
          <DockPanel LastChildFill="True">
            <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="22,24,16,18">
              <Border x:Name="sideLogo" Width="34" Height="34" CornerRadius="10" Background="#18FFFFFF" BorderBrush="#44FFFFFF" BorderThickness="1">
                <Border.Effect><DropShadowEffect x:Name="sideFx" Color="#FFFFFF" BlurRadius="8" Opacity="0.3" ShadowDepth="0"/></Border.Effect>
                <Viewbox Width="16" Height="16"><Path Data="M 15,1 L 3,17 L 11,17 L 9,29 L 23,11 L 14,11 Z" Fill="{StaticResource Accent}"/></Viewbox>
              </Border>
              <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="OTC" FontFamily="Bahnschrift, Segoe UI Semibold" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                <TextBlock Text="OPTI" FontFamily="Bahnschrift, Segoe UI Semibold" FontSize="10.5" Foreground="{StaticResource Accent}"/>
              </StackPanel>
            </StackPanel>

            <StackPanel DockPanel.Dock="Bottom" Margin="14,6,14,16">
              <CheckBox x:Name="swMotion" Style="{StaticResource Switch}" Content="Анимации" IsChecked="True" Foreground="{StaticResource Muted}" FontSize="12" Margin="6,0,0,10"/>
              <Border Padding="12,10" Background="{StaticResource Bg2}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="10">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <Grid Width="7" Height="7" VerticalAlignment="Center">
                      <Ellipse x:Name="sideRing" Width="7" Height="7" Stroke="{StaticResource Good}" StrokeThickness="1" Opacity="0" RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><ScaleTransform x:Name="sideRingS" ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform></Ellipse>
                      <Ellipse x:Name="sideDot" Width="7" Height="7" Fill="{StaticResource Dim}"/>
                    </Grid>
                    <TextBlock x:Name="sideTitle" Text="Нет активной сессии" FontSize="12" FontWeight="SemiBold" Foreground="{StaticResource Text}" Margin="8,0,0,0"/>
                  </StackPanel>
                  <TextBlock x:Name="sideSub" Margin="15,3,0,0" FontSize="11" Foreground="{StaticResource Dim}" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </StackPanel>

            <Grid DockPanel.Dock="Top">
            <Border x:Name="navHi" Background="#191E36" CornerRadius="8" Height="36" VerticalAlignment="Top" Margin="10,0" Visibility="Collapsed">
              <Border.RenderTransform><TranslateTransform x:Name="navHiT" Y="0"/></Border.RenderTransform>
            </Border>
            <StackPanel x:Name="navPanel">
              <RadioButton x:Name="navDash" Style="{StaticResource Nav}" GroupName="N" IsChecked="True">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE80F;"/><TextBlock Text="Главная"/></StackPanel></RadioButton>
              <RadioButton x:Name="navColor" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE7F4;"/><TextBlock Text="Цвета"/></StackPanel></RadioButton>
              <RadioButton x:Name="navOpt" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE945;"/><TextBlock Text="Оптимизация"/></StackPanel></RadioButton>
              <RadioButton x:Name="navInternet" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE774;"/><TextBlock Text="Интернет"/></StackPanel></RadioButton>
              <RadioButton x:Name="navDebloat" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE74D;"/><TextBlock Text="Удаление лишнего"/></StackPanel></RadioButton>
              <RadioButton x:Name="navStartup" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE7E8;"/><TextBlock Text="Автозапуск"/></StackPanel></RadioButton>
              <RadioButton x:Name="navRust" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE7FC;"/><TextBlock Text="Rust"/></StackPanel></RadioButton>
              <RadioButton x:Name="navSession" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE768;"/><TextBlock Text="Игровая сессия"/></StackPanel></RadioButton>
              <RadioButton x:Name="navClean" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE894;"/><TextBlock Text="Очистка диска"/></StackPanel></RadioButton>
              <RadioButton x:Name="navRestore" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE777;"/><TextBlock Text="Восстановление и профили"/></StackPanel></RadioButton>
              <RadioButton x:Name="navSettings" Style="{StaticResource Nav}" GroupName="N" Visibility="Collapsed">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE713;"/><TextBlock Text="Настройки"/></StackPanel></RadioButton>
              <RadioButton x:Name="navLog" Style="{StaticResource Nav}" GroupName="N">
                <StackPanel Orientation="Horizontal"><TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" Text="&#xE8A5;"/><TextBlock Text="Журнал"/></StackPanel></RadioButton>
            </StackPanel>
            </Grid>
          </DockPanel>
        </Border>

        <!-- content -->
        <Grid Grid.Column="1">
          <Grid.RowDefinitions>
            <RowDefinition Height="74"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="36"/>
          </Grid.RowDefinitions>

          <Border x:Name="header" Grid.Row="0" Background="Transparent">
            <DockPanel Margin="30,0,10,0">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top" Margin="0,10,0,0">
                <Button x:Name="appMin" Style="{StaticResource Chrome}" Content="&#xE921;"/>
                <Button x:Name="appClose" Style="{StaticResource Chrome}" Content="&#xE8BB;"/>
              </StackPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top" Margin="0,8,12,0">
                <Button x:Name="btnBuy" Style="{StaticResource GoldBtn}" Margin="0,0,10,0" ToolTip="Купить PLUS или ULTRA в Discord">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE734;" FontSize="13" Margin="0,1,7,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Купить PLUS / ULTRA" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
                <Button x:Name="btnDiscord" Style="{StaticResource IconBtn}" Margin="0,0,8,0" ToolTip="Discord">
                  <Viewbox Width="20" Height="20">
                    <Path Fill="#8E9BFF">
                      <Path.Data>
                        <GeometryGroup FillRule="EvenOdd">
                          <PathGeometry Figures="M3,19 L5,6 Q7,4.5 10,4 L10.8,5.3 Q12,5.1 13.2,5.3 L14,4 Q17,4.5 19,6 L21,19 Q18,21 15.5,21.2 L14.6,19.8 Q12,20.4 9.4,19.8 L8.5,21.2 Q6,21 3,19 Z"/>
                          <EllipseGeometry Center="8.6,12.6" RadiusX="1.7" RadiusY="1.9"/>
                          <EllipseGeometry Center="15.4,12.6" RadiusX="1.7" RadiusY="1.9"/>
                        </GeometryGroup>
                      </Path.Data>
                    </Path>
                  </Viewbox>
                </Button>
                <Button x:Name="btnWeb" Style="{StaticResource IconBtn}" Margin="0,0,10,0" ToolTip="Сайт">
                  <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE774;" FontSize="16" Foreground="#B8BCD8"/>
                </Button>
                <Button x:Name="btnAccount" Style="{StaticResource AccountBtn}" ToolTip="Аккаунт и настройки">
                  <StackPanel Orientation="Horizontal">
                    <Grid Width="30" Height="30">
                      <Ellipse>
                        <Ellipse.Fill>
                          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                            <GradientStop Color="#34D399" Offset="0"/><GradientStop Color="#38BDF8" Offset="1"/>
                          </LinearGradientBrush>
                        </Ellipse.Fill>
                      </Ellipse>
                      <TextBlock x:Name="accInitial" Text="?" FontSize="14" FontWeight="Bold" Foreground="#06121A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Grid>
                    <StackPanel Margin="9,0,0,0" VerticalAlignment="Center">
                      <TextBlock x:Name="accName" FontSize="12.5" FontWeight="SemiBold" Foreground="#F0F1FA" MaxWidth="110" TextTrimming="CharacterEllipsis"/>
                      <TextBlock x:Name="accTier" FontSize="10" Foreground="#8A90B4"/>
                    </StackPanel>
                  </StackPanel>
                </Button>
              </StackPanel>
              <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="pageTitle" FontSize="22" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                <TextBlock x:Name="pageSub" FontSize="12.5" Foreground="{StaticResource Muted}" Margin="0,3,0,0"/>
                <Rectangle x:Name="hdrBar" Width="0" Height="2" RadiusX="1" RadiusY="1" Fill="{StaticResource Accent}" HorizontalAlignment="Left" Margin="0,7,0,0"/>
              </StackPanel>
            </DockPanel>
          </Border>

          <Grid Grid.Row="1" Margin="30,4,30,8">

            <!-- Display color controls -->
            <ScrollViewer x:Name="pgColor" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="0,0,10,12">
                <Border Style="{StaticResource Card}" Margin="0,0,0,14" Padding="16,14">
                  <StackPanel>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="104"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Grid Grid.Column="0" Width="84" Height="84" VerticalAlignment="Center">
                        <Ellipse x:Name="colorRing" Width="78" Height="78" StrokeThickness="4" RenderTransformOrigin="0.5,0.5">
                          <Ellipse.Stroke>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                              <GradientStop Color="#2BE7FF" Offset="0"/>
                              <GradientStop Color="#A855F7" Offset="0.52"/>
                              <GradientStop Color="#FF4FD8" Offset="1"/>
                            </LinearGradientBrush>
                          </Ellipse.Stroke>
                          <Ellipse.RenderTransform><RotateTransform x:Name="colorRingRot" Angle="0"/></Ellipse.RenderTransform>
                          <Ellipse.Effect>
                            <DropShadowEffect x:Name="colorRingFx" Color="#7C4DFF" BlurRadius="22" ShadowDepth="0" Opacity="0.8"/>
                          </Ellipse.Effect>
                        </Ellipse>
                        <Ellipse Width="8" Height="8" Fill="#40E9FF" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,5,5,0">
                          <Ellipse.Effect><DropShadowEffect Color="#40E9FF" BlurRadius="12" ShadowDepth="0" Opacity="0.95"/></Ellipse.Effect>
                        </Ellipse>
                        <TextBlock Text="OTC" FontSize="16" FontWeight="Bold" Foreground="#E8FBFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Grid>
                      <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <TextBlock Text="OTC  /  COLOR STUDIO" FontSize="10.5" FontWeight="Bold" Foreground="#43DFF5"/>
                        <TextBlock Text="Собери свой цветовой стиль" FontSize="18" FontWeight="Bold" Foreground="{StaticResource Text}" Margin="0,4,0,0"/>
                        <TextBlock Text="Сохраняй конфиги и возвращайся к ним в один клик." FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                      </StackPanel>
                    </Grid>
                    <Border x:Name="colorAccentLine" Height="2" Margin="0,13,0,0" HorizontalAlignment="Stretch" Opacity="0.85">
                      <Border.Background>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                          <GradientStop Color="#2BE7FF" Offset="0"/>
                          <GradientStop Color="#9B5CFF" Offset="0.52"/>
                          <GradientStop Color="#FF4FD8" Offset="1"/>
                        </LinearGradientBrush>
                      </Border.Background>
                    </Border>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="ЦВЕТОВОЙ ФИЛЬТР ДИСПЛЕЯ" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                    <TextBlock Margin="0,7,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Настройки меняют весь основной монитор, а не только игру. Используется системная гамма-кривая Windows; полноэкранная игра или драйвер могут переопределить её. Это не GPU-шейдер."/>
                    <TextBlock x:Name="txtColorSupport" Margin="0,8,0,0" FontSize="11" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Исходные цвета восстанавливаются при закрытии приложения."/>
                  </StackPanel>
                </Border>
                <Border x:Name="pnlColorLocked" Style="{StaticResource Card}" Margin="0,0,0,14" Visibility="Collapsed" BorderBrush="#6752A8">
                  <DockPanel LastChildFill="True">
                    <Button x:Name="btnColorPremium" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Активировать PLUS / ULTRA" Margin="14,0,0,0" VerticalAlignment="Center"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="PLUS COLOR STUDIO" FontSize="12" FontWeight="Bold" Foreground="#D8B8FF"/>
                      <TextBlock Text="Фильтр и цветовые конфиги доступны в PLUS и ULTRA. Насыщенность и все оптимизации открывает ULTRA." FontSize="11.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                    </StackPanel>
                  </DockPanel>
                </Border>
                <Border x:Name="pnlColorControls" Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <Grid Margin="0,0,0,2">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Яркость" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                      <Border Grid.Column="1" Background="#152334" BorderBrush="#28556A" BorderThickness="1" CornerRadius="7" Padding="9,3">
                        <TextBlock x:Name="txtColorBrightness" Text="0" FontSize="12" FontWeight="SemiBold" Foreground="#74E9F5"/>
                      </Border>
                    </Grid>
                    <Slider x:Name="slColorBrightness" Style="{StaticResource ColorSlider}" Minimum="-35" Maximum="35" Value="0" Margin="0,2,0,2"/>
                    <TextBlock Text="Изменяет общую яркость изображения." FontSize="11" Foreground="{StaticResource Muted}" Margin="0,0,0,14"/>
                    <Grid Margin="0,0,0,2">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Контраст" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                      <Border Grid.Column="1" Background="#152334" BorderBrush="#28556A" BorderThickness="1" CornerRadius="7" Padding="9,3">
                        <TextBlock x:Name="txtColorContrast" Text="100" FontSize="12" FontWeight="SemiBold" Foreground="#74E9F5"/>
                      </Border>
                    </Grid>
                    <Slider x:Name="slColorContrast" Style="{StaticResource ColorSlider}" Minimum="70" Maximum="135" Value="100" Margin="0,2,0,2"/>
                    <TextBlock Text="Меняет разницу между тёмными и светлыми тонами." FontSize="11" Foreground="{StaticResource Muted}" Margin="0,0,0,14"/>
                    <Grid Margin="0,0,0,2">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Выразительность цвета" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                      <Border Grid.Column="1" Background="#152334" BorderBrush="#28556A" BorderThickness="1" CornerRadius="7" Padding="9,3">
                        <TextBlock x:Name="txtColorSaturation" Text="100" FontSize="12" FontWeight="SemiBold" Foreground="#74E9F5"/>
                      </Border>
                    </Grid>
                    <Slider x:Name="slColorSaturation" Style="{StaticResource ColorSlider}" Minimum="80" Maximum="140" Value="100" Margin="0,2,0,2"/>
                    <Button x:Name="btnColorVivid" Style="{StaticResource Btn}" Content="Выразительные цвета (125%)" HorizontalAlignment="Right" Padding="10,5" Margin="0,2,0,6"/>
                    <TextBlock Text="Плавная S-кривая усиливает средние тона и бережнее сохраняет детали в тенях и светах, чем линейный контраст. Это системная гамма-коррекция, а не настоящая RGB/GPU-насыщенность; эффект действует на основной дисплей." FontSize="11" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,14"/>
                    <Grid Margin="0,0,0,2">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Экспозиция" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                      <Border Grid.Column="1" Background="#152334" BorderBrush="#28556A" BorderThickness="1" CornerRadius="7" Padding="9,3">
                        <TextBlock x:Name="txtColorExposure" Text="0.00 EV" FontSize="12" FontWeight="SemiBold" Foreground="#74E9F5"/>
                      </Border>
                    </Grid>
                    <Slider x:Name="slColorExposure" Style="{StaticResource ColorSlider}" Minimum="-1.5" Maximum="1.5" Value="0" TickFrequency="0.05" Margin="0,2,0,2"/>
                    <TextBlock Text="Общий сдвиг экспозиции в ступенях EV." FontSize="11" Foreground="{StaticResource Muted}" Margin="0,0,0,14"/>
                    <Grid Margin="0,0,0,2">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Гамма" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
                      <Border Grid.Column="1" Background="#152334" BorderBrush="#28556A" BorderThickness="1" CornerRadius="7" Padding="9,3">
                        <TextBlock x:Name="txtColorGamma" Text="1.00" FontSize="12" FontWeight="SemiBold" Foreground="#74E9F5"/>
                      </Border>
                    </Grid>
                    <Slider x:Name="slColorGamma" Style="{StaticResource ColorSlider}" Minimum="0.65" Maximum="1.8" Value="1" TickFrequency="0.01" Margin="0,2,0,2"/>
                    <TextBlock Text="Меняет средние тона цветовой кривой дисплея." FontSize="11" Foreground="{StaticResource Muted}"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,12">
                  <StackPanel>
                    <TextBlock Text="МОИ ЦВЕТОВЫЕ КОНФИГИ" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                    <TextBlock Text="Создай именованный профиль настроек и загружай его позже." FontSize="11.5" Foreground="{StaticResource Muted}" Margin="0,5,0,10"/>
                    <WrapPanel>
                      <Button x:Name="btnColorSaveProfile" Style="{StaticResource BtnPrimary}" Content="Сохранить как конфиг" Margin="0,0,8,8"/>
                      <ComboBox x:Name="cmbColorProfiles" MinWidth="190" Height="34" Margin="0,0,8,8" VerticalContentAlignment="Center" ToolTip="Сохранённые цветовые конфиги"/>
                      <Button x:Name="btnColorLoadProfile" Style="{StaticResource Btn}" Content="Загрузить" Margin="0,0,8,8"/>
                      <Button x:Name="btnColorDeleteProfile" Style="{StaticResource BtnDanger}" Content="Удалить конфиг" Margin="0,0,8,8"/>
                    </WrapPanel>
                    <TextBlock x:Name="txtColorProfileStatus" FontSize="11.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                  <Button x:Name="btnColorApply" Style="{StaticResource BtnPrimary}" Content="Применить к дисплею" Margin="0,0,8,0"/>
                  <Button x:Name="btnColorRestore" Style="{StaticResource Btn}" Content="Восстановить исходные цвета"/>
                </StackPanel>
                <TextBlock x:Name="txtColorStatus" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
              </StackPanel>
            </ScrollViewer>

            <!-- Dashboard -->
            <ScrollViewer x:Name="pgDash" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="0,0,10,12">
                <ProgressBar x:Name="countProxy" Minimum="0" Maximum="1000" Value="0" Visibility="Collapsed" Height="0"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Border x:Name="dCard1" Grid.Column="0" Style="{StaticResource Card}">
                    <StackPanel>
                      <TextBlock Text="ЭТОТ ПК" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="dCpu" Margin="0,10,0,0" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
                      <TextBlock x:Name="dGpu" Margin="0,5,0,0" FontSize="12.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                      <TextBlock x:Name="dRam" Margin="0,5,0,0" FontSize="12.5" Foreground="{StaticResource Muted}"/>
                      <TextBlock x:Name="dOs" Margin="0,5,0,0" FontSize="12.5" Foreground="{StaticResource Muted}"/>
                    </StackPanel>
                  </Border>
                  <Border x:Name="dCard2" Grid.Column="2" Style="{StaticResource Card}">
                    <StackPanel>
                      <TextBlock Text="РЕКОМЕНДУЕМЫЕ ТВИКИ" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                      <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                        <TextBlock x:Name="dApplied" FontSize="34" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                        <TextBlock x:Name="dTotal" FontSize="16" Foreground="{StaticResource Dim}" VerticalAlignment="Bottom" Margin="6,0,0,6"/>
                      </StackPanel>
                      <ProgressBar x:Name="dBar" Minimum="0" Maximum="100" Value="0" Margin="0,8,0,0"/>
                      <TextBlock x:Name="dAppliedNote" Margin="0,9,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    </StackPanel>
                  </Border>
                  <Border x:Name="dCard3" Grid.Column="4" Style="{StaticResource Card}">
                    <StackPanel>
                      <TextBlock Text="RUST" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="dRust" Margin="0,10,0,0" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
                      <TextBlock x:Name="dRustSub" Margin="0,5,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    </StackPanel>
                  </Border>
                </Grid>

                <Border x:Name="dGradeCard" Style="{StaticResource Card}" Margin="0,16,0,0">
                  <DockPanel>
                    <Grid DockPanel.Dock="Left" Width="136" Height="136" Margin="0,0,24,0">
                      <Ellipse Width="120" Height="120" Stroke="#24213B" StrokeThickness="11"/>
                      <Ellipse x:Name="gradeArc" Width="120" Height="120" Stroke="#34D399" StrokeThickness="11" StrokeDashCap="Round" RenderTransformOrigin="0.5,0.5" Visibility="Collapsed">
                        <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
                      </Ellipse>
                      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                        <TextBlock x:Name="gradeLetter" Text="-" FontSize="44" FontWeight="Bold" HorizontalAlignment="Center" Foreground="{StaticResource Text}"/>
                        <TextBlock x:Name="gradeScore" Text="0 / 100" FontSize="12" HorizontalAlignment="Center" Foreground="{StaticResource Muted}"/>
                      </StackPanel>
                    </Grid>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="OTC GRADE" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="gradeTitle" FontSize="17" FontWeight="Bold" Foreground="{StaticResource Text}" Margin="0,6,0,0" TextWrapping="Wrap"/>
                      <TextBlock x:Name="gradeGrowth" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Good}" Margin="0,6,0,0" TextWrapping="Wrap"/>
                      <TextBlock x:Name="gradeNote" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,6,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                  </DockPanel>
                </Border>

                <Border x:Name="dOptCard" Style="{StaticResource Card}" Margin="0,16,0,0">
                  <DockPanel>
                    <Button x:Name="btnOptimizeAll" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Оптимизировать ПК" Padding="26,13" FontSize="14" VerticalAlignment="Center" Margin="16,0,0,0"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="Один клик, только безопасные твики" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                      <TextBlock Margin="0,4,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                        Text="Применяет только безопасные твики, которые поддерживает ваш ПК, сначала создаёт точку восстановления, затем показывает, что именно изменилось. Твики из разделов «Проверить» и «Расширенные» автоматически не применяются."/>
                    </StackPanel>
                  </DockPanel>
                </Border>
                <Border x:Name="dChanges" Style="{StaticResource Card}" Margin="0,12,0,0" Visibility="Collapsed">
                  <StackPanel>
                    <TextBlock x:Name="dChangesTitle" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock x:Name="dChangesSub" Margin="0,4,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    <StackPanel x:Name="pnlChanges" Margin="0,10,0,0"/>
                  </StackPanel>
                </Border>

                <DockPanel Margin="0,26,0,10" LastChildFill="False">
                  <StackPanel DockPanel.Dock="Left">
                    <TextBlock Text="Что на самом деле ограничивает ваш FPS" FontSize="15" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Text="Проверено на этом ПК прямо сейчас. Сначала исправьте оранжевые пункты: они важнее любого твика реестра." FontSize="12" Foreground="{StaticResource Muted}" Margin="0,3,0,0"/>
                  </StackPanel>
                  <Button x:Name="btnRescan" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Пересканировать" VerticalAlignment="Center"/>
                </DockPanel>
                <StackPanel x:Name="pnlFindings"/>

                <Button x:Name="btnGoOpt" Style="{StaticResource BtnPrimary}" Content="Просмотреть рекомендуемые твики" HorizontalAlignment="Left" Margin="0,18,0,0" Padding="22,12"/>
              </StackPanel>
            </ScrollViewer>

            <!-- Optimize -->
            <Grid x:Name="pgOpt" Visibility="Collapsed">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0">
                <Border Style="{StaticResource Card}" Padding="14,10" Margin="0,0,0,10">
                  <TextBlock FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                    Text="Честно: большинство твиков Windows дают в лучшем случае несколько процентов и помогают 1% low и задержке больше, чем среднему FPS. У каждого переключателя есть оценка эффекта. Старые значения сохраняются до любого изменения, поэтому «Откатить» вернёт именно то, что было."/>
                </Border>
                <Border x:Name="bannerReboot" Visibility="Collapsed" Background="#161326" BorderBrush="#5A4A1E" BorderThickness="1" CornerRadius="10" Padding="14,9" Margin="0,0,0,10">
                  <TextBlock x:Name="bannerRebootText" FontSize="12.5" Foreground="{StaticResource Warn}" TextWrapping="Wrap"/>
                </Border>
                <DockPanel Margin="0,0,0,10" LastChildFill="True">
                  <TextBox x:Name="txtSearch" DockPanel.Dock="Right" Width="210" Style="{StaticResource Input}" ToolTip="Поиск твиков по названию или описанию"/>
                   <Button x:Name="btnOptKey" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Ввести ключ (PLUS / ULTRA)" Margin="10,0,10,0"/>
                  <StackPanel Orientation="Horizontal">
                    <RadioButton x:Name="fAll" Style="{StaticResource FilterChip}" GroupName="F" Content="Все" IsChecked="True"/>
                    <RadioButton x:Name="fSafe" Style="{StaticResource FilterChip}" GroupName="F" Content="Безопасные"/>
                    <RadioButton x:Name="fTest" Style="{StaticResource FilterChip}" GroupName="F" Content="Проверить"/>
                    <RadioButton x:Name="fAdv" Style="{StaticResource FilterChip}" GroupName="F" Content="Расширенные"/>
                    <RadioButton x:Name="fOpt" Style="{StaticResource FilterChip}" GroupName="F" Content="Опционально"/>
                  </StackPanel>
                </DockPanel>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnlTweaks" Margin="0,0,10,8"/></ScrollViewer>
              <Border Grid.Row="2" Style="{StaticResource Card}" Padding="16,12" Margin="0,6,0,0">
                <DockPanel LastChildFill="False">
                  <CheckBox x:Name="chkRestore" Style="{StaticResource Switch}" Content="Сначала создать точку восстановления" IsChecked="True" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontSize="12.5"/>
                  <Button x:Name="btnOptApply" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Применить выбранное" Margin="8,0,0,0"/>
                  <Button x:Name="btnOptRevert" DockPanel.Dock="Right" Style="{StaticResource BtnDanger}" Content="Откатить выбранное" Margin="8,0,0,0"/>
                  <Button x:Name="btnOptClear" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Сбросить" Margin="8,0,0,0"/>
                  <Button x:Name="btnOptRec" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Выбрать рекомендуемые"/>
                  <Button x:Name="btnOptGame" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Игровой профиль" ToolTip="Выбрать поддерживаемые безопасные параметры FPS и отклика"/>
                </DockPanel>
              </Border>
            </Grid>

            <!-- Rust -->
            <ScrollViewer x:Name="pgRust" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="0,0,10,12">
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Параметры запуска Steam" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,4,0,12" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Выберите нужные флаги, скопируйте и вставьте в Steam > Rust > Свойства > Общие > Параметры запуска. Число потоков подставлено по вашему процессору. Прирост небольшой и зависит от системы. Если что-то работает не так, уберите этот флаг."/>
                    <WrapPanel>
                      <CheckBox x:Name="loHigh" Style="{StaticResource Switch}" Content="-high   (по желанию, проверьте)" IsChecked="False" Margin="0,5,26,5"/>
                      <CheckBox x:Name="loExcl" Style="{StaticResource Switch}" Content="-window-mode exclusive" IsChecked="True" Margin="0,5,26,5"/>
                      <CheckBox x:Name="loCpu" Style="{StaticResource Switch}" Content="-cpuCount / -exThreads" IsChecked="True" Margin="0,5,26,5"/>
                      <CheckBox x:Name="loD3d" Style="{StaticResource Switch}" Content="-force-d3d11-no-singlethreaded" IsChecked="True" Margin="0,5,26,5"/>
                      <CheckBox x:Name="loLog" Style="{StaticResource Switch}" Content="-nolog" IsChecked="True" Margin="0,5,26,5"/>
                    </WrapPanel>
                    <Border Background="{StaticResource Bg0}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,12,0,0">
                      <TextBox x:Name="txtLaunch" IsReadOnly="True" Background="Transparent" BorderThickness="0" FontFamily="Consolas" FontSize="12.5" Foreground="{StaticResource AccentHi}" TextWrapping="Wrap"/>
                    </Border>
                    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                      <Button x:Name="btnCopyLaunch" Style="{StaticResource BtnPrimary}" Content="Копировать в буфер"/>
                      <TextBlock x:Name="txtLaunchNote" Margin="14,0,0,0" VerticalAlignment="Center" FontSize="12" Foreground="{StaticResource Muted}"/>
                    </StackPanel>
                    <TextBlock Margin="0,12,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Намеренно не включено: -maxMem и -malloc=system из старых гайдов. Для этой игры это городские легенды, а системный аллокатор может даже ухудшить результат."/>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Пресеты графики" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,4,0,12" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Записывает настоящие игровые конвары в client.cfg, те же значения, что сохраняет консоль F1, поэтому это безопасно для EAC. Самое сильное средство от микрофризов здесь это больший gc.buffer. Rust должен быть закрыт. Резервная копия создаётся при первом запуске, а «Восстановить» возвращает её."/>
                    <WrapPanel>
                      <Button x:Name="btnPreMax" Style="{StaticResource Btn}" Content="Макс. FPS" Margin="0,0,8,8"/>
                      <Button x:Name="btnPreComp" Style="{StaticResource Btn}" Content="Соревновательный" Margin="0,0,8,8"/>
                      <Button x:Name="btnPreBal" Style="{StaticResource Btn}" Content="Сбалансированный" Margin="0,0,8,8"/>
                      <Button x:Name="btnPreRestore" Style="{StaticResource BtnDanger}" Content="Восстановить копию" Margin="0,0,8,8"/>
                    </WrapPanel>
                    <TextBlock x:Name="txtPreStatus" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    <TextBlock Margin="0,10,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Макс. FPS: тени выключены, все постэффекты выключены. Соревновательный: короткие тени оставлены, чтобы видеть игроков в тени. Сбалансированный: выглядит прилично, но без самых дорогих эффектов."/>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="ЧЁРНЫЙ ГОЛОГРАММ" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Text="Декоративный стиль-предпросмотр внутри OTC OPTI. Не меняет изображение Rust, не показывает игроков и не создаёт игровой оверлей." FontSize="11.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,5,0,8"/>
                    <CheckBox x:Name="chkRustHolo" Style="{StaticResource Switch}" Content="Показать чёрный holo-preview" IsChecked="False" Margin="0,2,0,8"/>
                    <Border x:Name="pnlRustHolo" Visibility="Collapsed" Background="#080B12" BorderBrush="#24798A" BorderThickness="1" CornerRadius="10" Padding="16" ClipToBounds="True">
                      <Grid Height="92">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel VerticalAlignment="Center">
                          <TextBlock Text="RUST  /  HOLOGRAM PREVIEW" FontSize="10" FontWeight="Bold" Foreground="#52E8F5"/>
                          <TextBlock Text="BLACK GLASS" FontSize="21" FontWeight="Bold" Foreground="#E2F9FF" Margin="0,5,0,0"/>
                          <TextBlock Text="Только визуальная тема приложения" FontSize="11" Foreground="#8295A4" Margin="0,3,0,0"/>
                        </StackPanel>
                        <Grid Grid.Column="1" Width="78" Height="78" VerticalAlignment="Center" Margin="12,0,4,0">
                          <Ellipse Width="66" Height="66" Stroke="#3EE7F5" StrokeThickness="2" Opacity="0.9" RenderTransformOrigin="0.5,0.5">
                            <Ellipse.RenderTransform><RotateTransform x:Name="rustHoloRingRot" Angle="0"/></Ellipse.RenderTransform>
                            <Ellipse.Effect><DropShadowEffect Color="#20CDE3" BlurRadius="18" ShadowDepth="0" Opacity="0.75"/></Ellipse.Effect>
                          </Ellipse>
                          <Ellipse Width="48" Height="48" Stroke="#935CFF" StrokeThickness="1" Opacity="0.8"/>
                          <TextBlock Text="H" FontSize="25" FontWeight="Bold" Foreground="#D8FAFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Grid>
                        <Border Height="1" VerticalAlignment="Bottom" Background="#55DDF1" Opacity="0.65"/>
                      </Grid>
                    </Border>
                    <Button x:Name="btnRustHoloPremium" Style="{StaticResource Btn}" Content="Нужен ULTRA — активировать" HorizontalAlignment="Left" Margin="0,8,0,0"/>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="Что влияет на FPS сильнее любых твиков" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,8,0,0" FontSize="12.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap" LineHeight="20"
                      Text="1. Включите XMP / EXPO в BIOS (см. Главная).&#10;2. Держите Rust на SSD со свободным местом.&#10;3. При необъяснимых микрофризах сделайте чистую установку драйвера GPU (DDU в безопасном режиме).&#10;4. Ограничьте FPS на пару кадров ниже частоты монитора для ровного frametime.&#10;5. В игре больше всего ресурсов съедают дальность прорисовки и тени. Введите perf 1 в F1, чтобы видеть реальные цифры при тестах."/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>

            <!-- Game session -->
            <ScrollViewer x:Name="pgSession" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="0,0,10,12">
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Бусты сессии" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,4,0,12" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Работают только пока активна сессия и отменяются сами, когда она заканчивается или вы закрываете OTC OPTI. Настройки запуска не меняются, поэтому при сбое ничего не остаётся."/>
                    <CheckBox x:Name="sesTimer" Style="{StaticResource Switch}" Content="Держать самый точный системный таймер (обычно 0,5 мс)" IsChecked="True" Margin="0,5"/>
                    <CheckBox x:Name="sesPurge" Style="{StaticResource Switch}" Content="Умная очистка standby-памяти (только когда свободной памяти мало)" IsChecked="True" Margin="0,5"/>
                    <CheckBox x:Name="sesPrio" Style="{StaticResource Switch}" Content="Повышать приоритет игры до «Выше среднего» при запуске" IsChecked="True" Margin="0,5"/>
                    <CheckBox x:Name="sesPin" Style="{StaticResource Switch}" Content="Привязать игру к ядрам с V-Cache (только двухчиплетные X3D)" IsChecked="True" Margin="0,5" Visibility="Collapsed"/>
                    <CheckBox x:Name="sesSvc" Style="{StaticResource Switch}" Content="Приостановить фоновые службы (индексация, Windows Update, телеметрия, SysMain)" Margin="0,5"/>
                    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                      <TextBlock Text="Процесс игры" FontSize="12.5" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,12,0"/>
                      <TextBox x:Name="txtGameExe" Style="{StaticResource Input}" Width="200" Text="RustClient" ToolTip="Имя процесса без .exe. Работает с любой игрой, например cs2, FortniteClient-Win64-Shipping, javaw."/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                      <Button x:Name="btnSesToggle" Style="{StaticResource BtnPrimary}" Content="Начать сессию" Padding="26,11"/>
                      <CheckBox x:Name="sesAuto" Content="Автоматически запускать и останавливать вместе с игрой" Margin="18,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock x:Name="txtSesStatus" Margin="0,12,0,0" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    <TextBlock Margin="0,10,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Держите это окно открытым (можно свёрнутым), пока играете. В Windows 11 таймер доходит до игры только если применён твик глобального таймера и вы перезагрузились."/>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="Закрыть фоновые приложения" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,4,0,10" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Сначала просит каждое приложение закрыться, затем завершает оставшиеся. Сохраните свою работу. Steam не трогается, Rust запускается через него."/>
                    <WrapPanel x:Name="pnlKill"/>
                    <Button x:Name="btnKill" Style="{StaticResource BtnDanger}" Content="Закрыть выбранное" HorizontalAlignment="Left" Margin="0,10,0,0"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>

            <!-- Cleaner -->
            <Grid x:Name="pgClean" Visibility="Collapsed">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
                <Button x:Name="btnScan" Style="{StaticResource Btn}" Content="Узнать размеры"/>
                <Button x:Name="btnCleanRec" Style="{StaticResource Btn}" Content="Выбрать рекомендуемые" Margin="8,0,0,0"/>
                <Button x:Name="btnCleanNone" Style="{StaticResource Btn}" Content="Сбросить" Margin="8,0,0,0"/>
                <Button x:Name="btnCleanRun" Style="{StaticResource BtnPrimary}" Content="Очистить выбранное" Margin="8,0,0,0"/>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnlClean" Margin="0,0,10,0"/></ScrollViewer>
              <Border Grid.Row="2" Style="{StaticResource Card}" Padding="16,12" Margin="0,10,0,0">
                <StackPanel>
                  <DockPanel>
                    <TextBlock x:Name="txtCleanTotal" DockPanel.Dock="Right" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Accent}"/>
                    <TextBlock x:Name="txtCleanStatus" FontSize="12" Foreground="{StaticResource Muted}" Text="Ожидание."/>
                  </DockPanel>
                  <ProgressBar x:Name="barClean" Minimum="0" Maximum="100" Value="0" Margin="0,9,0,0"/>
                </StackPanel>
              </Border>
            </Grid>

            <!-- Debloat -->
            <Grid x:Name="pgDebloat" Visibility="Collapsed">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0">
                <Border Style="{StaticResource Card}" Padding="14,10" Margin="0,0,0,10">
                  <TextBlock FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                    Text="Удаляет предустановленные приложения для всех пользователей и из установочного образа, чтобы они не возвращались у новых аккаунтов. Microsoft Store, Фото, Блокнот, Калькулятор, Терминал, Ножницы, Paint и Edge не затрагиваются. Сначала создаётся точка восстановления, а всё удалённое можно снова поставить из Microsoft Store."/>
                </Border>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                  <Button x:Name="btnDbScan" Style="{StaticResource Btn}" Content="Сканировать ПК"/>
                  <Button x:Name="btnDbSafe" Style="{StaticResource Btn}" Content="Выбрать безопасные" Margin="8,0,0,0"/>
                  <Button x:Name="btnDbAll" Style="{StaticResource Btn}" Content="Выбрать все установленные" Margin="8,0,0,0"/>
                  <Button x:Name="btnDbNone" Style="{StaticResource Btn}" Content="Сбросить" Margin="8,0,0,0"/>
                  <Button x:Name="btnDbRun" Style="{StaticResource BtnPrimary}" Content="Удалить выбранное" Margin="8,0,0,0"/>
                </StackPanel>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnlDebloat" Margin="0,0,10,8"/></ScrollViewer>
              <Border Grid.Row="2" Style="{StaticResource Card}" Padding="16,12" Margin="0,6,0,0">
                <StackPanel>
                  <DockPanel>
                    <TextBlock x:Name="txtDbCount" DockPanel.Dock="Right" FontSize="13" FontWeight="Bold" Foreground="{StaticResource Accent}"/>
                    <TextBlock x:Name="txtDbStatus" FontSize="12" Foreground="{StaticResource Muted}" Text="Нажмите «Сканировать», чтобы увидеть, что из этого установлено."/>
                  </DockPanel>
                  <ProgressBar x:Name="barDb" Minimum="0" Maximum="100" Value="0" Margin="0,9,0,0"/>
                </StackPanel>
              </Border>
            </Grid>

            <!-- Startup -->
            <Grid x:Name="pgStartup" Visibility="Collapsed">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <Border Grid.Row="0" Style="{StaticResource Card}" Padding="14,10" Margin="0,0,0,10">
                <DockPanel>
                  <Button x:Name="btnStRefresh" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Обновить" Margin="14,0,0,0" VerticalAlignment="Center"/>
                  <TextBlock FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                    Text="Программы, которые запускаются при входе и висят в фоне, занимая ОЗУ и процессор. Отключите всё, что не нужно во время игры. Это мгновенно и полностью обратимо. Записи аудио, графического драйвера и безопасности лучше не трогать."/>
                </DockPanel>
              </Border>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnlStartup" Margin="0,0,10,8"/></ScrollViewer>
            </Grid>

            <!-- Internet -->
            <ScrollViewer x:Name="pgInternet" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="pnlInternet" Margin="0,0,10,12">
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Подключение" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,6,0,8" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Text="Ваше активное подключение, данные берутся из Windows. Здесь ничего не изменяется."/>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Адаптер" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nAdapter" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Тип" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nType" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Скорость линка" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nSpeed" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Адрес IPv4" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nIp" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Шлюз" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nGw" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="DNS-серверы" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nDnsSrv" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="MTU адаптера" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="nMtu" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <DockPanel>
                      <Button x:Name="btnNetTest" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Запустить тест"/>
                      <TextBlock Text="Состояние сети" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                    </DockPanel>
                    <TextBlock Margin="0,6,0,8" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Text="Измеряет пинг, джиттер и потерю пакетов до роутера и интернета. На FPS это не влияет, но показывает, что виновато: подключение или ПК."/>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Роутер (шлюз)" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="hGw" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Интернет (1.1.1.1)" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="hWan" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Потеря пакетов" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="hLoss" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Джиттер" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="hJit" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Запрос DNS" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="hDns" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Профиль TCP" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,6,0,8" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Rust и большинство шутеров гоняют игровой трафик по UDP, а эти настройки TCP его не затрагивают. Ждите улучшения загрузок, лаунчеров и TCP-сервисов, но не пинга в игре. Текущие настройки сохраняются перед первым изменением, а «По умолчанию» восстанавливает именно их."/>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Автонастройка" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tAuto" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Эвристика масштабирования" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tHeur" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="ECN" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tEcn" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Метки времени" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tTs" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Масштабирование на приёме (RSS)" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tRss" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Объединение на приёме (RSC)" FontSize="12.5" Foreground="{StaticResource Dim}"/>
                      <TextBlock x:Name="tRsc" Grid.Column="1" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/></Grid>
                    <CheckBox x:Name="swNetRollback" Style="{StaticResource Switch}" Content="Откатить автоматически, если связь ухудшится" IsChecked="True" Foreground="{StaticResource Muted}" FontSize="12.5" Margin="0,12,0,0"/>
                    <WrapPanel Margin="0,12,0,0">
                      <Button x:Name="btnTcpGaming" Style="{StaticResource BtnPrimary}" Content="Игровой / сбалансированный" Margin="0,0,8,8"/>
                      <Button x:Name="btnTcpThroughput" Style="{StaticResource Btn}" Content="Высокая пропускная способность" Margin="0,0,8,8"/>
                      <Button x:Name="btnTcpDefault" Style="{StaticResource BtnDanger}" Content="По умолчанию Windows (восстановить)" Margin="0,0,8,8"/>
                    </WrapPanel>
                    <TextBlock x:Name="txtTcpStatus" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
                    <TextBlock Margin="0,8,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Игровой / сбалансированный: автонастройка normal, эвристика выключена (Windows не будет тихо урезать окно приёма), ECN и метки времени выключены, RSS включён, RSC как было у вас. «Высокая пропускная способность» дополнительно включает RSC. Ни один не использует хаки реестра и не рисует фальшивый пинг."/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <DockPanel>
                      <Button x:Name="btnMtu" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Определить MTU"/>
                      <TextBlock Text="MTU" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                    </DockPanel>
                    <TextBlock x:Name="txtMtu" Margin="0,8,0,0" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap" Text="Ещё не проверялось."/>
                    <TextBlock Margin="0,6,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="Находит самый большой пакет, который проходит без фрагментации. Только показывает результат. Снижение MTU не снижает пинг, а 1500 подходит большинству подключений. Значение около 1492 обычно означает PPPoE."/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <DockPanel>
                      <Button x:Name="btnDns" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Проверить DNS"/>
                      <TextBlock Text="DNS" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}" VerticalAlignment="Center"/>
                    </DockPanel>
                    <TextBlock x:Name="txtDns" Margin="0,8,0,0" FontFamily="Consolas" FontSize="12" Foreground="{StaticResource Text}" TextWrapping="Wrap" Text="Ещё не проверялось."/>
                    <TextBlock Margin="0,6,0,0" FontSize="11.5" Foreground="{StaticResource Dim}" TextWrapping="Wrap"
                      Text="DNS влияет только на скорость разрешения имён вроде store.steampowered.com. Задержку уже открытого игрового соединения он не снижает. Здесь ничего не меняется. Результаты приблизительны, потому что резолверы кэшируют."/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>

            <!-- Restore -->
            <ScrollViewer x:Name="pgRestore" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="0,0,10,12">
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Откатить всё" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,6,0,12" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Отменяет все твики, применённые этим приложением, используя исходные значения, сохранённые перед изменением. Настройки TCP возвращаются к состоянию до первого сетевого изменения. Удалённые приложения здесь не восстанавливаются, поставьте их заново из Microsoft Store."/>
                    <WrapPanel>
                      <Button x:Name="btnRevertAll" Style="{StaticResource BtnDanger}" Content="Откатить все твики" Margin="0,0,8,8"/>
                      <Button x:Name="btnNetRestore" Style="{StaticResource Btn}" Content="Восстановить настройки сети" Margin="0,0,8,8"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Профили" FontSize="14" FontWeight="Bold" Foreground="{StaticResource Text}"/>
                    <TextBlock Margin="0,6,0,12" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"
                      Text="Экспорт сохраняет на рабочий стол список применённых твиков, журнал, настройки TCP и сводку по железу. Импорт загружает выбор твиков из профиля на страницу «Оптимизация», чтобы вы могли проверить его перед применением. Ничего не применяется автоматически."/>
                    <WrapPanel>
                      <Button x:Name="btnExport" Style="{StaticResource Btn}" Content="Экспорт профиля" Margin="0,0,8,8"/>
                      <Button x:Name="btnImport" Style="{StaticResource Btn}" Content="Импорт профиля" Margin="0,0,8,8"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
                <TextBlock x:Name="txtRestoreStatus" FontSize="12.5" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
              </StackPanel>
            </ScrollViewer>

            <!-- Log -->
            <ScrollViewer x:Name="pgSettings" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="АККАУНТ" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                    <TextBlock x:Name="sName" FontSize="18" FontWeight="Bold" Foreground="{StaticResource Text}" Margin="0,8,0,0"/>
                    <TextBlock x:Name="sId" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,3,0,0"/>
                    <TextBlock Text="Вход через Discord запоминается на этом ПК примерно на 7 дней. Потом нужно войти снова." FontSize="12" Foreground="{StaticResource Muted}" Margin="0,8,0,0" TextWrapping="Wrap"/>
                    <Button x:Name="btnLogout" Style="{StaticResource Btn}" Content="Выйти из аккаунта" HorizontalAlignment="Left" Margin="0,12,0,0"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,14,0,0">
                  <StackPanel>
                    <TextBlock Text="ЛИЦЕНЗИЯ" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                    <TextBlock x:Name="sLic" FontSize="16" FontWeight="Bold" Foreground="{StaticResource Text}" Margin="0,8,0,0" TextWrapping="Wrap"/>
                    <TextBlock x:Name="sLicSub" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,4,0,0" TextWrapping="Wrap"/>
                    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                      <Button x:Name="btnSetKey" Style="{StaticResource BtnPrimary}" Content="Активация ключа"/>
                      <Button x:Name="btnBuy2" Style="{StaticResource GoldBtn}" Margin="10,0,0,0" Content="Купить в Discord"/>
                    </StackPanel>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,14,0,0">
                  <StackPanel>
                    <TextBlock Text="БЫСТРАЯ ОПТИМИЗАЦИЯ" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                    <TextBlock x:Name="sQuick" FontSize="12.5" Foreground="{StaticResource Muted}" Margin="0,8,0,0" TextWrapping="Wrap"/>
                    <Button x:Name="btnQuick" Style="{StaticResource BtnPrimary}" Content="Быстрая оптимизация (25%)" HorizontalAlignment="Left" Margin="0,12,0,0"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,14,0,0">
                  <StackPanel>
                    <TextBlock Text="ОФОРМЛЕНИЕ" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                    <TextBlock Text="Выберите цветовую тему приложения. Выбор запоминается." FontSize="12" Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
                    <WrapPanel x:Name="sThemes" Margin="0,12,0,0"/>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Margin="0,14,0,0">
                  <StackPanel>
                    <TextBlock Text="ФУНКЦИИ" FontSize="10.5" FontWeight="Bold" Foreground="{StaticResource Dim}"/>
                    <TextBlock Text="FREE, PLUS и ULTRA: сравнение доступа к функциям." FontSize="12" Foreground="{StaticResource Muted}" Margin="0,4,0,10"/>
                    <StackPanel x:Name="sFeatures"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>

            <Grid x:Name="pgLog" Visibility="Collapsed">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
                <Button x:Name="btnLogFile" Style="{StaticResource Btn}" Content="Открыть файл журнала"/>
                <Button x:Name="btnLogClear" Style="{StaticResource Btn}" Content="Очистить вид" Margin="8,0,0,0"/>
              </StackPanel>
              <Border Grid.Row="1" Style="{StaticResource Card}" Padding="12">
                <ListBox x:Name="logList" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                  <ListBox.ItemContainerStyle>
                    <Style TargetType="ListBoxItem">
                      <Setter Property="Padding" Value="0"/><Setter Property="Margin" Value="0"/>
                      <Setter Property="Focusable" Value="False"/>
                      <Setter Property="Template">
                        <Setter.Value><ControlTemplate TargetType="ListBoxItem"><ContentPresenter/></ControlTemplate></Setter.Value>
                      </Setter>
                    </Style>
                  </ListBox.ItemContainerStyle>
                </ListBox>
              </Border>
            </Grid>
          </Grid>

          <Border Grid.Row="2" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
            <DockPanel Margin="30,0,24,0">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse Width="6" Height="6" Fill="{StaticResource Good}" VerticalAlignment="Center"/>
                <TextBlock Text="Администратор" FontSize="11" Foreground="{StaticResource Dim}" Margin="7,0,0,0"/>
              </StackPanel>
              <Ellipse x:Name="spin" DockPanel.Dock="Left" Width="12" Height="12" Stroke="{StaticResource Accent}" StrokeThickness="2" StrokeDashArray="2.4 2.6" Margin="0,0,10,0" Visibility="Collapsed" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                <Ellipse.RenderTransform><RotateTransform x:Name="spinRot" Angle="0"/></Ellipse.RenderTransform>
              </Ellipse>
              <TextBlock x:Name="lastLog" FontSize="11.5" Foreground="{StaticResource Dim}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Text="Готово."/>
            </DockPanel>
          </Border>
        </Grid>
      </Grid>

      <Border x:Name="toast" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,26,54" Visibility="Collapsed" IsHitTestVisible="False" Background="#191E36" BorderBrush="#FFFFFF" BorderThickness="1" CornerRadius="10" MinWidth="240" MaxWidth="380">
        <Border.RenderTransform><TranslateTransform x:Name="toastT" X="440"/></Border.RenderTransform>
        <Border.Effect><DropShadowEffect Color="#000000" BlurRadius="18" Opacity="0.5" ShadowDepth="4"/></Border.Effect>
        <StackPanel>
          <TextBlock x:Name="toastText" Margin="16,12,16,10" FontSize="12.5" FontWeight="SemiBold" Foreground="{StaticResource Text}" TextWrapping="Wrap"/>
          <Rectangle x:Name="toastBar" Height="2" Fill="{StaticResource Accent}" HorizontalAlignment="Left" Width="240"/>
        </StackPanel>
      </Border>
    </Grid>
  </Border>
</Window>
'@
# ---- animation engine -----------------------------------------------------------
# Every animation checks $script:AnimOn, so the "Animations" switch in the sidebar turns them all off.
$script:BaseOp = @{}

function Get-Span { param([double]$Ms) return [TimeSpan]::FromMilliseconds($Ms) }
function Get-Dur  { param([double]$Ms) return (New-Object Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds($Ms))) }

function New-Ease {
    param([string]$Kind = 'Quad', [string]$Mode = 'EaseOut')
    $e = switch ($Kind) {
        'Back'  { New-Object Windows.Media.Animation.BackEase }
        'Sine'  { New-Object Windows.Media.Animation.SineEase }
        'Cubic' { New-Object Windows.Media.Animation.CubicEase }
        default { New-Object Windows.Media.Animation.QuadraticEase }
    }
    if ($Kind -eq 'Back') { $e.Amplitude = 0.45 }
    $e.EasingMode = $Mode
    return $e
}

function New-DAnim {
    param([double]$From, [double]$To, [double]$DurMs, [int]$Delay = 0, $Ease = $null)
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    $a.From = $From
    $a.To = $To
    $a.Duration = Get-Dur $DurMs
    if ($Delay -gt 0) { $a.BeginTime = Get-Span $Delay }
    if ($Ease) { $a.EasingFunction = $Ease }
    return $a
}

function Start-FadeSlide {
    param($El, [int]$Delay = 0, [double]$Dy = 14, [double]$Dx = 0, [int]$Dur = 420)
    if (-not $El) { return }
    $key = $El.GetHashCode()
    if (-not $script:BaseOp.ContainsKey($key)) { $script:BaseOp[$key] = $(if ($El.Opacity -gt 0.05) { [double]$El.Opacity } else { 1.0 }) }
    $to = [double]$script:BaseOp[$key]
    $opacity = [Windows.UIElement]::OpacityProperty
    if (-not $script:AnimOn) {
        $El.BeginAnimation($opacity, $null)
        $El.Opacity = $to
        $El.RenderTransform = [Windows.Media.Transform]::Identity
        return
    }
    $tt = New-Object Windows.Media.TranslateTransform
    $tt.X = $Dx; $tt.Y = $Dy
    $El.RenderTransform = $tt
    $El.Opacity = 0
    $ease = New-Ease 'Quad' 'EaseOut'
    $El.BeginAnimation($opacity, (New-DAnim 0 $to $Dur $Delay $ease))
    if ($Dy -ne 0) { $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-DAnim $Dy 0 $Dur $Delay $ease)) }
    if ($Dx -ne 0) { $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-DAnim $Dx 0 $Dur $Delay $ease)) }
}

function Start-Pop {
    param($El, [int]$Delay = 0, [double]$From = 0.6, [int]$Dur = 380)
    if (-not $El -or -not $script:AnimOn) { return }
    $El.RenderTransformOrigin = New-Object Windows.Point -ArgumentList 0.5, 0.5
    $st = New-Object Windows.Media.ScaleTransform
    $st.ScaleX = $From; $st.ScaleY = $From
    $El.RenderTransform = $st
    $ease = New-Ease 'Back' 'EaseOut'
    $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim $From 1 $Dur $Delay $ease))
    $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim $From 1 $Dur $Delay $ease))
}

function Start-Forever {
    param($Target, $Prop, [double]$From, [double]$To, [double]$Sec, [bool]$Reverse = $true, [string]$Kind = 'Sine', [int]$Delay = 0)
    if (-not $script:AnimOn -or -not $Target) { return }
    # Performance fix: never animate DropShadowEffect blur. WPF recalculates the
    # full blur surface on every frame; keep these glows static instead.
    if (($Target -is [Windows.Media.Effects.DropShadowEffect]) -and
        ($Prop -eq [Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty)) { return }
    $a = New-DAnim $From $To ($Sec * 1000)
    $a.AutoReverse = $Reverse
    if ($Delay -gt 0) { $a.BeginTime = Get-Span $Delay }
    $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    if ($Reverse) { $a.EasingFunction = New-Ease $Kind 'EaseInOut' }
    $Target.BeginAnimation($Prop, $a)
}

function Stop-Anim {
    param($Target, $Prop)
    try { if ($Target) { $Target.BeginAnimation($Prop, $null) } } catch { }
}

function Start-Stagger {
    param($Panel, [int]$Max = 14, [int]$Step = 34, [int]$Base = 0, [double]$Dy = 12)
    if (-not $Panel) { return }
    $i = 0
    foreach ($ch in @($Panel.Children)) {
        if ($i -ge $Max) { break }
        Start-FadeSlide $ch ($Base + $i * $Step) $Dy 0 360
        $i++
    }
}

function Set-BarAnimated {
    param($Bar, [double]$Value)
    $old = $Bar.Value
    $Bar.Value = $Value
    if (-not $script:AnimOn -or [math]::Abs($old - $Value) -lt 0.5) { return }
    $a = New-DAnim $old $Value 650 0 (New-Ease 'Cubic' 'EaseOut')
    $a.FillBehavior = 'Stop'
    $Bar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $a)
}

function Set-Spinner {
    param([bool]$On)
    $ui = $script:UI
    if (-not $ui.spin) { return }
    $prop = [Windows.Media.RotateTransform]::AngleProperty
    if ($On) {
        $ui.spin.Visibility = 'Visible'
        Start-Forever $ui.spinRot $prop 0 360 0.9 $false
    } else {
        Stop-Anim $ui.spinRot $prop
        $ui.spin.Visibility = 'Collapsed'
    }
}

function Add-CardHover {
    param($Card)
    $Card.BorderBrush = New-Object Windows.Media.SolidColorBrush -ArgumentList ([Windows.Media.ColorConverter]::ConvertFromString('#242A47'))
    $Card.Add_MouseEnter({
        param($s, $e)
        if ($script:AnimOn) {
            $ca = New-Object Windows.Media.Animation.ColorAnimation
            $ca.To = [Windows.Media.ColorConverter]::ConvertFromString('#6B6B6B'); $ca.Duration = Get-Dur 140
            $s.BorderBrush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca)
        }
    })
    $Card.Add_MouseLeave({
        param($s, $e)
        if ($script:AnimOn) {
            $ca = New-Object Windows.Media.Animation.ColorAnimation
            $ca.To = [Windows.Media.ColorConverter]::ConvertFromString('#242A47'); $ca.Duration = Get-Dur 240
            $s.BorderBrush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca)
        }
    })
}

function Update-ApplyGlow {
    $btn = $script:UI.btnOptApply
    if (-not $btn) { return }
    $n = $script:Sel.Count
    $label = if ($n -gt 0) { "Применить выбранное ($n)" } else { 'Применить выбранное' }
    if ($btn.Content -ne $label) { $btn.Content = $label; if ($n -gt 0) { Start-Pop $btn 0 0.94 220 } }
    if ($script:Sel.Count -gt 0 -and $script:AnimOn) {
        if (-not $btn.Effect) {
            $fx = New-Object Windows.Media.Effects.DropShadowEffect
            $fx.Color = [Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF')
            $fx.ShadowDepth = 0; $fx.Opacity = 0.85; $fx.BlurRadius = 6
            $btn.Effect = $fx
            Start-Forever $fx ([Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty) 4 22 1.0 $true
        }
    } else { $btn.Effect = $null }
}

function Set-Ambient {
    # slow background pulses in the app shell
    $ui = $script:UI
    $blur = [Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty
    if ($script:AnimOn) {
        Start-Forever $ui.sideFx $blur 6 18 2.8 $true
        if (-not $ui.btnOptimizeAll.Effect) {
            $fx = New-Object Windows.Media.Effects.DropShadowEffect
            $fx.Color = [Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF')
            $fx.ShadowDepth = 0; $fx.Opacity = 0.7; $fx.BlurRadius = 6
            $ui.btnOptimizeAll.Effect = $fx
            Start-Forever $fx $blur 6 26 1.7 $true
        }
    } else {
        Stop-Anim $ui.sideFx $blur
        $ui.btnOptimizeAll.Effect = $null
    }
}

function Start-Particles {
    $ui = $script:UI
    $c = $ui.particles
    $c.Children.Clear()
    if (-not $script:AnimOn) { return }
    $w = $ui.landing.ActualWidth; if ($w -lt 200) { $w = 1100 }
    $h = $ui.landing.ActualHeight; if ($h -lt 200) { $h = 720 }
    $rnd = New-Object System.Random
    for ($i = 0; $i -lt 6; $i++) {
        $size = 2 + $rnd.NextDouble() * 2.6
        $e = New-Object Windows.Shapes.Ellipse
        $e.Width = $size; $e.Height = $size
        $e.Fill = Get-Brush '#FFFFFF' (0.35 + $rnd.NextDouble() * 0.4)
        [Windows.Controls.Canvas]::SetLeft($e, $rnd.NextDouble() * $w)
        [Windows.Controls.Canvas]::SetTop($e, -8)
        $tt = New-Object Windows.Media.TranslateTransform
        $e.RenderTransform = $tt
        $e.Opacity = 0
        [void]$c.Children.Add($e)
        $dur = 9 + $rnd.NextDouble() * 8
        $delay = [int]($rnd.NextDouble() * 7000)
        $ya = New-DAnim 0 ($h * 0.9 + $rnd.NextDouble() * 120 + 20) ($dur * 1000) $delay
        $ya.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $ya)
        $ka = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $ka.Duration = Get-Dur ($dur * 1000)
        $ka.BeginTime = Get-Span $delay
        $ka.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        foreach ($kf in @(@(0, 0.0), @(0.8, 0.2), @(0.8, 0.7), @(0, 1.0))) {
            $frame = New-Object Windows.Media.Animation.LinearDoubleKeyFrame
            $frame.Value = [double]$kf[0]
            $frame.KeyTime = [Windows.Media.Animation.KeyTime]::FromPercent([double]$kf[1])
            [void]$ka.KeyFrames.Add($frame)
        }
        $e.BeginAnimation([Windows.UIElement]::OpacityProperty, $ka)
    }
}

function Stop-Particles {
    $c = $script:UI.particles
    foreach ($e in @($c.Children)) {
        try { $e.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null); $e.BeginAnimation([Windows.UIElement]::OpacityProperty, $null) } catch { }
    }
    $c.Children.Clear()
}

# ---- debloat page ---------------------------------------------------------------
$script:DbBuilt = $false
$script:DbCatalog = @()
$script:DbRows = @{}
$script:DbCtx = @{ Busy = $false; Seeded = $false }
$script:DbButtons = @('btnDbScan', 'btnDbSafe', 'btnDbAll', 'btnDbNone', 'btnDbRun')

function Update-DbCount {
    $n = 0
    foreach ($id in $script:DbRows.Keys) { $r = $script:DbRows[$id]; if ($r.Switch.IsChecked -and $r.Switch.IsEnabled) { $n++ } }
    $script:UI.txtDbCount.Text = "$n selected"
}

function Build-DebloatPage {
    $ui = $script:UI
    $script:DbCatalog = @(Get-DebloatCatalog)
    $ui.pnlDebloat.Children.Clear()
    $script:DbRows = @{}
    foreach ($cat in $script:DebloatCats.Keys) {
        $h = New-Tb ($script:DebloatCats[$cat].ToUpper()) 10.5 'Dim' $true
        $h.Margin = '2,14,0,8'
        [void]$ui.pnlDebloat.Children.Add($h)
        foreach ($d in @($script:DbCatalog | Where-Object { $_.Cat -eq $cat })) {
            $card = New-Object Windows.Controls.Border
            $card.Background = Get-Res 'Bg2'
            $card.BorderThickness = '1'
            $card.CornerRadius = New-Object Windows.CornerRadius -ArgumentList 10
            $card.Padding = '14,9'
            $card.Margin = '0,0,0,6'
            Add-CardHover $card
            $g = New-Object Windows.Controls.Grid
            foreach ($w in 'Auto', '*', 'Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
            $sw = New-Object Windows.Controls.CheckBox
            $sw.Style = Get-Res 'Switch'
            $sw.Tag = $d.Id
            $sw.VerticalAlignment = 'Center'
            $sw.Margin = '0,0,14,0'
            $sw.Add_Click({ Update-DbCount })
            [void]$g.Children.Add($sw)
            $mid = New-Object Windows.Controls.WrapPanel
            $mid.VerticalAlignment = 'Center'
            $nm = New-Tb $d.Name 13 'Text' $true
            $nm.TextWrapping = 'NoWrap'; $nm.Margin = '0,0,10,0'; $nm.VerticalAlignment = 'Center'
            [void]$mid.Children.Add($nm)
            if ($d.Safe) { [void]$mid.Children.Add((New-Chip 'Можно удалить' 'Good' 'Bg1')) } else { [void]$mid.Children.Add((New-Chip 'Опционально' 'Warn' 'Bg1')) }
            [Windows.Controls.Grid]::SetColumn($mid, 1)
            [void]$g.Children.Add($mid)
            $st = New-Tb '' 11.5 'Dim' $true
            $st.TextWrapping = 'NoWrap'; $st.VerticalAlignment = 'Center'; $st.Margin = '12,0,0,0'
            [Windows.Controls.Grid]::SetColumn($st, 2)
            [void]$g.Children.Add($st)
            $card.Child = $g
            [void]$ui.pnlDebloat.Children.Add($card)
            $script:DbRows[$d.Id] = @{ Item = $d; Card = $card; Switch = $sw; Status = $st; Installed = $null }
        }
    }
    $script:DbBuilt = $true
    Update-DbCount
}

function Set-DbBusy {
    param([bool]$Busy)
    foreach ($b in $script:DbButtons) { $script:UI[$b].IsEnabled = -not $Busy }
    $script:DbCtx.Busy = $Busy
    $script:UI.navPanel.IsEnabled = -not $Busy
    Set-Spinner $Busy
}

function Start-DebloatScan {
    $ui = $script:UI
    if ($script:DbCtx.Busy) { return }
    Set-DbBusy $true
    $ui.txtDbStatus.Text = 'Сканирование установленных приложений...'
    Invoke-Async -Work $script:DebloatScan -OnDone {
        param($res, $err)
        $ui = $script:UI
        Set-DbBusy $false
        if ($err) { $ui.txtDbStatus.Text = "Ошибка сканирования: $err"; Write-Log "Debloat scan failed: $err" 'err'; return }
        $names = @($res | ForEach-Object { $_ })
        $found = 0
        foreach ($id in $script:DbRows.Keys) {
            $r = $script:DbRows[$id]; $d = $r.Item; $has = $false
            if ($d.Special -eq 'onedrive') { $has = ($names -contains '__onedrive__') }
            else { foreach ($pat in $d.Patterns) { if (@($names | Where-Object { $_ -like $pat }).Count -gt 0) { $has = $true; break } } }
            $r.Installed = $has
            if ($has) {
                $found++
                $r.Status.Text = 'Установлено'; $r.Status.Foreground = Get-Res 'Good'
                $r.Switch.IsEnabled = $true
            } else {
                $r.Status.Text = 'Не установлено'; $r.Status.Foreground = Get-Res 'Dim'
                $r.Switch.IsChecked = $false; $r.Switch.IsEnabled = $false
            }
        }
        if (-not $script:DbCtx.Seeded) {
            $script:DbCtx.Seeded = $true
            foreach ($id in $script:DbRows.Keys) { $r = $script:DbRows[$id]; if ($r.Installed -and $r.Item.Safe) { $r.Switch.IsChecked = $true } }
        }
        $ui.txtDbStatus.Text = "$found приложений, доступных для удаления, найдено на этом ПК."
        Update-DbCount
        Write-Log "Debloat scan: $found removable app(s) installed." 'info'
    }
}

function Select-DbRows {
    param([string]$Mode)
    foreach ($id in $script:DbRows.Keys) {
        $r = $script:DbRows[$id]
        if (-not $r.Switch.IsEnabled) { continue }
        $r.Switch.IsChecked = switch ($Mode) { 'safe' { [bool]$r.Item.Safe } 'all' { $true } default { $false } }
    }
    Update-DbCount
}

function Start-DebloatRemove {
    $ui = $script:UI
    if ($script:DbCtx.Busy) { return }
    $sel = @($script:DbRows.Values | Where-Object { $_.Switch.IsChecked -and $_.Switch.IsEnabled -and $_.Installed -ne $false })
    if ($sel.Count -eq 0) { Write-Log 'Для удаления ничего не выбрано.' 'warn'; return }
    $msg = "Удалить элементов с этого ПК: $($sel.Count)?"
    if (@($sel | Where-Object { $_.Item.Cat -eq 'xbox' }).Count -gt 0) { $msg += "`n`nВы выбрали компоненты Xbox / Gaming Services. Без них перестанут работать Game Pass и некоторые игровые лаунчеры." }
    $ans = [Windows.MessageBox]::Show($msg, 'OTC OPTI', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    Set-DbBusy $true
    try { Write-Log 'Создаю точку восстановления...' 'info'; Invoke-UiPump; New-RestorePointAsync; Write-Log 'Точка восстановления создана.' 'ok' }
    catch { Write-Log "Точка восстановления не создана: $($_.Exception.Message)" 'warn' }
    $items = @($sel | ForEach-Object { @{ Id = $_.Item.Id; Patterns = @($_.Item.Patterns); Special = $_.Item.Special } })
    $script:DbCtx.Count = $items.Count; $script:DbCtx.Done = 0; $script:DbCtx.Removed = 0; $script:DbCtx.Failed = 0
    $ui.barDb.Value = 0
    $ui.txtDbStatus.Text = 'Удаление приложений. Это может занять несколько минут...'
    Invoke-Async -Work $script:DebloatWork -ArgList @(, $items) -OnProgress {
        param($it)
        $ctx = $script:DbCtx
        $r = $script:DbRows[$it.Id]
        if ($it.Kind -eq 'start') { $r.Status.Text = 'Удаление...'; $r.Status.Foreground = Get-Res 'Warn'; return }
        $ctx.Done++
        if ($it.Removed -gt 0) { $ctx.Removed++; $r.Status.Text = 'Удалено'; $r.Status.Foreground = Get-Res 'Good'; $r.Installed = $false; Start-Pop $r.Status 0 0.7 300; Start-SlideOut $r.Card }
        elseif ($it.Err) { $ctx.Failed++; $r.Status.Text = 'Ошибка'; $r.Status.Foreground = Get-Res 'Bad'; $r.Status.ToolTip = [string]$it.Err }
        else { $r.Status.Text = 'Не найдено'; $r.Status.Foreground = Get-Res 'Dim'; $r.Installed = $false }
        $r.Switch.IsChecked = $false
        if ($it.Removed -gt 0) { $r.Switch.IsEnabled = $false }
        Set-BarAnimated $script:UI.barDb ([math]::Round(100 * $ctx.Done / [math]::Max(1, $ctx.Count)))
        $script:UI.txtDbStatus.Text = "Удаление приложений... $($ctx.Done) из $($ctx.Count)"
    } -OnDone {
        param($res, $err)
        $ctx = $script:DbCtx
        Set-DbBusy $false
        Update-DbCount
        if ($err) { $script:UI.txtDbStatus.Text = "Failed: $err"; Write-Log "Debloat failed: $err" 'err'; return }
        $script:UI.barDb.Value = 100
        $script:UI.txtDbStatus.Text = "Готово. Удалено: $($ctx.Removed), ошибок: $($ctx.Failed)."
        Write-Log "Debloat finished: $($ctx.Removed) removed, $($ctx.Failed) failed." $(if ($ctx.Failed -gt 0) { 'warn' } else { 'ok' })
        Show-Toast "Removed $($ctx.Removed) app(s)$(if ($ctx.Failed -gt 0) { ", $($ctx.Failed) failed" })" $(if ($ctx.Failed -gt 0) { 'warn' } else { 'ok' })
    }
}

# ---- startup page ---------------------------------------------------------------
$script:StItems = @()

function Build-StartupPage {
    $ui = $script:UI
    $ui.pnlStartup.Children.Clear()
    $script:StItems = @(Get-StartupItems)
    if ($script:StItems.Count -eq 0) {
        [void]$ui.pnlStartup.Children.Add((New-Tb 'Программ в автозапуске не найдено. Из обычных мест при входе ничего не запускается.' 12.5 'Muted'))
        return
    }
    $i = 0
    foreach ($it in $script:StItems) {
        $card = New-Object Windows.Controls.Border
        $card.Background = Get-Res 'Bg2'
        $card.BorderThickness = '1'
        $card.CornerRadius = New-Object Windows.CornerRadius -ArgumentList 10
        $card.Padding = '14,10'
        $card.Margin = '0,0,0,6'
        Add-CardHover $card
        $g = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto', '*') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
        $sw = New-Object Windows.Controls.CheckBox
        $sw.Style = Get-Res 'Switch'
        $sw.Tag = $i
        $sw.IsChecked = [bool]$it.Enabled
        $sw.VerticalAlignment = 'Center'
        $sw.Margin = '0,0,14,0'
        $sw.Add_Click({ param($s, $e) Invoke-Safe { Set-StartupItem ([int]$s.Tag) ([bool]$s.IsChecked) } 'Startup toggle'; Start-Flash $s.Parent.Parent })
        [void]$g.Children.Add($sw)
        $mid = New-Object Windows.Controls.StackPanel
        $head = New-Object Windows.Controls.WrapPanel
        $nm = New-Tb $it.Name 13 'Text' $true
        $nm.TextWrapping = 'NoWrap'; $nm.Margin = '0,0,10,0'; $nm.VerticalAlignment = 'Center'
        [void]$head.Children.Add($nm)
        [void]$head.Children.Add((New-Chip $it.Scope 'Dim' 'Bg1'))
        if (("$($it.Name) $($it.Command)") -match $script:StartupKeep) { [void]$head.Children.Add((New-Chip 'Скорее всего нужно' 'Warn' 'Bg1')) }
        [void]$mid.Children.Add($head)
        $cmd = New-Tb $it.Command 11 'Dim'
        $cmd.FontFamily = 'Consolas'; $cmd.TextTrimming = 'CharacterEllipsis'; $cmd.TextWrapping = 'NoWrap'; $cmd.Margin = '0,3,0,0'
        $cmd.ToolTip = $it.Command
        [void]$mid.Children.Add($cmd)
        [Windows.Controls.Grid]::SetColumn($mid, 1)
        [void]$g.Children.Add($mid)
        $card.Child = $g
        [void]$ui.pnlStartup.Children.Add($card)
        $i++
    }
}

function Set-StartupItem {
    param([int]$Index, [bool]$On)
    $it = $script:StItems[$Index]
    Set-StartupEnabled $it.Key $it.Name $On
    $it.Enabled = $On
    Write-Log ("Startup: {0} {1}." -f $it.Name, $(if ($On) { 'will launch at sign-in' } else { 'will no longer launch at sign-in' })) $(if ($On) { 'info' } else { 'accent' })
}
# ---- animation catalog -------------------------------------------------------------------------
# Every entry below is implemented in code. The Animations switch in the sidebar turns them all off.
$script:AnimCatalog = @(
    # landing page
    'Window fade-in', 'Window settle zoom', 'Background gradient drift', 'Glow breathing', 'Glow swell', 'Logo fade-in', 'Logo spring pop',
    'Ring rotation', 'Counter-rotating dotted ring', 'Orbiting dot (inner)', 'Orbiting dot (outer, reverse)', 'Logo glow pulse', 'Bolt flicker',
    'Tagline rise', 'Title letter cascade', 'Title letter hover lift', 'Title letter hover color flash', 'Subtitle rise', 'Subtitle underline grow',
    'Paragraph rise', 'Enter button fade-in', 'Enter button spring pop', 'Enter button light sweep', 'Enter button idle glow pulse',
    'Enter button arrow nudge', 'Enter button hover glow and grow', 'Chips staggered rise', 'Chips gentle bob', 'Footer fade-in',
    'Window controls fade-in', 'Floating particles', 'Bokeh drift', 'Parallax on mouse move', 'Click ripple', 'Landing exit fade', 'Landing exit zoom',
    # app shell
    'App slide-in', 'Nav staggered slide-in', 'Nav sliding highlight', 'Nav hover nudge', 'Nav icon pop', 'Sidebar logo spring pop',
    'Sidebar logo glow pulse', 'Animations switch fade-in', 'Page fade and slide', 'Page title rise', 'Page subtitle rise', 'Header accent bar grow',
    # dashboard
    'Dashboard cards staggered rise', 'Dashboard card hover lift', 'Applied count-up', 'Progress bar fill', 'Findings staggered rise',
    'Finding row hover glow', 'Warning dot pulse', 'Optimize-all button glow pulse', 'Change summary reveal', 'Change list stagger',
    # lists and controls
    'List stagger (optimize, debloat, startup, cleaner, internet)', 'Switch knob slide with overshoot', 'Switch track color fade', 'Button hover fade',
    'Button press squash', 'Card hover border glow', 'Status pill pop', 'Tier filter chip pop', 'Search box focus expand', 'Apply button glow pulse',
    'Apply count pop', 'Reboot banner drop-in', 'Reboot banner pulse', 'Busy spinner', 'Busy progress bar pulse', 'Cleaner result pop',
    'Removed app slide-out', 'Removed status pop', 'Startup toggle flash', 'Network result pop', 'Network test button pulse', 'TCP status pop',
    # feedback and chrome
    'Toast slide-in', 'Toast timer bar', 'Toast slide-out', 'Log row fade-in', 'Status text fade', 'Session dot pulse', 'Session ring ping',
    'Sidebar status title pop', 'Window drag dim', 'Window close fade', 'Window close shrink'
)

# ---- small helpers ---------------------------------------------------------------------------------
$script:EnterArrowT = $null
$script:Ready = $false
$script:Prepared = $false
$script:CloseNow = $false
$script:DeferFindings = $false
$script:FindingsBusy = $false
$script:ParLast = 0
$script:Ripples = New-Object System.Collections.Queue

function Get-Color { param([string]$Hex) return [Windows.Media.ColorConverter]::ConvertFromString($Hex) }

function Set-EnterContent {
    param([string]$Text, [bool]$Arrow = $true)
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = 14
    $tb.FontWeight = 'Bold'
    $tb.Foreground = Get-Brush '#0D0A1F'
    [void]$sp.Children.Add($tb)
    $script:EnterArrowT = $null
    if ($Arrow) {
        $ar = New-Object Windows.Controls.TextBlock
        $ar.Text = [string][char]0x2192
        $ar.FontSize = 15
        $ar.FontWeight = 'Bold'
        $ar.Foreground = Get-Brush '#0D0A1F'
        $ar.Margin = '12,0,0,0'
        $t = New-Object Windows.Media.TranslateTransform
        $ar.RenderTransform = $t
        $script:EnterArrowT = $t
        [void]$sp.Children.Add($ar)
        if ($script:AnimOn) { Start-Forever $t ([Windows.Media.TranslateTransform]::XProperty) 0 7 0.6 $true }
    }
    $script:UI.btnEnter.Content = $sp
}

function Set-LandingSys {
    $F = $script:Facts
    $dot = [string][char]0x00B7
    $script:UI.lnSys.Text = ("{0}   {1}   {2} ГБ ОЗУ   {1}   v{3}" -f $F.CpuName, $dot, $F.RamGB, $script:Version)
    if ($env:OTC_DISCORD_NAME) { $script:UI.lnSys.Text += ("   {0}   Discord: {1}" -f $dot, $env:OTC_DISCORD_NAME) }
}

function Move-NavHighlight {
    param($Item, [switch]$Instant)
    $ui = $script:UI
    if (-not $Item -or -not $ui.navHi) { return }
    try {
        $ui.navPanel.UpdateLayout()
        $pt = $Item.TransformToAncestor($ui.navPanel).Transform((New-Object Windows.Point -ArgumentList 0, 0))
        $ui.navHi.Visibility = 'Visible'
        $ui.navHi.Height = [double]$Item.ActualHeight
        $y = [Windows.Media.TranslateTransform]::YProperty
        if ($script:AnimOn -and -not $Instant) { $ui.navHiT.BeginAnimation($y, (New-DAnim $ui.navHiT.Y $pt.Y 300 0 (New-Ease 'Back' 'EaseOut'))) }
        else { $ui.navHiT.BeginAnimation($y, $null); $ui.navHiT.Y = $pt.Y }
    } catch { }
}

function Set-HeaderBar {
    $b = $script:UI.hdrBar
    if (-not $b) { return }
    $w = [Windows.FrameworkElement]::WidthProperty
    if ($script:AnimOn) { $b.BeginAnimation($w, (New-DAnim 0 44 420 80 (New-Ease 'Cubic' 'EaseOut'))) }
    else { $b.BeginAnimation($w, $null); $b.Width = 44 }
}

function Set-SessionRing {
    param([bool]$On)
    $ui = $script:UI
    if (-not $ui.sideRing) { return }
    $sx = [Windows.Media.ScaleTransform]::ScaleXProperty; $sy = [Windows.Media.ScaleTransform]::ScaleYProperty; $op = [Windows.UIElement]::OpacityProperty
    if ($On -and $script:AnimOn) {
        Start-Forever $ui.sideRingS $sx 1 3.4 1.5 $false
        Start-Forever $ui.sideRingS $sy 1 3.4 1.5 $false
        Start-Forever $ui.sideRing $op 0.9 0 1.5 $false
    } else {
        Stop-Anim $ui.sideRingS $sx; Stop-Anim $ui.sideRingS $sy; Stop-Anim $ui.sideRing $op
        $ui.sideRing.Opacity = 0
    }
}

function Add-CardLift {
    param($El)
    if (-not $El) { return }
    $El.Add_MouseEnter({ param($s, $e)
        if (-not $script:AnimOn) { return }
        if ($s.RenderTransform -isnot [Windows.Media.TranslateTransform]) { $s.RenderTransform = New-Object Windows.Media.TranslateTransform }
        $s.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-DAnim $s.RenderTransform.Y -3 150 0 (New-Ease)))
    })
    $El.Add_MouseLeave({ param($s, $e)
        if (-not $script:AnimOn) { return }
        if ($s.RenderTransform -is [Windows.Media.TranslateTransform]) { $s.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-DAnim $s.RenderTransform.Y 0 220 0 (New-Ease))) }
    })
}

function Start-Flash {
    param($Card)
    if (-not $Card -or -not $script:AnimOn -or $Card.BorderBrush -isnot [Windows.Media.SolidColorBrush]) { return }
    $ca = New-Object Windows.Media.Animation.ColorAnimation
    $ca.To = Get-Color '#FFFFFF'; $ca.Duration = Get-Dur 200; $ca.AutoReverse = $true
    try { $Card.BorderBrush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca) } catch { }
}

function Start-SlideOut {
    param($El)
    if (-not $El) { return }
    if (-not $script:AnimOn) { return }
    $tt = New-Object Windows.Media.TranslateTransform
    $El.RenderTransform = $tt
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-DAnim 0 36 280 0 (New-Ease 'Quad' 'EaseIn')))
    $El.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-DAnim 1 0.4 280))
}

# ---- toast notifications ----------------------------------------------------------------------------
$script:ToastTimer = $null

function Hide-Toast {
    $ui = $script:UI
    if (-not $ui.toast) { return }
    if ($script:AnimOn) {
        $a = New-DAnim $ui.toastT.X 440 260 0 (New-Ease 'Quad' 'EaseIn')
        $a.Add_Completed({ $script:UI.toast.Visibility = 'Collapsed' })
        $ui.toastT.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $a)
    } else { $ui.toast.Visibility = 'Collapsed' }
}

function Show-Toast {
    param([string]$Text, [string]$Kind = 'ok')
    $ui = $script:UI
    if (-not $ui.toast) { return }
    $hex = switch ($Kind) { 'ok' { '#2ED3A0' } 'err' { '#FF5C7A' } 'warn' { '#FFB547' } default { '#FFFFFF' } }
    $ui.toast.BorderBrush = Get-Brush $hex
    $ui.toastBar.Fill = Get-Brush $hex
    $ui.toastText.Text = $Text
    $ui.toast.Visibility = 'Visible'
    $x = [Windows.Media.TranslateTransform]::XProperty
    if ($script:AnimOn) {
        $ui.toastT.BeginAnimation($x, (New-DAnim 440 0 380 0 (New-Ease 'Back' 'EaseOut')))
        $ui.toastBar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-DAnim 240 0 3400 300))
    } else {
        $ui.toastT.BeginAnimation($x, $null); $ui.toastT.X = 0
        $ui.toastBar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null); $ui.toastBar.Width = 240
    }
    if ($script:ToastTimer) { $script:ToastTimer.Stop() }
    $script:ToastTimer = New-Object Windows.Threading.DispatcherTimer
    $script:ToastTimer.Interval = [TimeSpan]::FromMilliseconds(3800)
    $script:ToastTimer.Add_Tick({ $script:ToastTimer.Stop(); Hide-Toast })
    $script:ToastTimer.Start()
}

# ---- landing extras ----------------------------------------------------------------------------------
function Start-Bokeh {
    $ui = $script:UI
    $c = $ui.bokeh
    $c.Children.Clear()
    if (-not $script:AnimOn) { return }
    $w = $ui.landing.ActualWidth; if ($w -lt 200) { $w = 1100 }
    $h = $ui.landing.ActualHeight; if ($h -lt 200) { $h = 720 }
    $rnd = New-Object System.Random
    for ($i = 0; $i -lt 6; $i++) {
        $size = 130 + $rnd.NextDouble() * 130
        $e = New-Object Windows.Shapes.Ellipse
        $e.Width = $size; $e.Height = $size
        $rg = New-Object Windows.Media.RadialGradientBrush
        [void]$rg.GradientStops.Add((New-Object Windows.Media.GradientStop -ArgumentList (Get-Color '#26FFFFFF'), 0.0))
        [void]$rg.GradientStops.Add((New-Object Windows.Media.GradientStop -ArgumentList (Get-Color '#00FFFFFF'), 1.0))
        $e.Fill = $rg
        [Windows.Controls.Canvas]::SetLeft($e, $rnd.NextDouble() * $w)
        [Windows.Controls.Canvas]::SetTop($e, $rnd.NextDouble() * $h)
        $tt = New-Object Windows.Media.TranslateTransform
        $e.RenderTransform = $tt
        [void]$c.Children.Add($e)
        Start-Forever $tt ([Windows.Media.TranslateTransform]::XProperty) (-30 - $rnd.NextDouble() * 50) (30 + $rnd.NextDouble() * 50) (9 + $rnd.NextDouble() * 8) $true 'Sine' ([int]($rnd.NextDouble() * 2000))
        Start-Forever $tt ([Windows.Media.TranslateTransform]::YProperty) (-24 - $rnd.NextDouble() * 40) (24 + $rnd.NextDouble() * 40) (11 + $rnd.NextDouble() * 8) $true 'Sine' ([int]($rnd.NextDouble() * 2000))
        Start-Forever $e ([Windows.UIElement]::OpacityProperty) 0.35 1 (5 + $rnd.NextDouble() * 4) $true 'Sine'
    }
}

function Start-Ripple {
    param($Pos)
    if (-not $script:AnimOn) { return }
    $c = $script:UI.particles
    $e = New-Object Windows.Shapes.Ellipse
    $e.Width = 40; $e.Height = 40
    $e.Stroke = Get-Brush '#FFFFFF'
    $e.StrokeThickness = 1.5
    $e.Opacity = 0.7
    $e.IsHitTestVisible = $false
    $e.RenderTransformOrigin = New-Object Windows.Point -ArgumentList 0.5, 0.5
    [Windows.Controls.Canvas]::SetLeft($e, $Pos.X - 20)
    [Windows.Controls.Canvas]::SetTop($e, $Pos.Y - 20)
    $st = New-Object Windows.Media.ScaleTransform
    $st.ScaleX = 0.2; $st.ScaleY = 0.2
    $e.RenderTransform = $st
    [void]$c.Children.Add($e)
    $ease = New-Ease 'Cubic' 'EaseOut'
    $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim 0.2 4 750 0 $ease))
    $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim 0.2 4 750 0 $ease))
    $e.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-DAnim 0.7 0 750))
    $script:Ripples.Enqueue($e)
    while ($script:Ripples.Count -gt 6) { $old = $script:Ripples.Dequeue(); $c.Children.Remove($old) }
}

function Invoke-Parallax {
    param($Pos)
    if (-not $script:AnimOn) { return }
    $now = [Environment]::TickCount
    if (($now - $script:ParLast) -lt 40) { return }
    $script:ParLast = $now
    $ui = $script:UI
    $w = [math]::Max(1.0, $ui.landing.ActualWidth); $h = [math]::Max(1.0, $ui.landing.ActualHeight)
    $nx = ($Pos.X / $w) - 0.5; $ny = ($Pos.Y / $h) - 0.5
    $xp = [Windows.Media.TranslateTransform]::XProperty; $yp = [Windows.Media.TranslateTransform]::YProperty
    $ui.parBokeh.BeginAnimation($xp, (New-DAnim $ui.parBokeh.X (-$nx * 36) 280))
    $ui.parBokeh.BeginAnimation($yp, (New-DAnim $ui.parBokeh.Y (-$ny * 26) 280))
    $ui.parPart.BeginAnimation($xp, (New-DAnim $ui.parPart.X (-$nx * 16) 280))
    $ui.parPart.BeginAnimation($yp, (New-DAnim $ui.parPart.Y (-$ny * 12) 280))
}

function Get-TierRu {
    param([string]$Tier)
    switch ($Tier) { 'Safe' { return 'Безопасно' } 'Test' { return 'Проверить' } 'Advanced' { return 'Расширенно' } default { return 'Опционально' } }
}

function Get-GainRu {
    param([string]$G)
    switch ($G) {
        'FPS' { return 'FPS' } 'Lows' { return '1% low' } 'Latency' { return 'Задержка' } 'Ping' { return 'Пинг' }
        'Stability' { return 'Стабильность' } 'Background' { return 'Фон' } 'Comfort' { return 'Комфорт' } default { return $G }
    }
}

# --- OTC OPTI: nove animace uvodni obrazovky ---------------------------------------
function Start-OtcAmbient {
    $ui = $script:UI
    if (-not $script:AnimOn) { return }
    $sx = [Windows.Media.ScaleTransform]::ScaleXProperty
    $sy = [Windows.Media.ScaleTransform]::ScaleYProperty
    $op = [Windows.UIElement]::OpacityProperty

    # 1) dva pulzujici kruhy se rozbihaji od loga
    foreach ($p in @(@($ui.pulseAS, $ui.pulseA, 0), @($ui.pulseBS, $ui.pulseB, 1400))) {
        if (-not $p[0] -or -not $p[1]) { continue }
        Start-Forever $p[0] $sx 1 2.4 2.8 $false 'Sine' $p[2]
        Start-Forever $p[0] $sy 1 2.4 2.8 $false 'Sine' $p[2]
        Start-Forever $p[1] $op 0.55 0 2.8 $false 'Sine' $p[2]
    }

    # 2) svisla svetla cara pravidelne projede celou obrazovkou
    if ($ui.scanLine -and $ui.scanT) {
        $w = [math]::Max(700.0, [double]$ui.landing.ActualWidth)
        $ui.scanLine.Opacity = 1
        $ka = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        $ka.Duration = Get-Dur 7500
        $ka.BeginTime = Get-Span 3400
        $ka.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        foreach ($kf in @(@(-10, 0), @($w, 3400), @($w, 7500))) {
            $f = New-Object Windows.Media.Animation.EasingDoubleKeyFrame
            $f.Value = [double]$kf[0]
            $f.KeyTime = [Windows.Media.Animation.KeyTime]::FromTimeSpan((Get-Span $kf[1]))
            $f.EasingFunction = New-Ease 'Cubic' 'EaseInOut'
            [void]$ka.KeyFrames.Add($f)
        }
        $ui.scanT.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $ka)
    }

    # 3) pismena O-T-C se postupne na okamzik ztlumi (vlna)
    $k = 0
    foreach ($l in @($ui.lnTitle.Children)) {
        if ($l.Foreground -isnot [Windows.Media.SolidColorBrush]) { $k++; continue }
        $ca = New-Object Windows.Media.Animation.ColorAnimationUsingKeyFrames
        $ca.Duration = Get-Dur 6000
        $ca.BeginTime = Get-Span (4200 + $k * 140)
        $ca.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        foreach ($kf in @(@('#F4F4F4', 0), @('#5E5E5E', 220), @('#FFFFFF', 560), @('#F4F4F4', 900), @('#F4F4F4', 6000))) {
            $f = New-Object Windows.Media.Animation.LinearColorKeyFrame
            $f.Value = Get-Color $kf[0]
            $f.KeyTime = [Windows.Media.Animation.KeyTime]::FromTimeSpan((Get-Span $kf[1]))
            [void]$ca.KeyFrames.Add($f)
        }
        try { $l.Foreground.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca) } catch { }
        $k++
    }
}

function Start-LandingAmbient {
    $ui = $script:UI
    if (-not $script:AnimOn) { $ui.lnUnder.Width = 120; return }
    $ang = [Windows.Media.RotateTransform]::AngleProperty
    Start-Forever $ui.orbit1Rot $ang 0 360 6 $false
    Start-Forever $ui.orbit2Rot $ang 360 0 9.5 $false
    Start-Forever $ui.ring2Rot $ang 360 0 34 $false
    # the bolt flickers every few seconds
    $ka = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $ka.Duration = Get-Dur 5200
    $ka.BeginTime = Get-Span 3000
    $ka.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    foreach ($kf in @(@(1, 0), @(1, 0.7), @(0.3, 0.75), @(1, 0.81), @(0.6, 0.88), @(1, 0.95), @(1, 1))) {
        $f = New-Object Windows.Media.Animation.LinearDoubleKeyFrame
        $f.Value = [double]$kf[0]
        $f.KeyTime = [Windows.Media.Animation.KeyTime]::FromPercent([double]$kf[1])
        [void]$ka.KeyFrames.Add($f)
    }
    $ui.logoBolt.BeginAnimation([Windows.UIElement]::OpacityProperty, $ka)
    # the enter button breathes
    $fx = New-Object Windows.Media.Effects.DropShadowEffect
    $fx.Color = Get-Color '#FFFFFF'; $fx.ShadowDepth = 0; $fx.Opacity = 0.55; $fx.BlurRadius = 8
    $ui.btnEnter.Effect = $fx
    Start-Forever $fx ([Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty) 8 36 1.8 $true
    # chips bob gently, out of step with each other
    $i = 0
    foreach ($chip in @($ui.chipA, $ui.chipB, $ui.chipC)) {
        if ($chip.RenderTransform -is [Windows.Media.TranslateTransform]) { Start-Forever $chip.RenderTransform ([Windows.Media.TranslateTransform]::YProperty) 0 -4 (2.2 + $i * 0.35) $true 'Sine' 2700 }
        $i++
    }
    $ui.lnUnder.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-DAnim 0 120 700 1550 (New-Ease 'Cubic' 'EaseOut')))
    Start-OtcAmbient; Start-Bokeh
}

# ---- X3D pinning (dual-CCD V-Cache chips) --------------------------------------------------------------
function Set-VCacheAffinity {
    param($Proc)
    $F = $script:Facts
    if (-not $F.DualCcdX3D -or $F.Threads -lt 4) { return }
    $half = [int]($F.Threads / 2)
    $mask = [int64]([math]::Pow(2, $half) - 1)
    try {
        if ([int64]$Proc.ProcessorAffinity -ne $mask) {
            $Proc.ProcessorAffinity = [IntPtr]$mask
            $script:Session.PinnedPid = $Proc.Id
            Write-Log ("{0} pinned to the first CCD ({1} logical cores, the V-Cache side)." -f $Proc.ProcessName, $half) 'ok'
        }
    } catch { Write-Log "Could not pin the game: $($_.Exception.Message)" 'warn' }
}

function Reset-GameAffinity {
    $F = $script:Facts
    if (-not $script:Session.PinnedPid) { return }
    try {
        $p = Get-Process -Id $script:Session.PinnedPid -ErrorAction Stop
        $all = [int64]([math]::Pow(2, [math]::Min(62, [int]$F.Threads)) - 1)
        $p.ProcessorAffinity = [IntPtr]$all
    } catch { }
    $script:Session.PinnedPid = $null
}

# ---- non-blocking startup --------------------------------------------------------------------------------
function Start-Prepare {
    # The window is already on screen. The hardware scan runs in a worker so nothing freezes.
    $ui = $script:UI
    Set-EnterContent 'Подготовка...' $false
    $ui.btnEnter.IsEnabled = $false
    $work = "function Find-RustClient {`n" + (Get-Item -LiteralPath 'function:Find-RustClient').ScriptBlock.ToString() + "`n}`nfunction Get-SystemFacts {`n" + (Get-Item -LiteralPath 'function:Get-SystemFacts').ScriptBlock.ToString() + "`n}`nGet-SystemFacts"
    Invoke-Async -Work ([scriptblock]::Create($work)) -OnDone {
        param($res, $err)
        $f = $null
        try { $f = @($res)[0]; if ($f -is [System.Management.Automation.PSObject]) { $f = $f.BaseObject } } catch { }
        if ($f -isnot [hashtable]) {
            try { $f = Get-SystemFacts } catch { $f = @{ Build = [Environment]::OSVersion.Version.Build; Win11 = $false; OsName = 'Windows'; RamGB = 0; CpuName = 'Unknown CPU'; Cores = 0; Threads = 0; X3D = $false; DualCcdX3D = $false; Gpus = @(); Laptop = $false; RustExe = $null; RustHdd = $false } }
        }
        $script:Facts = $f
        try { Restore-OrphanedSession } catch { }
        Import-Journal
        $script:Tweaks = Get-TweakCatalog
        Initialize-PlusTweakIds
        try { $lr = Invoke-LicenseRevert; if ($lr -gt 0) { Write-Log "Тариф не разрешает часть активных оптимизаций; откачено: $lr." 'warn' } } catch { }
        $script:Ready = $true
        Set-LandingSys
        Set-EnterContent 'ВОЙТИ' $true
        $script:UI.btnEnter.IsEnabled = $true
        if ($script:Facts.DualCcdX3D) { $script:UI.sesPin.Visibility = 'Visible' }
        Write-Log "OTC OPTI $($script:Version) ready on $($script:Facts.OsName)." 'accent'
        Update-KeyButton
        Write-Log ("Discord: {0} (ID {1})" -f $env:OTC_DISCORD_NAME, $env:OTC_DISCORD_ID) 'info'
        if (Test-Premium) {
            $until = if ((Get-PremiumUntil) -ge 4294967295) { 'Навсегда' } else { [DateTimeOffset]::FromUnixTimeSeconds((Get-PremiumUntil)).ToLocalTime().ToString('dd.MM.yyyy HH:mm') }
            Write-Log ("{0} активен до {1}." -f (Get-LicenseTier), $until) 'ok'
        }
        else { Write-Log ("Бесплатная версия: доступно {0} оптимизаций; PLUS и ULTRA открывают дополнительные функции." -f $script:FreeIds.Count) 'info' }
    }
}

function Start-CloseAnim {
    $ui = $script:UI
    $a = New-DAnim 1 0 220 0 (New-Ease 'Quad' 'EaseIn')
    $a.Add_Completed({ $script:UI.Win.Close() })
    $fs = New-Object Windows.Media.ScaleTransform
    $ui.frame.RenderTransformOrigin = New-Object Windows.Point -ArgumentList 0.5, 0.5
    $ui.frame.RenderTransform = $fs
    $fs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim 1 0.97 220))
    $fs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim 1 0.97 220))
    $ui.Win.BeginAnimation([Windows.UIElement]::OpacityProperty, $a)
}

function Invoke-WindowDrag {
    $w = $script:UI.Win
    $op = [Windows.UIElement]::OpacityProperty
    if ($script:AnimOn) { $w.BeginAnimation($op, (New-DAnim $w.Opacity 0.92 120)) }
    try { $w.DragMove() } catch { }
    if ($script:AnimOn) {
        $a = New-DAnim 0.92 1 220
        $a.FillBehavior = 'Stop'
        $w.Opacity = 1
        $w.BeginAnimation($op, $a)
    } else { $w.Opacity = 1 }
}
# ---- settings (persisted between launches) ------------------------------------------------
$script:SettingsFile = Join-Path $script:AppDir 'settings.json'

function Get-Settings {
    $d = @{ Anim = $true; ColorBrightness = 0.0; ColorContrast = 100.0; ColorSaturation = 100.0; ColorExposure = 0.0; ColorGamma = 1.0 }
    try {
        if (Test-Path -LiteralPath $script:SettingsFile) {
            $j = ConvertFrom-Json (Get-Content -LiteralPath $script:SettingsFile -Raw)
            if ($null -ne $j.Anim) { $d.Anim = [bool]$j.Anim }
            foreach ($item in @(
                @{ Name = 'ColorBrightness'; Min = -35.0; Max = 35.0 },
                @{ Name = 'ColorContrast'; Min = 70.0; Max = 135.0 },
                @{ Name = 'ColorSaturation'; Min = 80.0; Max = 140.0 },
                @{ Name = 'ColorExposure'; Min = -1.5; Max = 1.5 },
                @{ Name = 'ColorGamma'; Min = 0.65; Max = 1.8 }
            )) {
                $value = 0.0
                if ($null -ne $j.($item.Name) -and
                    [double]::TryParse([string]$j.($item.Name), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and
                    -not [double]::IsNaN($value) -and -not [double]::IsInfinity($value) -and
                    $value -ge $item.Min -and $value -le $item.Max) {
                    $d[$item.Name] = $value
                }
            }
        }
    } catch { }
    return $d
}

function Save-Settings {
    $settings = @{
        Anim = [bool]$script:AnimOn
        ColorBrightness = [double]$script:ColorValues.Brightness
        ColorContrast = [double]$script:ColorValues.Contrast
        ColorSaturation = [double]$script:ColorValues.Saturation
        ColorExposure = [double]$script:ColorValues.Exposure
        ColorGamma = [double]$script:ColorValues.Gamma
    }
    Write-TextFile $script:SettingsFile (ConvertTo-Json -InputObject $settings -Compress)
}

function Restore-ColorRampFile {
    if (-not (Test-Path -LiteralPath $script:ColorRampRecoveryFile)) { return }
    $savedData = ConvertFrom-Json (Get-Content -LiteralPath $script:ColorRampRecoveryFile -Raw)
    if ($savedData -is [System.Management.Automation.PSCustomObject] -and
        $savedData.PSObject.Properties['value'] -and
        $savedData.PSObject.Properties['Count']) {
        $savedData = $savedData.value
    }
    $saved = @($savedData)
    if ($saved.Count -ne 768) { throw 'The saved display color recovery data is invalid.' }
    $ramp = New-Object 'System.UInt16[]' 768
    for ($i = 0; $i -lt 768; $i++) {
        $value = [uint16]0
        if (-not [uint16]::TryParse([string]$saved[$i], [ref]$value)) {
            throw 'The saved display color recovery data contains an invalid value.'
        }
        $ramp[$i] = $value
    }
    [RomNative]::SetDisplayGammaRamp($ramp)
    Remove-Item -LiteralPath $script:ColorRampRecoveryFile -Force
    $script:ColorOriginalRamp = $null
}

function Restore-ColorFilter {
    if ($null -eq $script:ColorOriginalRamp -and (Test-Path -LiteralPath $script:ColorRampRecoveryFile)) {
        Restore-ColorRampFile
        return $true
    }
    if ($null -eq $script:ColorOriginalRamp) { return $false }
    [RomNative]::SetDisplayGammaRamp($script:ColorOriginalRamp)
    if (Test-Path -LiteralPath $script:ColorRampRecoveryFile) {
        Remove-Item -LiteralPath $script:ColorRampRecoveryFile -Force
    }
    $script:ColorOriginalRamp = $null
    return $true
}

function New-ColorGammaRamp {
    param([uint16[]]$OriginalRamp, [hashtable]$Values)
    if ($OriginalRamp.Length -ne 768) { throw 'The original display gamma ramp is invalid.' }
    $brightness = [double]$Values.Brightness / 100.0
    $contrast = [double]$Values.Contrast / 100.0
    $saturation = [double]$Values.Saturation / 100.0
    $curvePower = 1.0 + (($saturation - 1.0) * 1.5)
    $exposure = [Math]::Pow(2.0, [double]$Values.Exposure)
    $gamma = [Math]::Max(0.1, [double]$Values.Gamma)
    $ramp = New-Object 'System.UInt16[]' 768
    for ($channel = 0; $channel -lt 3; $channel++) {
        for ($i = 0; $i -lt 256; $i++) {
            $index = $channel * 256 + $i
            $input = [double]$OriginalRamp[$index] / 65535.0
            $adjusted = [Math]::Max(0.0, [Math]::Min(1.0, (($input - 0.5) * $contrast + 0.5 + $brightness)))
            if ($adjusted -le 0.0) {
                $adjusted = 0.0
            } elseif ($adjusted -ge 1.0) {
                $adjusted = 1.0
            } else {
                $lower = [Math]::Pow($adjusted, $curvePower)
                $upper = [Math]::Pow(1.0 - $adjusted, $curvePower)
                $adjusted = $lower / ($lower + $upper)
            }
            $adjusted = [Math]::Max(0.0, [Math]::Min(1.0, ($adjusted * $exposure)))
            $adjusted = [Math]::Pow($adjusted, 1.0 / $gamma)
            $ramp[$index] = [uint16][Math]::Round($adjusted * 65535.0)
        }
    }
    return ,$ramp
}

function Apply-ColorFilter {
    if (-not (Test-Premium)) { throw 'Display color controls require an active PLUS or ULTRA license.' }
    if (-not $script:NativeOk) { throw 'Windows display color control is unavailable on this system.' }
    if (-not (Test-Ultra)) { $script:ColorValues.Saturation = 100.0 }
    if ($null -eq $script:ColorOriginalRamp) {
        $original = [RomNative]::ReadDisplayGammaRamp()
        Write-TextFile $script:ColorRampRecoveryFile (ConvertTo-Json -InputObject ([int[]]$original) -Compress)
        $script:ColorOriginalRamp = $original
    }
    $ramp = New-ColorGammaRamp $script:ColorOriginalRamp $script:ColorValues
    try {
        [RomNative]::SetDisplayGammaRamp($ramp)
    } catch {
        try { [void](Restore-ColorFilter) } catch {
            Write-Log "Display color recovery failed: $($_.Exception.Message)" 'err'
        }
        throw
    }
    Write-Log 'Applied the display color curve to the primary monitor.' 'ok'
}

function ColorSlider_ValueChanged {
    param($Sender, $EventArgs)
    if (-not $Sender -or -not $script:UI -or -not (Test-Premium)) { return }
    $value = [double]$Sender.Value
    if ([string]$Sender.Tag -eq 'Saturation' -and -not (Test-Ultra)) {
        $Sender.Value = 100
        $script:ColorValues.Saturation = 100.0
        return
    }
    switch ([string]$Sender.Tag) {
        'Brightness' { $script:ColorValues.Brightness = $value; $script:UI.txtColorBrightness.Text = $value.ToString('0') }
        'Contrast' { $script:ColorValues.Contrast = $value; $script:UI.txtColorContrast.Text = $value.ToString('0') }
        'Saturation' { $script:ColorValues.Saturation = $value; $script:UI.txtColorSaturation.Text = $value.ToString('0') }
        'Exposure' { $script:ColorValues.Exposure = $value; $script:UI.txtColorExposure.Text = $value.ToString('+0.00;-0.00;0.00') + ' EV' }
        'Gamma' { $script:ColorValues.Gamma = $value; $script:UI.txtColorGamma.Text = $value.ToString('0.00') }
        default { return }
    }
    Save-Settings
    $script:UI.txtColorStatus.Text = 'Настройки сохранены. Нажмите «Применить к дисплею», чтобы включить фильтр.'
    $script:UI.txtColorStatus.Foreground = Get-Res 'Muted'
}

function Initialize-ColorFilter {
    Restore-ColorRampFile
    $saved = Get-Settings
    $script:ColorValues = @{
        Brightness = [double]$saved.ColorBrightness
        Contrast = [double]$saved.ColorContrast
        Saturation = [double]$saved.ColorSaturation
        Exposure = [double]$saved.ColorExposure
        Gamma = [double]$saved.ColorGamma
    }
}

$script:ColorProfilesDir = Join-Path $env:APPDATA 'OtcLoader\color-profiles'

function Read-ColorProfile {
    param([string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -gt 32768) { throw 'The color profile is larger than the supported limit.' }
    $profile = ConvertFrom-Json ([IO.File]::ReadAllText($Path))
    if ([int]$profile.SchemaVersion -ne 1) { throw 'This color profile version is not supported.' }
    $name = ([string]$profile.Name).Trim()
    if (-not $name -or $name.Length -gt 48 -or $name -match '[\x00-\x1F]') {
        throw 'The color profile name is invalid.'
    }
    $values = @{}
    foreach ($item in @(
        @{ Name = 'Brightness'; Min = -35.0; Max = 35.0 },
        @{ Name = 'Contrast'; Min = 70.0; Max = 135.0 },
        @{ Name = 'Saturation'; Min = 80.0; Max = 140.0 },
        @{ Name = 'Exposure'; Min = -1.5; Max = 1.5 },
        @{ Name = 'Gamma'; Min = 0.65; Max = 1.8 }
    )) {
        $value = 0.0
        $profileValue = $profile.Values.($item.Name)
        if ($item.Name -eq 'Saturation' -and $null -eq $profileValue) { $profileValue = 100.0 }
        $raw = [Convert]::ToString($profileValue, [System.Globalization.CultureInfo]::InvariantCulture)
        if (-not [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or
            [double]::IsNaN($value) -or [double]::IsInfinity($value) -or
            $value -lt $item.Min -or $value -gt $item.Max) {
            throw "The $($item.Name) value in this profile is invalid."
        }
        $values[$item.Name] = $value
    }
    return @{ Name = $name; Values = $values }
}

function Update-ColorProfiles {
    if (-not $script:UI -or -not $script:UI.cmbColorProfiles) { return }
    [void][IO.Directory]::CreateDirectory($script:ColorProfilesDir)
    $combo = $script:UI.cmbColorProfiles
    $previous = $null
    if ($combo.SelectedItem) { $previous = [string]$combo.SelectedItem.Tag }
    $combo.Items.Clear()
    $badProfiles = 0
    foreach ($path in [IO.Directory]::GetFiles($script:ColorProfilesDir, '*.json')) {
        try {
            $profile = Read-ColorProfile $path
            $item = New-Object Windows.Controls.ComboBoxItem
            $item.Content = $profile.Name
            $item.Tag = $path
            [void]$combo.Items.Add($item)
            if ($previous -and [string]::Equals($previous, $path, [StringComparison]::OrdinalIgnoreCase)) {
                $combo.SelectedItem = $item
            }
        } catch {
            $badProfiles++
            Write-Log "Color profile '$([IO.Path]::GetFileName($path))' could not be loaded: $($_.Exception.Message)" 'warn'
        }
    }
    if ($badProfiles -gt 0) {
        $script:UI.txtColorProfileStatus.Text = "$badProfiles конфиг(а) повреждено или имеют неподдерживаемый формат; подробности в журнале."
        $script:UI.txtColorProfileStatus.Foreground = Get-Res 'Warn'
    } elseif ($combo.Items.Count -eq 0) {
        $script:UI.txtColorProfileStatus.Text = 'Пока нет сохранённых конфигов.'
        $script:UI.txtColorProfileStatus.Foreground = Get-Res 'Muted'
    } else {
        $script:UI.txtColorProfileStatus.Text = "Сохранено конфигов: $($combo.Items.Count)."
        $script:UI.txtColorProfileStatus.Foreground = Get-Res 'Muted'
    }
}

function Read-ColorProfileName {
    $w = New-Object Windows.Window
    $w.Title = 'Новый цветовой конфиг'
    $w.Width = 390
    $w.Height = 170
    $w.ResizeMode = 'NoResize'
    $w.WindowStartupLocation = 'CenterOwner'
    try { $w.Owner = $script:UI.Win } catch { }
    try { $w.Background = Get-Res 'Bg1' } catch { }
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = '18'
    [void]$panel.Children.Add((New-Tb 'Название конфига (до 48 символов):' 12 'Text'))
    $nameBox = New-Object Windows.Controls.TextBox
    $nameBox.Margin = '0,10,0,14'
    $nameBox.Padding = '7'
    [void]$panel.Children.Add($nameBox)
    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    $ok = New-Object Windows.Controls.Button
    $ok.Content = 'Сохранить'
    $ok.Padding = '14,6'
    $ok.Margin = '0,0,8,0'
    $ok.IsDefault = $true
    $cancel = New-Object Windows.Controls.Button
    $cancel.Content = 'Отмена'
    $cancel.Padding = '14,6'
    $cancel.IsCancel = $true
    [void]$buttons.Children.Add($ok)
    [void]$buttons.Children.Add($cancel)
    [void]$panel.Children.Add($buttons)
    $w.Content = $panel
    $script:ColorProfileNameResult = $null
    $ok.Add_Click({
        $script:ColorProfileNameResult = [string]$nameBox.Text
        $w.DialogResult = $true
    }.GetNewClosure())
    $w.Add_ContentRendered({ $nameBox.Focus() | Out-Null }.GetNewClosure())
    [void]$w.ShowDialog()
    return $script:ColorProfileNameResult
}

function Save-ColorProfile {
    if (-not (Test-Premium)) { throw 'Color profiles require an active PLUS or ULTRA license.' }
    $name = Read-ColorProfileName
    if ($null -eq $name) { return }
    $name = $name.Trim()
    if (-not $name -or $name.Length -gt 48 -or $name -match '[\x00-\x1F]') {
        throw 'Use a config name of 1–48 characters without control characters.'
    }
    [void][IO.Directory]::CreateDirectory($script:ColorProfilesDir)
    foreach ($path in [IO.Directory]::GetFiles($script:ColorProfilesDir, '*.json')) {
        $existing = Read-ColorProfile $path
        if ([string]::Equals($existing.Name, $name, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'A color config with this name already exists.'
        }
    }
    $profile = @{
        SchemaVersion = 1
        Name = $name
        Values = @{
            Brightness = [double]$script:ColorValues.Brightness
            Contrast = [double]$script:ColorValues.Contrast
            Saturation = if (Test-Ultra) { [double]$script:ColorValues.Saturation } else { 100.0 }
            Exposure = [double]$script:ColorValues.Exposure
            Gamma = [double]$script:ColorValues.Gamma
        }
    }
    $path = Join-Path $script:ColorProfilesDir ("{0}.json" -f [Guid]::NewGuid().ToString('N'))
    Write-TextFile $path (ConvertTo-Json -InputObject $profile -Depth 4 -Compress)
    Update-ColorProfiles
    foreach ($item in $script:UI.cmbColorProfiles.Items) {
        if ([string]::Equals([string]$item.Tag, $path, [StringComparison]::OrdinalIgnoreCase)) {
            $script:UI.cmbColorProfiles.SelectedItem = $item
            break
        }
    }
    $script:UI.txtColorProfileStatus.Text = "Конфиг «$name» сохранён."
    $script:UI.txtColorProfileStatus.Foreground = Get-Res 'Good'
    Write-Log "Color profile '$name' saved." 'ok'
}

function Load-ColorProfile {
    if (-not (Test-Premium)) { throw 'Color profiles require an active PLUS or ULTRA license.' }
    $item = $script:UI.cmbColorProfiles.SelectedItem
    if (-not $item) { throw 'Сначала выберите цветовой конфиг.' }
    $profile = Read-ColorProfile ([string]$item.Tag)
    $script:ColorValues = $profile.Values
    if (-not (Test-Ultra)) { $script:ColorValues.Saturation = 100.0 }
    $script:UI.slColorBrightness.Value = [double]$script:ColorValues.Brightness
    $script:UI.slColorContrast.Value = [double]$script:ColorValues.Contrast
    $script:UI.slColorSaturation.Value = [double]$script:ColorValues.Saturation
    $script:UI.slColorExposure.Value = [double]$script:ColorValues.Exposure
    $script:UI.slColorGamma.Value = [double]$script:ColorValues.Gamma
    Save-Settings
    $script:UI.txtColorProfileStatus.Text = "Загружен конфиг «$($profile.Name)». Нажмите «Применить к дисплею», чтобы включить фильтр."
    $script:UI.txtColorProfileStatus.Foreground = Get-Res 'Good'
    Write-Log "Color profile '$($profile.Name)' loaded." 'ok'
}

function Remove-ColorProfile {
    if (-not (Test-Premium)) { throw 'Color profiles require an active PLUS or ULTRA license.' }
    $item = $script:UI.cmbColorProfiles.SelectedItem
    if (-not $item) { throw 'Сначала выберите цветовой конфиг.' }
    $profile = Read-ColorProfile ([string]$item.Tag)
    $answer = [Windows.MessageBox]::Show("Удалить конфиг «$($profile.Name)»?", 'Цветовые конфиги', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Remove-Item -LiteralPath ([string]$item.Tag) -Force -ErrorAction Stop
    Update-ColorProfiles
    $script:UI.txtColorProfileStatus.Text = "Конфиг «$($profile.Name)» удалён."
    $script:UI.txtColorProfileStatus.Foreground = Get-Res 'Good'
    Write-Log "Color profile '$($profile.Name)' deleted." 'info'
}

function Start-ColorPageAnimations {
    param([switch]$Stop)
    if (-not $script:UI) { return }
    if ($script:AnimOn -and -not $Stop -and $script:UI.navColor.IsChecked) {
        Start-Forever $script:UI.colorRingRot ([Windows.Media.RotateTransform]::AngleProperty) 0 360 22 $false
        Start-Forever $script:UI.colorAccentLine ([Windows.UIElement]::OpacityProperty) 0.55 1 1.8 $true
    } else {
        Stop-Anim $script:UI.colorRingRot ([Windows.Media.RotateTransform]::AngleProperty)
        Stop-Anim $script:UI.colorAccentLine ([Windows.UIElement]::OpacityProperty)
        $script:UI.colorAccentLine.Opacity = 0.85
    }
}

function Start-RustHoloAnimation {
    if (-not $script:UI -or -not $script:UI.chkRustHolo.IsChecked -or -not $script:AnimOn -or -not $script:UI.navRust.IsChecked) {
        if ($script:UI) { Stop-Anim $script:UI.rustHoloRingRot ([Windows.Media.RotateTransform]::AngleProperty) }
        return
    }
    Start-Forever $script:UI.rustHoloRingRot ([Windows.Media.RotateTransform]::AngleProperty) 0 360 18 $false
}

# ---- safety tiers ------------------------------------------------------------------------------
# Safe      applied by "Оптимизировать ПК"
# Test      helps some PCs and hurts others, always opt-in, measure it
# Advanced  real security or stability tradeoff, always opt-in
# Optional  preferences and situational tweaks
$script:SecurityIds = @('rust_defender', 'adv_vbs', 'sch_hyper', 'sch_mitig')
$script:TestTierIds = @('sch_hags', 'gpu_fsegl', 'gpu_fso', 'gpu_mpo', 'sch_memcomp', 'gpu_tdr', 'net_lat')

function Get-TweakTier {
    param($T)
    if ($T.Group -eq 'Adv') { return 'Advanced' }
    if ($script:TestTierIds -contains $T.Id) { return 'Test' }
    $rec = $false
    try { $rec = Test-TweakRecommended $T } catch { }
    if ($rec) { return 'Safe' }
    return 'Optional'
}

function Initialize-PlusTweakIds {
    $freeCount = @($script:Tweaks | Where-Object { $script:FreeIds -contains [string]$_.Id }).Count
    $target = [Math]::Max(0, ([int][Math]::Ceiling($script:Tweaks.Count * 0.55) - $freeCount))
    $candidates = @($script:Tweaks | Where-Object {
        $script:FreeIds -notcontains [string]$_.Id -and
        $script:SecurityIds -notcontains [string]$_.Id -and
        $script:TestTierIds -notcontains [string]$_.Id -and
        $_.Group -ne 'Adv' -and
        [int]$_.Impact -lt 3
    } | Sort-Object @{ Expression = { [int]$_.Impact }; Ascending = $true }, @{ Expression = { [string]$_.Id }; Ascending = $true })
    $script:PlusTweakIds = @($candidates | Select-Object -First $target | ForEach-Object { [string]$_.Id })
}

function Get-TweakRequiredTier {
    param($T)
    if ($script:FreeIds -contains [string]$T.Id) { return 'FREE' }
    if ($script:PlusTweakIds -contains [string]$T.Id) { return 'PLUS' }
    return 'ULTRA'
}

function Get-TierBrush {
    param([string]$Tier)
    switch ($Tier) { 'Safe' { return 'Good' } 'Test' { return 'Warn' } 'Advanced' { return 'Bad' } default { return 'Dim' } }
}

$script:OptFilter = 'All'
$script:OptSearch = ''

function Update-OptFilter {
    $ui = $script:UI
    $hdr = $null; $cnt = 0
    $q = $script:OptSearch
    foreach ($ch in @($ui.pnlTweaks.Children)) {
        if ($ch.Tag -eq 'hdr') {
            if ($hdr) { $hdr.Visibility = $(if ($cnt -gt 0) { 'Visible' } else { 'Collapsed' }) }
            $hdr = $ch; $cnt = 0; continue
        }
        $c = $script:Cards[[string]$ch.Tag]
        if (-not $c) { continue }
        $show = ($script:OptFilter -eq 'All' -or $c.Tier -eq $script:OptFilter)
        if ($show -and $q) { $show = ((($c.Tweak.Name + ' ' + $c.Tweak.Desc).IndexOf($q, [StringComparison]::OrdinalIgnoreCase)) -ge 0) }
        $ch.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
        if ($show) { $cnt++ }
    }
    if ($hdr) { $hdr.Visibility = $(if ($cnt -gt 0) { 'Visible' } else { 'Collapsed' }) }
}

function Update-FilterCounts {
    $ui = $script:UI
    $n = @{ Safe = 0; Test = 0; Advanced = 0; Optional = 0 }
    foreach ($c in $script:Cards.Values) { $n[$c.Tier]++ }
    $ui.fAll.Content = "Все ($($script:Cards.Count))"
    $ui.fSafe.Content = "Безопасные ($($n.Safe))"
    $ui.fTest.Content = "Проверить ($($n.Test))"
    $ui.fAdv.Content = "Расширенные ($($n.Advanced))"
    $ui.fOpt.Content = "Опционально ($($n.Optional))"
}

# ---- one-click optimize + what changed ---------------------------------------------------------------
$script:LastRun = @{ Apply = $true; Ok = @(); Fail = @() }

function Show-ChangeSummary {
    param([int]$Already, [int]$Available, [int]$Skipped)
    $ui = $script:UI
    $ok = @($script:LastRun.Ok); $fail = @($script:LastRun.Fail)
    $tick = [string][char]0x2713; $dot = [string][char]0x2022
    $ui.dChanges.Visibility = 'Visible'
    $ui.dChangesTitle.Text = if ($ok.Count -gt 0) { "$($ok.Count) change(s) applied" } else { 'Nothing needed changing' }
    $parts = @("$Already already optimal", "$Available optional tweak(s) available (Test it, Advanced, Optional)")
    if ($Skipped -gt 0) { $parts += "$Skipped recommended tweak(s) skipped because they do not fit this PC" }
    if ($fail.Count -gt 0) { $parts += "$($fail.Count) failed, see the Activity log" }
    $ui.dChangesSub.Text = ($parts -join "   $dot   ")
    $ui.pnlChanges.Children.Clear()
    foreach ($grp in $script:Groups) {
        $mine = @($ok | Where-Object { $_.Group -eq $grp.Key })
        if ($mine.Count -eq 0) { continue }
        $h = New-Tb $grp.Title 11 'Dim' $true
        $h.Margin = '0,8,0,3'
        [void]$ui.pnlChanges.Children.Add($h)
        foreach ($t in $mine) { [void]$ui.pnlChanges.Children.Add((New-Tb ("$tick  " + $t.Name) 12.5 'Text')) }
    }
    foreach ($t in $fail) { [void]$ui.pnlChanges.Children.Add((New-Tb ("!  " + $t.Name + " (failed)") 12.5 'Bad')) }
    Start-FadeSlide $ui.dChanges 0 12 0 360
    Show-Toast $ui.dChangesTitle.Text $(if ($fail.Count -gt 0) { 'warn' } else { 'ok' })
    Start-Stagger $ui.pnlChanges 24 24 120 6
}

function Invoke-OptimizeAll {
    foreach ($c in $script:Cards.Values) { $c.Switch.IsChecked = $false }
    $n = 0; $already = 0; $skipped = 0; $available = 0
    foreach ($id in $script:Cards.Keys) {
        $c = $script:Cards[$id]
        $rec = $false
        try { $rec = Test-TweakRecommended $c.Tweak } catch { }
        if ($c.Blocked) { if ($rec) { $skipped++ }; continue }
        if ($c.Tier -eq 'Safe') {
            if ($c.Applied) { $already++ } else { $c.Switch.IsChecked = $true; $n++ }
        } elseif (-not $c.Applied) { $available++ }
    }
    if ($n -eq 0) {
        Write-Log 'Оптимизация ПК: все безопасные твики уже применены.' 'ok'
        $script:LastRun = @{ Apply = $true; Ok = @(); Fail = @() }
    } else {
        Write-Log "Оптимизация ПК: применяю безопасных твиков: $n..." 'accent'
        Invoke-OptRun $true
    }
    Show-ChangeSummary $already $available $skipped
}

# ---- internet page -------------------------------------------------------------------------------------
$script:NetBusy = $false

function Set-Tb {
    param($Tb, [string]$Text, [string]$Brush = 'Text')
    $Tb.Text = $Text
    $Tb.Foreground = Get-Res $Brush
}

function Update-NetPage {
    $ui = $script:UI
    $info = Get-NetPrimaryBg
    if ($info) {
        Set-Tb $ui.nAdapter $info.Desc
        Set-Tb $ui.nType $info.Type
        Set-Tb $ui.nSpeed $info.Speed
        Set-Tb $ui.nIp $info.Ip
        Set-Tb $ui.nGw $info.Gateway
        Set-Tb $ui.nDnsSrv $(if (@($info.Dns).Count -gt 0) { @($info.Dns) -join ', ' } else { 'Automatic' })
        Set-Tb $ui.nMtu "$($info.Mtu)"
    } else {
        foreach ($n in 'nAdapter', 'nType', 'nSpeed', 'nIp', 'nGw', 'nDnsSrv', 'nMtu') { Set-Tb $ui[$n] 'No active connection' 'Dim' }
    }
    try {
        $s = Get-TcpStateBg
        Set-Tb $ui.tAuto $s.AutoTuning; Set-Tb $ui.tHeur $s.Heuristics; Set-Tb $ui.tEcn $s.Ecn
        Set-Tb $ui.tTs $s.Timestamps; Set-Tb $ui.tRss $s.Rss; Set-Tb $ui.tRsc $s.Rsc
        $ui.txtTcpStatus.Text = $(if (Get-NetBaseline) { 'Baseline saved. Windows default restores your original settings.' } else { 'No baseline yet. It is saved automatically right before the first change.' })
    } catch {
        foreach ($n in 'tAuto', 'tHeur', 'tEcn', 'tTs', 'tRss', 'tRsc') { Set-Tb $ui[$n] 'Not available' 'Dim' }
        $ui.txtTcpStatus.Text = 'TCP settings could not be read on this system.'
    }
}

function Set-NetBusy {
    param([bool]$Busy)
    $script:NetBusy = $Busy
    foreach ($b in 'btnNetTest', 'btnTcpGaming', 'btnTcpThroughput', 'btnTcpDefault', 'btnMtu', 'btnDns') { $script:UI[$b].IsEnabled = -not $Busy }
    $script:UI.navPanel.IsEnabled = -not $Busy
    Set-Spinner $Busy
}

function Set-Latency {
    param($Tb, $Stats, [int]$Good = 30, [int]$Warn = 80)
    if ($Stats.Lost -ge $Stats.Sent) { Set-Tb $Tb 'No reply (the device may block ping)' 'Warn'; return }
    $brush = if ($Stats.Avg -le $Good) { 'Good' } elseif ($Stats.Avg -le $Warn) { 'Warn' } else { 'Bad' }
    Set-Tb $Tb ("{0} ms average  ({1} to {2} ms)" -f $Stats.Avg, $Stats.Min, $Stats.Max) $brush
}

function Start-NetTest {
    if ($script:NetBusy) { return }
    $ui = $script:UI
    Set-NetBusy $true
    Start-Forever $ui.btnNetTest ([Windows.UIElement]::OpacityProperty) 1 0.55 0.5 $true
    try {
        $info = Get-NetPrimaryBg
        if (-not $info) { Set-Tb $ui.hGw 'No active connection' 'Warn'; return }
        foreach ($n in 'hGw', 'hWan', 'hLoss', 'hJit', 'hDns') { Set-Tb $ui[$n] 'testing...' 'Dim' }
        Invoke-UiPump
        $g = Test-PingStats $info.Gateway 12 1000 -Pump
        Set-Latency $ui.hGw $g 5 20
        $w = Test-PingStats '1.1.1.1' 12 1000 -Pump
        Set-Latency $ui.hWan $w 30 80
        $loss = [math]::Round(100.0 * $w.Lost / [math]::Max(1, $w.Sent), 1)
        Set-Tb $ui.hLoss "$loss%" $(if ($loss -eq 0) { 'Good' } elseif ($loss -lt 3) { 'Warn' } else { 'Bad' })
        Set-Tb $ui.hJit "$($w.Jitter) ms" $(if ($w.Jitter -le 3) { 'Good' } elseif ($w.Jitter -le 10) { 'Warn' } else { 'Bad' })
        $ms = @(Invoke-Blocking -Script { $sw = [System.Diagnostics.Stopwatch]::StartNew(); try { [void](Resolve-DnsName -Name 'www.google.com' -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop); [math]::Round($sw.Elapsed.TotalMilliseconds, 0) } catch { -1 } })[0]
        if ($ms -lt 0) { Set-Tb $ui.hDns 'Lookup failed' 'Bad' } else { Set-Tb $ui.hDns "$ms ms" $(if ($ms -le 60) { 'Good' } elseif ($ms -le 200) { 'Warn' } else { 'Bad' }) }
        Write-Log ("Network test: router {0} ms, internet {1} ms, loss {2}%, jitter {3} ms." -f $g.Avg, $w.Avg, $loss, $w.Jitter) 'info'
        foreach ($n in 'hGw', 'hWan', 'hLoss', 'hJit', 'hDns') { Start-Pop $ui[$n] 0 0.92 260 }
    } finally { Stop-Anim $ui.btnNetTest ([Windows.UIElement]::OpacityProperty); $ui.btnNetTest.Opacity = 1; Set-NetBusy $false }
}

function Start-TcpProfile {
    param([string]$Profile)
    if ($script:NetBusy) { return }
    $ui = $script:UI
    Set-NetBusy $true
    try {
        $ui.txtTcpStatus.Text = 'Applying and re-testing your connection...'
        Invoke-UiPump
        $r = Invoke-TcpProfile $Profile ([bool]$ui.swNetRollback.IsChecked) -Pump
        if ($r.Changes.Count -eq 0) {
            $ui.txtTcpStatus.Text = 'Already set that way. Nothing changed.'
            $ui.txtTcpStatus.Foreground = Get-Res 'Muted'
        } elseif ($r.RolledBack) {
            $ui.txtTcpStatus.Text = ("Connectivity got worse after the change (loss {0}/{1} vs {2}/{3} before), so it was rolled back automatically." -f $r.Post.Lost, $r.Post.Sent, $r.Pre.Lost, $r.Pre.Sent)
            $ui.txtTcpStatus.Foreground = Get-Res 'Warn'
            Write-Log 'TCP profile rolled back: connectivity test got worse.' 'warn'
            Show-Toast 'Rolled back: connection got worse' 'warn'
        } else {
            $ui.txtTcpStatus.Text = 'Applied: ' + ($r.Changes -join '; ')
            $ui.txtTcpStatus.Foreground = Get-Res 'Good'
            foreach ($c in $r.Changes) { Write-Log "TCP: $c" 'ok' }
            Show-Toast 'TCP profile applied' 'ok'
        }
        Start-Pop $ui.txtTcpStatus 0 0.96 300
    } catch {
        $ui.txtTcpStatus.Text = "Failed: $($_.Exception.Message)"
        $ui.txtTcpStatus.Foreground = Get-Res 'Bad'
        Write-Log "TCP profile failed: $($_.Exception.Message)" 'err'
    } finally {
        Set-NetBusy $false
        Update-NetPage
    }
}

function Start-MtuTest {
    if ($script:NetBusy) { return }
    $ui = $script:UI
    Set-NetBusy $true
    try {
        $ui.txtMtu.Text = 'Testing...'; Invoke-UiPump
        $m = Find-PathMtu '1.1.1.1' -Pump
        $info = Get-NetPrimaryBg
        if (-not $m) { Set-Tb $ui.txtMtu 'Could not test. The path blocks ping or you are offline.' 'Warn'; return }
        $cur = if ($info) { $info.Mtu } else { 0 }
        if ($m -ge 1500 -or $m -ge $cur) { Set-Tb $ui.txtMtu "Detected path MTU: $m. No change recommended." 'Good' }
        else { Set-Tb $ui.txtMtu "Detected path MTU: $m (adapter is set to $cur). This usually means PPPoE or a tunnel. Windows normally adapts on its own, so only change it if you see fragmentation problems." 'Warn' }
        Write-Log "MTU detected: $m." 'info'
    } finally { Set-NetBusy $false }
}

function Start-DnsTest {
    if ($script:NetBusy) { return }
    $ui = $script:UI
    Set-NetBusy $true
    try {
        $ui.txtDns.Text = 'Testing...'; Invoke-UiPump
        $info = Get-NetPrimaryBg
        $servers = @()
        if ($info -and @($info.Dns).Count -gt 0) { $servers += $info.Dns[0] } elseif ($info) { $servers += $info.Gateway }
        $servers += '1.1.1.1', '8.8.8.8', '9.9.9.9'
        $rows = @(Invoke-Blocking -Functions 'Test-DnsServers' -ArgList @(,$servers) -Script { param($s) Test-DnsServers $s })
        $lines = foreach ($r in $rows) {
            $label = if ($info -and $r.Server -eq $servers[0]) { "$($r.Server) (yours)" } else { $r.Server }
            $val = if ($r.Avg -lt 0) { 'failed' } else { "$($r.Avg) ms" }
            if ($r.Failed -gt 0 -and $r.Avg -ge 0) { $val += "  ($($r.Failed) lookup(s) failed)" }
            ('{0,-24}{1}' -f $label, $val)
        }
        $ui.txtDns.Text = ($lines -join "`n")
        Write-Log 'DNS test finished.' 'info'
    } finally { Set-NetBusy $false }
}

# ---- restore and profiles ---------------------------------------------------------------------------------
function Invoke-RevertAll {
    $ui = $script:UI
    $ans = [Windows.MessageBox]::Show('Отменить все твики, применённые этим приложением, и вернуть исходные значения?', 'OTC OPTI', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    $ids = @($script:Journal.Keys)
    $ok = 0; $fail = 0; $explorer = $false
    foreach ($id in $ids) {
        $t = @($script:Tweaks | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
        if (-not $t) { Write-Log "Journal entry '$id' is not in this version's catalog, skipped." 'warn'; continue }
        try { Invoke-TweakUndo $t; $ok++; if ($t.Explorer) { $explorer = $true }; Write-Log "Откачено: $($t.Name)" 'accent' }
        catch { $fail++; Write-Log "FAILED to revert $($t.Name): $($_.Exception.Message)" 'err' }
        Invoke-UiPump
    }
    try { $b = Get-NetBaseline; if ($b) { Set-TcpStateBg $b; Write-Log 'TCP settings restored to your baseline.' 'accent' } } catch { Write-Log "TCP restore failed: $($_.Exception.Message)" 'err' }
    if ($explorer) { Restart-ExplorerShell }
    Update-AllCards
    $ui.txtRestoreStatus.Text = "Reverted $ok tweak(s), $fail failed."
    $ui.txtRestoreStatus.Foreground = Get-Res $(if ($fail -gt 0) { 'Warn' } else { 'Good' })
}

function Invoke-ExportProfile {
    $dir = [Environment]::GetFolderPath('Desktop')
    $path = Join-Path $dir ("OTCOpti-Profile-{0}.json" -f (Get-Date -Format 'yyyy-MM-dd'))
    Export-OptProfile $path
    $script:UI.txtRestoreStatus.Text = "Profile saved to $path"
    $script:UI.txtRestoreStatus.Foreground = Get-Res 'Good'
    Write-Log "Profile exported to $path" 'ok'
    Show-Toast 'Профиль сохранён на рабочий стол' 'ok'
}

function Invoke-ImportProfile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Профиль OTC OPTI (*.json)|*.json'
    if (-not $dlg.ShowDialog()) { return }
    $ids = @(Import-OptProfile $dlg.FileName)
    $n = 0
    foreach ($c in $script:Cards.Values) { $c.Switch.IsChecked = $false }
    foreach ($id in $ids) {
        $c = $script:Cards[[string]$id]
        if ($c -and -not $c.Blocked -and -not $c.Applied) { $c.Switch.IsChecked = $true; $n++ }
    }
    Write-Log "Profile loaded: $n tweak(s) selected for review." 'ok'
    $script:UI.navOpt.IsChecked = $true
}

# ---- events for the new pages ------------------------------------------------------------------------------
function Register-ExtraEvents {
    $ui = $script:UI
    $ui.btnOptimizeAll.Add_Click({ Invoke-Safe { Invoke-OptimizeAll } 'Оптимизировать ПК' })

    $filters = @{ fAll = 'All'; fSafe = 'Safe'; fTest = 'Test'; fAdv = 'Advanced'; fOpt = 'Optional' }
    foreach ($n in $filters.Keys) {
        $ui[$n].Tag = $filters[$n]
        $ui[$n].Add_Checked({ param($s, $e) $script:OptFilter = [string]$s.Tag; Start-Pop $s 0 0.85 260; Update-OptFilter })
    }
    $ui.txtSearch.Add_GotKeyboardFocus({ if ($script:AnimOn) { $script:UI.txtSearch.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-DAnim $script:UI.txtSearch.ActualWidth 300 220 0 (New-Ease 'Cubic' 'EaseOut'))) } })
    $ui.txtSearch.Add_LostKeyboardFocus({ if ($script:AnimOn) { $script:UI.txtSearch.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-DAnim $script:UI.txtSearch.ActualWidth 210 240 0 (New-Ease 'Cubic' 'EaseOut'))) } })
    foreach ($n in 'dCard1', 'dCard2', 'dCard3', 'dOptCard') { Add-CardLift $ui[$n] }
    $ui.txtSearch.Add_TextChanged({ $script:OptSearch = $script:UI.txtSearch.Text.Trim(); Update-OptFilter })

    $ui.btnNetTest.Add_Click({ Invoke-Safe { Start-NetTest } 'Network test' })
    $ui.btnMtu.Add_Click({ Invoke-Safe { Start-MtuTest } 'MTU test' })
    $ui.btnDns.Add_Click({ Invoke-Safe { Start-DnsTest } 'DNS test' })
    $ui.btnTcpGaming.Add_Click({ Invoke-Safe { Start-TcpProfile 'gaming' } 'TCP profile' })
    $ui.btnTcpThroughput.Add_Click({ Invoke-Safe { Start-TcpProfile 'throughput' } 'TCP profile' })
    $ui.btnTcpDefault.Add_Click({ Invoke-Safe { Start-TcpProfile 'default' } 'TCP restore' })

    $ui.btnRevertAll.Add_Click({ Invoke-Safe { Invoke-RevertAll } 'Revert all' })
    $ui.btnNetRestore.Add_Click({ Invoke-Safe { Start-TcpProfile 'default'; $script:UI.txtRestoreStatus.Text = 'Network settings restored to your baseline.' } 'Network restore' })
    $ui.btnExport.Add_Click({ Invoke-Safe { Invoke-ExportProfile } 'Export' })
    $ui.btnImport.Add_Click({ Invoke-Safe { Invoke-ImportProfile } 'Import' })

    $ui.swMotion.IsChecked = [bool]$script:AnimOn
    $ui.swMotion.Add_Click({ Save-Settings })
}
# ---- UI helpers ---------------------------------------------------------------
function Get-Res { param([string]$Key) return $script:UI.Win.FindResource($Key) }

function Space-Text {
    param([string]$s)
    return (($s.ToCharArray() | ForEach-Object { [string]$_ }) -join [string][char]0x2009)
}

function New-Tb {
    param([string]$Text, [double]$Size = 12.5, [string]$Brush = 'Muted', [bool]$Bold = $false)
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.TextWrapping = 'Wrap'
    $tb.Foreground = Get-Res $Brush
    if ($Bold) { $tb.FontWeight = 'SemiBold' }
    return $tb
}

function New-Chip {
    param([string]$Text, [string]$Fg = 'Muted', [string]$Bg = 'Bg3')
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = New-Object Windows.CornerRadius 9
    $b.Padding = '8,2'
    $b.Margin = '0,0,6,0'
    $b.Background = Get-Res $Bg
    $b.VerticalAlignment = 'Center'
    $t = New-Tb $Text 10.5 $Fg $true
    $t.TextWrapping = 'NoWrap'
    $b.Child = $t
    return $b
}

function Invoke-Safe {
    param([scriptblock]$Block, [string]$What = 'Action')
    try { & $Block } catch { Write-Log "$What failed: $($_.Exception.Message)" 'err' }
}

function Set-Busy {
    param([bool]$Busy, [string[]]$Buttons)
    foreach ($n in $Buttons) { $script:UI[$n].IsEnabled = -not $Busy }
    $script:UI.Win.Cursor = if ($Busy) { [Windows.Input.Cursors]::Wait } else { $null }
    $script:UI.navPanel.IsEnabled = -not $Busy
    Set-Spinner $Busy
}

# ---- pages --------------------------------------------------------------------
$script:PageMeta = [ordered]@{
    dash    = @{ Title = 'Главная';     Sub = 'Ваш ПК с первого взгляда и что на самом деле тормозит FPS.' }
    color   = @{ Title = 'Цвета';       Sub = 'Настройте цветовую кривую основного дисплея.' }
    opt     = @{ Title = 'Оптимизация';      Sub = 'Включайте нужное и применяйте. Всё записывается в журнал и обратимо.' }
    rust    = @{ Title = 'Rust';          Sub = 'Параметры запуска и конфиг графики для RustClient.' }
    session = @{ Title = 'Игровая сессия';  Sub = 'Бусты, которые работают только пока вы играете, а потом сами отключаются.' }
    internet = @{ Title = 'Интернет';     Sub = 'Измерьте подключение и применяйте безопасные обратимые профили TCP.' }
    restore = @{ Title = 'Восстановление и профили'; Sub = 'Откатите всё или экспортируйте и импортируйте свои настройки.' }
    debloat = @{ Title = 'Удаление лишнего';       Sub = 'Удаление предустановленных приложений и рекламы для всех пользователей ПК.' }
    startup = @{ Title = 'Автозапуск';       Sub = 'Управляйте программами, которые запускаются при входе.' }
    clean   = @{ Title = 'Очистка диска';       Sub = 'Освободите место на диске. Ничего не удаляется без подтверждения.' }
    settings = @{ Title = 'Настройки'; Sub = 'Аккаунт, лицензия, быстрая оптимизация и список функций.' }
    log     = @{ Title = 'Журнал';  Sub = 'Всё, что это приложение сделало на этом ПК.' }
}
$script:PageCtl = @{ dash = 'pgDash'; color = 'pgColor'; opt = 'pgOpt'; internet = 'pgInternet'; restore = 'pgRestore'; debloat = 'pgDebloat'; startup = 'pgStartup'; rust = 'pgRust'; session = 'pgSession'; clean = 'pgClean'; settings = 'pgSettings'; log = 'pgLog' }

function Start-PageIn {
    param([string]$Key)
    $ui = $script:UI
    $el = $ui[$script:PageCtl[$Key]]
    Start-FadeSlide $el 0 0 34 320
    Start-FadeSlide $ui.pageTitle 0 8 0 300
    Start-FadeSlide $ui.pageSub 70 6 0 300
    Set-HeaderBar
    switch ($Key) {
        'dash' {
            $i = 0
            foreach ($n in 'dCard1', 'dCard2', 'dCard3') { Start-FadeSlide $ui[$n] (60 + $i * 90) 18 0 420; $i++ }
            Start-Stagger $ui.pnlFindings 10 45 300 12
            Update-DashStats -Animate
        }
        'opt'     { Start-Stagger $ui.pnlTweaks 14 28 40 10 }
        'debloat' { Start-Stagger $ui.pnlDebloat 14 28 40 10 }
        'startup' { Start-Stagger $ui.pnlStartup 12 30 40 10 }
        'internet' { Start-Stagger $ui.pnlInternet 6 80 40 14 }
        'restore' { Start-Stagger $ui.pgRestore.Content 3 90 40 14 }
        'clean'   { Start-Stagger $ui.pnlClean 10 34 40 10 }
        'rust'    { Start-Stagger $ui.pgRust.Content 3 90 40 14; Start-RustHoloAnimation }
        'color'   { Start-ColorPageAnimations }
        'session' { Start-Stagger $ui.pgSession.Content 2 100 40 14 }
    }
}

function Show-Page {
    param([string]$Key, [switch]$NoAnim)
    $ui = $script:UI
    if ($Key -ne 'color') { Start-ColorPageAnimations -Stop }
    if ($Key -ne 'rust') { Stop-Anim $ui.rustHoloRingRot ([Windows.Media.RotateTransform]::AngleProperty) }
    foreach ($k in $script:PageCtl.Keys) { $ui[$script:PageCtl[$k]].Visibility = 'Collapsed' }
    $ui[$script:PageCtl[$Key]].Visibility = 'Visible'
    $ui.pageTitle.Text = $script:PageMeta[$Key].Title
    $ui.pageSub.Text   = $script:PageMeta[$Key].Sub
    switch ($Key) {
        'dash'    { Update-Dashboard -KeepFindings }
        'color'   { }
        'opt'     { Update-AllCards }
        'internet' { Update-NetPage }
        'debloat' { if (-not $script:DbBuilt) { Build-DebloatPage; Start-DebloatScan } }
        'startup' { Build-StartupPage }
        'rust'    { Update-Launch }
        'session' { Update-SessionUi }
        'clean'   { if (-not $script:CleanBuilt) { Build-CleanPage } }
        'settings' { try { Update-SettingsPage } catch { } }
    }
    if (-not $NoAnim) { Start-PageIn $Key }
}

# ---- dashboard ----------------------------------------------------------------
function Update-Side {
    $ui = $script:UI
    if ($script:Session.Active) {
        $ui.sideDot.Fill = Get-Res 'Good'
        Start-Forever $ui.sideDot ([Windows.UIElement]::OpacityProperty) 1 0.3 0.9 $true
        Set-SessionRing $true
        if ($ui.sideTitle.Text -ne 'Сессия активна') { Start-Pop $ui.sideTitle 0 0.9 260 }
        $ui.sideTitle.Text = 'Сессия активна'
        $bits = @()
        if ($script:Session.Timer) { $bits += 'timer held' }
        if (@($script:Session.Stopped).Count -gt 0) { $bits += "$(@($script:Session.Stopped).Count) services paused" }
        if ($script:Session.Prio) { $bits += 'Rust priority' }
        if ($script:Session.Purge) { $bits += 'memory cleaner' }
        $ui.sideSub.Text = ($bits -join ', ')
    } else {
        $ui.sideDot.Fill = Get-Res 'Dim'
        Stop-Anim $ui.sideDot ([Windows.UIElement]::OpacityProperty)
        $ui.sideDot.Opacity = 1
        Set-SessionRing $false
        if ($ui.sideTitle.Text -ne 'Нет активной сессии') { Start-Pop $ui.sideTitle 0 0.9 260 }
        $ui.sideTitle.Text = 'Нет активной сессии'
        $n = $script:Journal.Count
        $ui.sideSub.Text = if ($n -gt 0) { "$n tweak(s) applied by this app" } else { 'No tweaks applied yet' }
    }
}


# ---- OTC GRADE ---------------------------------------------------------------
$script:GradeShown = 0.0
$script:GradeBase = $null

function Get-GradeInfo {
    param([int]$S)
    if ($S -ge 90) { return ,@('S', '#FBBF24', 'Максимум для этого ПК') }
    if ($S -ge 75) { return ,@('A', '#34D399', 'Отлично настроен') }
    if ($S -ge 60) { return ,@('B', '#2DD4BF', 'Хорошо, есть что докрутить') }
    if ($S -ge 40) { return ,@('C', '#FACC15', 'Средне, много резервов') }
    if ($S -ge 20) { return ,@('D', '#FB923C', 'Слабо настроен') }
    return ,@('E', '#F87171', 'Почти не оптимизирован')
}

function Get-OtcGrade {
    # Score = weighted share (by impact) of recommended tweaks that are applied. Premium-locked ones count too.
    $max = 0.0; $got = 0.0; $lockedMax = 0.0
    foreach ($id in @($script:Cards.Keys)) {
        $c = $script:Cards[$id]
        if ($c.Blocked -and -not $c.Locked) { continue }
        $rec = $false
        try { $rec = Test-TweakRecommended $c.Tweak } catch { }
        if (-not $rec) { continue }
        $w = [math]::Max(1, [int]$c.Tweak.Impact)
        $max += $w
        if ($c.Applied) { $got += $w }
        if ($c.Locked) { $lockedMax += $w }
    }
    $score = 0; $lp = 0
    if ($max -gt 0) { $score = [int][math]::Round(100 * $got / $max); $lp = [int][math]::Round(100 * $lockedMax / $max) }
    return @{ Score = $score; LockedPts = $lp }
}

function Set-GradeVisual {
    param([double]$V)
    $ui = $script:UI
    if (-not $ui.gradeArc) { return }
    $circ = 31.13   # (120 - 11) * pi / 11
    $ui.gradeArc.Visibility = $(if ($V -lt 0.5) { 'Collapsed' } else { 'Visible' })
    $dc = New-Object Windows.Media.DoubleCollection
    [void]$dc.Add($circ * $V / 100); [void]$dc.Add(100)
    $ui.gradeArc.StrokeDashArray = $dc
    $g = Get-GradeInfo ([int][math]::Round($V))
    $br = (New-Object Windows.Media.BrushConverter).ConvertFromString($g[1])
    $ui.gradeArc.Stroke = $br
    $ui.gradeLetter.Foreground = $br
    $ui.gradeLetter.Text = $g[0]
    $ui.gradeScore.Text = ('{0} / 100' -f [int][math]::Round($V))
}

function Step-Grade {
    $p = ([DateTime]::UtcNow - $script:GradeT0).TotalMilliseconds / 800.0
    if ($p -ge 1) { $p = 1 }
    $e = 1 - [math]::Pow(1 - $p, 3)
    $v = $script:GradeFrom + ($script:GradeTo - $script:GradeFrom) * $e
    $script:GradeShown = $v
    Set-GradeVisual $v
    if ($p -ge 1 -and $script:GradeTimer) { $script:GradeTimer.Stop() }
}

function Set-GradeGauge {
    param([int]$Score)
    if (-not $script:AnimOn) { $script:GradeShown = [double]$Score; Set-GradeVisual $Score; return }
    $script:GradeFrom = [double]$script:GradeShown
    $script:GradeTo = [double]$Score
    $script:GradeT0 = [DateTime]::UtcNow
    if (-not $script:GradeTimer) {
        $script:GradeTimer = New-Object Windows.Threading.DispatcherTimer
        $script:GradeTimer.Interval = [TimeSpan]::FromMilliseconds(16)
        $script:GradeTimer.Add_Tick({ try { Step-Grade } catch { $script:GradeTimer.Stop() } })
    }
    $script:GradeTimer.Start()
}

function Update-Grade {
    $ui = $script:UI
    if (-not $ui.gradeArc) { return }
    $g = Get-OtcGrade
    $s = [int]$g.Score

    # baseline = score at the first launch (saved), used for the "growth" line
    if ($null -eq $script:GradeBase) {
        $dir = Join-Path $env:ProgramData 'OTCOpti'
        $f = Join-Path $dir 'grade_base.txt'
        $b = 0
        try {
            if (Test-Path -LiteralPath $f) { [void][int]::TryParse(([IO.File]::ReadAllText($f)).Trim(), [ref]$b) }
            else {
                if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
                [IO.File]::WriteAllText($f, [string]$s); $b = $s
            }
        } catch { $b = $s }
        $script:GradeBase = $b
    }

    $info = Get-GradeInfo $s
    $ui.gradeTitle.Text = "Оценка $($info[0]): $($info[2])"
    $d = $s - [int]$script:GradeBase
    if ($d -gt 0) { $ui.gradeGrowth.Text = "Рост: +$d баллов с первого запуска" }
    else { $ui.gradeGrowth.Text = 'Применяйте оптимизации, и оценка будет расти.' }

    $next = $null
    foreach ($th in 20, 40, 60, 75, 90) { if ($s -lt $th) { $next = $th; break } }
    $note = ''
    if ($null -ne $next) { $note = "До оценки $((Get-GradeInfo $next)[0]) не хватает $($next - $s) баллов. " }
    else { $note = 'Это максимальная оценка для вашего ПК. ' }
    if (-not (Test-Premium) -and $g.LockedPts -gt 0) { $note += "PREMIUM откроет ещё до +$($g.LockedPts) баллов." }
    $ui.gradeNote.Text = $note.Trim()

    Set-GradeGauge $s
}

function Update-DashStats {
    param([switch]$Animate)
    $ui = $script:UI
    $total = 0; $done = 0
    foreach ($id in $script:Cards.Keys) {
        $c = $script:Cards[$id]
        if ($c.Blocked) { continue }
        $rec = $false
        try { $rec = Test-TweakRecommended $c.Tweak } catch { }
        if (-not $rec) { continue }
        $total++
        if ($c.Applied) { $done++ }
    }
    $pct = if ($total -gt 0) { [math]::Round(100 * $done / $total) } else { 0 }
    $ui.dTotal.Text = "/ $total"
    $ui.dApplied.Text = "$done"
    if ($Animate -and $script:AnimOn) {
        $ui.dApplied.Text = '0'
        $ui.countProxy.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, (New-DAnim 0 $done 750 180 (New-Ease 'Cubic' 'EaseOut')))
        $ui.dBar.Value = 0
        Set-BarAnimated $ui.dBar $pct
    } else { $ui.dBar.Value = $pct }
    try { Update-Grade } catch { }
    $ui.dAppliedNote.Text = if ($done -ge $total -and $total -gt 0) { 'Всё рекомендованное для этого ПК применено.' } else { "$($total - $done) рекомендуемых твиков доступно для этого ПК." }
}

function Update-Dashboard {
    param([switch]$KeepFindings)
    $ui = $script:UI; $F = $script:Facts
    $ui.dCpu.Text = $F.CpuName
    $ui.dGpu.Text = if (@($F.Gpus).Count -gt 0) { (@($F.Gpus) | ForEach-Object { $_.Name }) -join ' + ' } else { 'Видеокарта не обнаружена' }
    $ui.dRam.Text = "$($F.RamGB) ГБ ОЗУ"
    $ui.dOs.Text  = $F.OsName
    if ($F.RustExe) { $ui.dRust.Text = 'Rust найден'; $ui.dRustSub.Text = $F.RustExe }
    else { $ui.dRust.Text = 'Rust не найден'; $ui.dRustSub.Text = 'Установите Rust через Steam, чтобы открыть инструменты для Rust.' }
    Update-DashStats
    Update-Side
    if ($KeepFindings -and $script:FindingsDone) { return }
    if ($script:DeferFindings -or $script:FindingsBusy) { return }
    $script:FindingsBusy = $true
    $ui.pnlFindings.Children.Clear()
    [void]$ui.pnlFindings.Children.Add((New-Tb 'Сканирование этого ПК...' 12.5 'Muted'))
    Invoke-UiPump
    $items = @()
    try { $items = @(Invoke-Blocking -Functions 'Get-Findings', 'Format-Bytes', 'Get-ActivePlan', 'Invoke-NativeOut' -ArgList @($script:Facts, $script:NativeOk) -Script { param($f, $n) Get-Findings -F $f -NativeOk $n }) } catch { Write-Log "Ошибка сканирования: $($_.Exception.Message)" 'err' }
    $script:FindingsBusy = $false
    $ui.pnlFindings.Children.Clear()
    $order = @{ warn = 0; info = 1; ok = 2 }
    foreach ($f in ($items | Sort-Object { $order[$_.Level] })) {
        $row = New-Object Windows.Controls.Border
        $row.Background = Get-Res 'Bg2'
        $row.BorderBrush = Get-Res 'Line'
        $row.BorderThickness = '1'
        $row.CornerRadius = New-Object Windows.CornerRadius 10
        $row.Padding = '14,11'
        $row.Margin = '0,0,0,8'
        Add-CardHover $row
        $g = New-Object Windows.Controls.Grid
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = 'Auto'
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '*'
        [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 9; $dot.Height = 9; $dot.Margin = '0,5,14,0'; $dot.VerticalAlignment = 'Top'
        $dot.Fill = switch ($f.Level) { 'warn' { Get-Res 'Warn' } 'ok' { Get-Res 'Good' } default { Get-Res 'Dim' } }
        if ($f.Level -eq 'warn') { Start-Forever $dot ([Windows.UIElement]::OpacityProperty) 1 0.35 0.9 $true }
        $sp = New-Object Windows.Controls.StackPanel
        [void]$sp.Children.Add((New-Tb $f.Title 13 'Text' $true))
        $d = New-Tb $f.Detail 12 'Muted'; $d.Margin = '0,3,0,0'
        [void]$sp.Children.Add($d)
        [Windows.Controls.Grid]::SetColumn($sp, 1)
        [void]$g.Children.Add($dot); [void]$g.Children.Add($sp)
        $row.Child = $g
        [void]$ui.pnlFindings.Children.Add($row)
    }
    $script:FindingsDone = $true
    Start-Stagger $ui.pnlFindings 12 40 0 10
}

# ---- optimize page ------------------------------------------------------------
$script:Cards = @{}
$script:Sel = New-Object 'System.Collections.Generic.HashSet[string]'
$script:OptBuilt = $false

function New-TweakCard {
    param($T)
    $blocked = $null
    try { $blocked = Get-TweakBlock $T } catch { }
    $locked = [bool](Test-TweakLocked $T)
    if ($locked) { $blocked = "$(Get-TweakRequiredTier $T) — эта оптимизация недоступна в текущем тарифе." }

    $card = New-Object Windows.Controls.Border
    $card.Background = Get-Res 'CardBg'
    $card.BorderBrush = Get-Res 'Line'
    $card.BorderThickness = '1'
    $card.CornerRadius = New-Object Windows.CornerRadius 10
    $card.Tag = $T.Id
    $card.Padding = '14,12'
    $card.Margin = '0,0,0,8'
    if ($locked) {
        $gb = New-Object Windows.Media.LinearGradientBrush
        $gb.StartPoint = New-Object Windows.Point 0, 0
        $gb.EndPoint = New-Object Windows.Point 1, 1
        [void]$gb.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString('#2E2512'), 0.0))
        [void]$gb.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString('#17162B'), 1.0))
        $card.Background = $gb
        $card.BorderBrush = (New-Object Windows.Media.BrushConverter).ConvertFromString('#8A6A1F')
        $card.Cursor = [Windows.Input.Cursors]::Hand
        $requiredTier = Get-TweakRequiredTier $T
        $card.Add_MouseLeftButtonUp({ try { Show-Toast "Оптимизация доступна в тарифе $requiredTier. Откройте Настройки для активации." 'warn' } catch { } }.GetNewClosure())
    } else { Add-CardHover $card }

    $g = New-Object Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }

    $sw = New-Object Windows.Controls.CheckBox
    $sw.Style = Get-Res 'Switch'
    $sw.Tag = $T.Id
    $sw.VerticalAlignment = 'Top'
    $sw.Margin = '0,2,16,0'
    $sw.Add_Checked({ param($s, $e) [void]$script:Sel.Add([string]$s.Tag); Update-ApplyGlow })
    $sw.Add_Unchecked({ param($s, $e) [void]$script:Sel.Remove([string]$s.Tag); Update-ApplyGlow })
    $sw.IsChecked = $script:Sel.Contains($T.Id)
    [void]$g.Children.Add($sw)

    $mid = New-Object Windows.Controls.StackPanel
    $head = New-Object Windows.Controls.WrapPanel
    $nm = New-Tb $T.Name 13.5 'Text' $true
    $nm.Margin = '0,0,10,0'; $nm.TextWrapping = 'NoWrap'; $nm.VerticalAlignment = 'Center'
    if ($locked) {
        $lk = New-Object Windows.Controls.TextBlock
        $lk.FontFamily = New-Object Windows.Media.FontFamily 'Segoe MDL2 Assets'
        $lk.Text = [string][char]0xE72E
        $lk.FontSize = 15
        $lk.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#FBBF24')
        $lk.Margin = '0,0,8,0'; $lk.VerticalAlignment = 'Center'
        [void]$head.Children.Add($lk)
        $nm.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#F3D98B')
    }
    [void]$head.Children.Add($nm)
    $impact = switch ([int]$T.Impact) {
        0 { @('Не влияет на FPS', 'Dim') }
        1 { @('Небольшой прирост', 'Muted') }
        2 { @('Средний прирост', 'AccentHi') }
        default { @('Большой прирост, если применимо', 'Accent') }
    }
    if ($locked) { [void]$head.Children.Add((New-Chip (Get-TweakRequiredTier $T) 'Warn' 'Bg1')) }
    else { [void]$head.Children.Add((New-Chip (Get-TweakRequiredTier $T) 'Good' 'Bg1')) }
    [void]$head.Children.Add((New-Chip $impact[0] $impact[1]))
    $tier = Get-TweakTier $T
    [void]$head.Children.Add((New-Chip (Get-TierRu $tier) (Get-TierBrush $tier) 'Bg1'))
    foreach ($gn in @($T.Gain)) { [void]$head.Children.Add((New-Chip (Get-GainRu $gn) 'Dim' 'Bg1')) }
    if ($T.Reboot) { [void]$head.Children.Add((New-Chip 'Перезагрузка' 'Warn' 'Bg1')) }
    [void]$mid.Children.Add($head)

    $desc = New-Tb $T.Desc 12 'Muted'; $desc.Margin = '0,5,0,0'
    [void]$mid.Children.Add($desc)

    if ($T.Note) {
        $n = $null
        try { $n = & $T.Note } catch { }
        if ($n) { $nt = New-Tb ([string]$n) 11.5 'Warn'; $nt.Margin = '0,5,0,0'; [void]$mid.Children.Add($nt) }
    }
    if ($T.Live -and -not $blocked) {
        $l = $null
        try { $l = & $T.Live } catch { }
        if ($l) { $lt = New-Tb ([string]$l) 11.5 'AccentHi'; $lt.Margin = '0,5,0,0'; [void]$mid.Children.Add($lt) }
    }
    if ($blocked) {
        $bt = New-Tb ([string]$blocked) 11.5 'Dim'; $bt.Margin = '0,5,0,0'; $bt.FontStyle = 'Italic'
        if ($locked) {
            $bt.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString('#C9A24B')
            $bt.Text = "$(Get-TweakRequiredTier $T) — откройте Настройки и активируйте соответствующий ключ."
        }
        [void]$mid.Children.Add($bt)
        $sw.IsEnabled = $false
        $card.Opacity = $(if ($locked) { 0.92 } else { 0.6 })
    }
    [Windows.Controls.Grid]::SetColumn($mid, 1)
    [void]$g.Children.Add($mid)

    $pill = New-Object Windows.Controls.Border
    $pill.CornerRadius = New-Object Windows.CornerRadius 9
    $pill.Padding = '10,3'
    $pill.VerticalAlignment = 'Top'
    $pill.Margin = '14,1,0,0'
    $pt = New-Tb '' 11 'Dim' $true
    $pt.TextWrapping = 'NoWrap'
    $pill.Child = $pt
    [Windows.Controls.Grid]::SetColumn($pill, 2)
    [void]$g.Children.Add($pill)

    $card.Child = $g
    $script:Cards[$T.Id] = @{ Tweak = $T; Card = $card; Switch = $sw; Pill = $pill; PillText = $pt; Blocked = [bool]$blocked; Locked = $locked; Applied = $false; Tier = $tier }
    return $card
}

function Update-Card {
    param([string]$Id)
    $c = $script:Cards[$Id]
    if (-not $c) { return }
    if ($c.Blocked) {
        if ($c.Locked) {
            $bc = New-Object Windows.Media.BrushConverter
            $c.PillText.Text = Get-TweakRequiredTier $c.Tweak
            $c.Pill.Background = $bc.ConvertFromString('#2E2512')
            $c.PillText.Foreground = $bc.ConvertFromString('#FBBF24')
        } else {
            $c.PillText.Text = 'Недоступно'; $c.Pill.Background = Get-Res 'Bg1'; $c.PillText.Foreground = Get-Res 'Dim'
        }
        return
    }
    $on = $false
    try { $on = Test-TweakApplied $c.Tweak } catch { }
    $changed = ($c.Seen -and ($c.Applied -ne $on))
    $c.Applied = $on
    $c.Seen = $true
    if ($changed) { Start-Pop $c.Pill 0 0.6 360 }
    if ($on) { $c.PillText.Text = 'Применено'; $c.Pill.Background = [Windows.Media.Brushes]::Transparent; $c.PillText.Foreground = Get-Res 'Good'; $c.Pill.BorderBrush = Get-Res 'Good'; $c.Pill.BorderThickness = '1' }
    else     { $c.PillText.Text = 'Выкл'; $c.Pill.Background = Get-Res 'Bg1'; $c.PillText.Foreground = Get-Res 'Dim'; $c.Pill.BorderThickness = '0' }
}

function Update-AllCards {
    foreach ($id in @($script:Cards.Keys)) { Update-Card $id; Invoke-UiPump }
    Update-DashStats
    Update-Side
}

function Build-OptPage {
    if ($script:OptBuilt) { return }
    $ui = $script:UI
    $ui.pnlTweaks.Children.Clear()
    foreach ($grp in $script:Groups) {
        $mine = @($script:Tweaks | Where-Object { $_.Group -eq $grp.Key })
        if ($mine.Count -eq 0) { continue }
        $h = New-Tb ($grp.Title.ToUpper()) 10.5 'Dim' $true
        $h.Margin = '2,14,0,8'
        $h.Tag = 'hdr'
        [void]$ui.pnlTweaks.Children.Add($h)
        foreach ($t in $mine) {
            [void]$ui.pnlTweaks.Children.Add((New-TweakCard $t))
            $script:BuildN = [int]$script:BuildN + 1
            if ($script:UI.landing.Visibility -eq 'Visible') { Set-EnterContent ("Загрузка твиков {0}/{1}" -f $script:BuildN, @($script:Tweaks).Count) $false }
            Invoke-UiPump
        }
    }
    $script:OptBuilt = $true
    Update-AllCards
    Update-FilterCounts
}

function Get-SelectedTweaks {
    return @($script:Tweaks | Where-Object { $script:Sel.Contains($_.Id) -and -not $script:Cards[$_.Id].Blocked })
}

function Restart-ExplorerShell {
    Write-Log 'Restarting Explorer to apply interface changes...' 'info'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
}

function Invoke-OptRun {
    param([bool]$Apply)
    $ui = $script:UI
    $sel = @(Get-SelectedTweaks)
    if ($sel.Count -eq 0) { Write-Log 'Ничего не выбрано. Сначала включите несколько переключателей.' 'warn'; return }
    if ($Apply) {
        $risky = @($sel | Where-Object { $script:SecurityIds -contains $_.Id })
        if ($risky.Count -gt 0) {
            $names = ($risky | ForEach-Object { '  - ' + $_.Name }) -join "`n"
            $ans = [Windows.MessageBox]::Show("These changes weaken a Windows security protection or exclude files from scanning:`n`n$names`n`nThey can be undone from this app. Apply them anyway?", 'OTC OPTI security confirmation', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { Write-Log 'Security-related tweaks were not applied.' 'warn'; return }
        }
    }
    $btns = @('btnOptApply', 'btnOptRevert', 'btnOptClear', 'btnOptRec', 'btnOptGame')
    Set-Busy $true $btns
    $needExplorer = $false; $reboot = @(); $ok = 0; $fail = 0
    $script:LastRun = @{ Apply = $Apply; Ok = @(); Fail = @() }
    try {
        if ($Apply -and $ui.chkRestore.IsChecked) {
            Write-Log 'Создаю точку восстановления...' 'info'; Invoke-UiPump
            try { New-RestorePointAsync; Write-Log 'Точка восстановления создана.' 'ok' }
            catch { Write-Log "Точка восстановления не создана: $($_.Exception.Message)" 'warn' }
        }
        foreach ($t in $sel) {
            try {
                if ($Apply) { Invoke-TweakApply $t; Write-Log "Применено: $($t.Name)" 'ok' }
                else        { Invoke-TweakUndo $t;  Write-Log "Откачено: $($t.Name)" 'accent' }
                $ok++
                $script:LastRun.Ok += $t
                if ($t.Explorer) { $needExplorer = $true }
                if ($t.Reboot)   { $reboot += $t.Name }
                $script:Cards[$t.Id].Switch.IsChecked = $false
            } catch {
                $fail++
                $script:LastRun.Fail += $t
                Write-Log "ОШИБКА: $($t.Name) - $($_.Exception.Message)" 'err'
            }
            Update-Card $t.Id
            Invoke-UiPump
        }
        if ($needExplorer) { Restart-ExplorerShell }
        if ($reboot.Count -gt 0) {
            $ui.bannerRebootText.Text = 'Перезагрузите Windows для завершения: ' + ($reboot -join ', ') + '.'
            $ui.bannerReboot.Visibility = 'Visible'
            Start-FadeSlide $ui.bannerReboot 0 -12 0 320
            Start-Forever $ui.bannerReboot ([Windows.UIElement]::OpacityProperty) 1 0.65 1.1 $true 'Sine' 600
        }
        Write-Log ("{0} done: {1} succeeded, {2} failed." -f $(if ($Apply) { 'Apply' } else { 'Revert' }), $ok, $fail) $(if ($fail -gt 0) { 'warn' } else { 'ok' })
        Show-Toast ("{0} {1} tweak(s){2}" -f $(if ($Apply) { 'Применено' } else { 'Откачено' }), $ok, $(if ($fail -gt 0) { ", $fail failed" } else { '' })) $(if ($fail -gt 0) { 'warn' } else { 'ok' })
    } finally {
        Set-Busy $false $btns
        Update-DashStats
        Update-Side
    }
}

function Select-Recommended {
    $n = 0
    foreach ($id in $script:Cards.Keys) {
        $c = $script:Cards[$id]
        if ($c.Blocked -or $c.Applied) { continue }
        $rec = $false
        try { $rec = Test-TweakRecommended $c.Tweak } catch { }
        if ($rec) { $c.Switch.IsChecked = $true; $n++ }
    }
    Write-Log "Selected $n recommended tweak(s) that are not applied yet." 'info'
}

function Select-GameOptimizations {
    $gameIds = @('pwr_throttle', 'gpu_gamemode', 'gpu_dvr', 'inp_timer', 'sch_prio', 'sch_mmcss')
    $n = 0
    foreach ($id in $gameIds) {
        if (-not $script:Cards.ContainsKey($id)) { continue }
        $card = $script:Cards[$id]
        if ($card.Blocked -or $card.Applied) { continue }
        $card.Switch.IsChecked = $true
        $n++
    }
    Write-Log "Selected $n supported, reversible gaming optimization(s)." 'info'
}

# ---- Rust page ----------------------------------------------------------------
function Update-Launch {
    $ui = $script:UI
    $opt = @{ High = [bool]$ui.loHigh.IsChecked; Exclusive = [bool]$ui.loExcl.IsChecked; Cpu = [bool]$ui.loCpu.IsChecked; D3d = [bool]$ui.loD3d.IsChecked; NoLog = [bool]$ui.loLog.IsChecked }
    $ui.txtLaunch.Text = Get-RustLaunchOptions $opt
    $F = $script:Facts
    $ui.txtLaunchNote.Text = if ($F.Cores -gt 0) { "Обнаружено ядер: $($F.Cores), потоков: $($F.Threads)." } else { '' }
}

function Invoke-Preset {
    param([string]$Key, [string]$Label)
    $ui = $script:UI
    try {
        $n = Set-RustPreset $Key
        $ui.txtPreStatus.Text = "$Label written ($n settings). It applies the next time you start Rust."
        $ui.txtPreStatus.Foreground = Get-Res 'Good'
        Write-Log "Rust preset '$Label' written to client.cfg." 'ok'
    } catch {
        $ui.txtPreStatus.Text = $_.Exception.Message
        $ui.txtPreStatus.Foreground = Get-Res 'Warn'
        Write-Log "Rust preset: $($_.Exception.Message)" 'warn'
    }
}

# ---- game session page --------------------------------------------------------
function Get-SessionOptions {
    $ui = $script:UI
    return @{ Timer = [bool]$ui.sesTimer.IsChecked; Purge = [bool]$ui.sesPurge.IsChecked; Priority = [bool]$ui.sesPrio.IsChecked; Services = [bool]$ui.sesSvc.IsChecked; Pin = ([bool]$ui.sesPin.IsChecked -and [bool]$script:Facts.DualCcdX3D) }
}

function Update-SessionUi {
    $ui = $script:UI
    if ($script:Session.Active) {
        $ui.btnSesToggle.Content = 'Завершить сессию'
        $ui.txtSesStatus.Text = 'Сессия запущена. Бусты активны, пока вы не завершите её или не закроете приложение.'
        $ui.txtSesStatus.Foreground = Get-Res 'Good'
    } else {
        $ui.btnSesToggle.Content = 'Начать сессию'
        $ui.txtSesStatus.Text = if ($ui.sesAuto.IsChecked) { 'Ожидание запуска Rust...' } else { 'Сессия не запущена.' }
        $ui.txtSesStatus.Foreground = Get-Res 'Muted'
    }
    foreach ($n in 'sesTimer', 'sesPurge', 'sesPrio', 'sesPin', 'sesSvc') { $ui[$n].IsEnabled = -not $script:Session.Active }
    Update-Side
}

function Invoke-SessionTick {
    $rust = $null
    $gname = ([string]$script:UI.txtGameExe.Text).Trim() -replace '\.exe$', ''
    if (-not $gname) { $gname = 'RustClient' }
    try { $rust = Get-Process -Name $gname -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { }
    $auto = [bool]$script:UI.sesAuto.IsChecked
    if ($auto -and -not $script:Session.Active -and $rust) {
        $script:SessAutoStarted = $true; $script:RustGone = 0
        Write-Log 'Игра запущена, начинаю сессию.' 'accent'
        Start-GameSession (Get-SessionOptions); Update-SessionUi
    }
    elseif ($script:Session.Active -and $script:SessAutoStarted -and -not $rust) {
        $script:RustGone = [int]$script:RustGone + 1
        if ($script:RustGone -ge 2) { $script:SessAutoStarted = $false; Write-Log 'Игра закрыта, завершаю сессию.' 'accent'; Stop-GameSession; Update-SessionUi }
    }
    if ($script:Session.Active) {
        if ($script:Session.Prio -and $rust) {
            try { if ($rust.PriorityClass -notin 'AboveNormal', 'High', 'RealTime') { $rust.PriorityClass = 'AboveNormal'; Write-Log "$($rust.ProcessName) priority set to Above Normal." 'ok' } }
            catch { Write-Log "Could not change Rust priority: $($_.Exception.Message)" 'warn' }
        }
        if ($script:Session.Pin -and $rust) { Set-VCacheAffinity $rust }
        $script:Session.Tick = [int]$script:Session.Tick + 1
        if ($script:Session.Purge -and ($script:Session.Tick % 6) -eq 0) {
            $m = Get-MemSnapshot
            if ($m -and $m.Free -lt 1.5GB -and $m.Standby -gt 1GB) { Invoke-PurgeStandby }
        }
    }
}

function Build-KillList {
    $ui = $script:UI
    $ui.pnlKill.Children.Clear()
    $defaults = @('OneDrive', 'Epic Launcher')
    foreach ($k in $script:KillGroups.Keys) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $k
        $cb.Tag = $k
        $cb.Margin = '0,5,22,5'
        $cb.IsChecked = ($defaults -contains $k)
        [void]$ui.pnlKill.Children.Add($cb)
    }
}

# ---- cleaner page -------------------------------------------------------------
$script:CleanBuilt = $false
$script:CleanTasks = @()
$script:CleanChk = @{}
$script:CleanLbl = @{}
$script:CleanCtx = @{ Busy = $false }

function Build-CleanPage {
    $ui = $script:UI
    $script:CleanTasks = @(Get-CleanTasks)
    $ui.pnlClean.Children.Clear()
    foreach ($t in $script:CleanTasks) {
        $card = New-Object Windows.Controls.Border
        $card.Background = Get-Res 'Bg2'; $card.BorderBrush = Get-Res 'Line'; $card.BorderThickness = '1'
        $card.CornerRadius = New-Object Windows.CornerRadius 10
        $card.Padding = '14,10'; $card.Margin = '0,0,0,8'; Add-CardHover $card
        $g = New-Object Windows.Controls.Grid
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '*'
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
        [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
        $sp = New-Object Windows.Controls.StackPanel
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $t.Name; $cb.FontWeight = 'SemiBold'; $cb.Margin = '0,0,0,0'
        $cb.IsChecked = [bool]$t.Rec
        $d = New-Tb $t.Desc 11.5 'Muted'; $d.Margin = '28,3,12,0'
        [void]$sp.Children.Add($cb); [void]$sp.Children.Add($d)
        $lbl = New-Tb '-' 12.5 'Accent' $true
        $lbl.TextWrapping = 'NoWrap'; $lbl.VerticalAlignment = 'Top'; $lbl.FontFamily = 'Consolas'
        [Windows.Controls.Grid]::SetColumn($lbl, 1)
        [void]$g.Children.Add($sp); [void]$g.Children.Add($lbl)
        $card.Child = $g
        [void]$ui.pnlClean.Children.Add($card)
        $script:CleanChk[$t.Id] = $cb
        $script:CleanLbl[$t.Id] = $lbl
    }
    $script:CleanBuilt = $true
}

function Start-CleanJob {
    param([bool]$Delete)
    $ui = $script:UI
    if ($script:CleanCtx.Busy) { return }
    $tasks = @($script:CleanTasks | Where-Object { $script:CleanChk[$_.Id].IsChecked })
    if ($Delete -and $tasks.Count -eq 0) { Write-Log 'Для очистки ничего не отмечено.' 'warn'; return }
    if (-not $Delete) { $tasks = @($script:CleanTasks) }
    if ($Delete) {
        $ans = [Windows.MessageBox]::Show('Отмеченное будет удалено без возможности восстановления. Продолжить?', 'OTC OPTI', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    }
    $script:CleanCtx = @{ Busy = $true; Done = 0; Count = $tasks.Count; Delete = $Delete; Freed = 0.0 }
    foreach ($b in 'btnScan', 'btnCleanRun', 'btnCleanRec', 'btnCleanNone') { $ui[$b].IsEnabled = $false }
    $ui.barClean.Value = 0
    Set-Spinner $true
    Start-Forever $ui.barClean ([Windows.UIElement]::OpacityProperty) 1 0.55 0.8 $true
    $ui.txtCleanTotal.Text = ''
    $ui.txtCleanStatus.Text = if ($Delete) { 'Очистка...' } else { 'Сканирование...' }
    Invoke-Async -Work $script:CleanWork -ArgList @($tasks, $Delete) -OnProgress {
        param($it)
        $ctx = $script:CleanCtx
        switch ($it.Kind) {
            'start' { $script:CleanLbl[$it.Id].Text = '...' }
            'tick'  { $script:CleanLbl[$it.Id].Text = (Format-Bytes $it.Bytes) }
            'done'  {
                $script:CleanLbl[$it.Id].Text = if ($it.Text) { $it.Text } else { Format-Bytes $it.Bytes }
                Start-Pop $script:CleanLbl[$it.Id] 0 0.85 240
                $ctx.Done++
                $script:UI.barClean.Value = [math]::Round(100 * $ctx.Done / [math]::Max(1, $ctx.Count))
            }
            'total' { $ctx.Freed = $it.Bytes }
        }
    } -OnDone {
        param($res, $err)
        $ctx = $script:CleanCtx; $ui = $script:UI
        $ctx.Busy = $false
        foreach ($b in 'btnScan', 'btnCleanRun', 'btnCleanRec', 'btnCleanNone') { $ui[$b].IsEnabled = $true }
        $ui.barClean.Value = 100
        Set-Spinner $false
        Stop-Anim $ui.barClean ([Windows.UIElement]::OpacityProperty); $ui.barClean.Opacity = 1
        if ($err) { $ui.txtCleanStatus.Text = "Failed: $err"; Write-Log "Cleaner failed: $err" 'err'; return }
        if ($ctx.Delete) {
            $ui.txtCleanStatus.Text = 'Очистка завершена.'
            $ui.txtCleanTotal.Text = 'Освобождено ' + (Format-Bytes $ctx.Freed)
            Write-Log ("Cleaner freed {0}." -f (Format-Bytes $ctx.Freed)) 'ok'
            Show-Toast ("Freed {0}" -f (Format-Bytes $ctx.Freed)) 'ok'
        } else {
            $ui.txtCleanStatus.Text = 'Сканирование завершено.'
            $ui.txtCleanTotal.Text = (Format-Bytes $ctx.Freed) + ' можно освободить'
            Write-Log ("Cleaner scan: {0} reclaimable." -f (Format-Bytes $ctx.Freed)) 'info'
        }
    }
}

# ---- build the window ------------------------------------------------------------
function New-AppWindow {
    $xml = [xml]$script:Xaml
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    $ui = @{ Win = $win }
    foreach ($m in [regex]::Matches($script:Xaml, 'x:Name="([^"]+)"')) {
        $n = $m.Groups[1].Value
        $el = $win.FindName($n)
        if ($el) { $ui[$n] = $el }
    }
    $script:UI = $ui
    $ui.slColorBrightness.Value = [double]$script:ColorValues.Brightness
    $ui.slColorContrast.Value = [double]$script:ColorValues.Contrast
    $ui.slColorSaturation.Value = [double]$script:ColorValues.Saturation
    $ui.slColorExposure.Value = [double]$script:ColorValues.Exposure
    $ui.slColorGamma.Value = [double]$script:ColorValues.Gamma
    $ui.txtColorBrightness.Text = ([double]$script:ColorValues.Brightness).ToString('0')
    $ui.txtColorContrast.Text = ([double]$script:ColorValues.Contrast).ToString('0')
    $ui.txtColorSaturation.Text = ([double]$script:ColorValues.Saturation).ToString('0')
    $ui.txtColorExposure.Text = ([double]$script:ColorValues.Exposure).ToString('+0.00;-0.00;0.00') + ' EV'
    $ui.txtColorGamma.Text = ([double]$script:ColorValues.Gamma).ToString('0.00')
    try { Restore-Theme } catch { }
    return $win
}

function Start-AppEntrance {
    $ui = $script:UI
    Start-FadeSlide $ui.app 0 0 20 420
    $i = 0
    foreach ($n in @($ui.navPanel.Children)) { Start-FadeSlide $n (140 + $i * 55) 0 -18 380; $i++ }
    Start-Pop $ui.sideLogo 120 0.5 450
    Start-FadeSlide $ui.swMotion 520 0 0 320
    Move-NavHighlight $ui.navDash -Instant
    Set-Ambient
    try { Set-BgImage; Update-BgMotion } catch { }
    Start-PageIn 'dash'
    $script:DeferFindings = $false
    $script:FindingsDone = $false
    Invoke-Safe { Update-Dashboard } 'Dashboard scan'
}

function Enter-App {
    $ui = $script:UI
    if (-not $script:Ready) { return }
    $ui.btnEnter.IsEnabled = $false
    Set-EnterContent 'Сканирование ПК...' $false
    Invoke-UiPump
    $script:DeferFindings = $true
    $script:BuildN = 0
    try {
        Build-OptPage
        Build-KillList
        Build-CleanPage
        Update-Dashboard
    } catch { Write-Log "Startup scan hit a problem: $($_.Exception.Message)" 'warn' }
    Show-Page 'dash' -NoAnim
    if (-not $script:AnimOn) {
        Stop-Particles
        $ui.landing.Visibility = 'Collapsed'; $ui.app.Visibility = 'Visible'; $ui.app.Opacity = 1
        Start-PageIn 'dash'
        $script:DeferFindings = $false; $script:FindingsDone = $false
        Invoke-Safe { Update-Dashboard } 'Dashboard scan'
        return
    }
    $ui.hero.RenderTransformOrigin = New-Object Windows.Point -ArgumentList 0.5, 0.5
    $zoom = New-Object Windows.Media.ScaleTransform
    $ui.hero.RenderTransform = $zoom
    $zoom.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim 1 1.06 300 0 (New-Ease 'Quad' 'EaseIn')))
    $zoom.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim 1 1.06 300 0 (New-Ease 'Quad' 'EaseIn')))
    $fade = New-DAnim 1 0 300 0 (New-Ease 'Quad' 'EaseIn')
    $fade.Add_Completed({
        Stop-Particles
        $script:UI.landing.Visibility = 'Collapsed'
        $script:UI.app.Visibility = 'Visible'
        Start-AppEntrance
    })
    $ui.landing.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
}

function Start-LandingAnimations {
    $ui = $script:UI
    $letters = @($ui.lnTitle.Children)
    if (-not $script:AnimOn) {
        $ui.Win.Opacity = 1
        $ui.logoScale.ScaleX = 1; $ui.logoScale.ScaleY = 1; $ui.lnUnder.Width = 120
        foreach ($el in @($ui.logoWrap, $ui.lnTag, $ui.lnSub, $ui.lnLine, $ui.btnEnter, $ui.chipA, $ui.chipB, $ui.chipC, $ui.lnSys, $ui.lnChrome) + $letters) { Start-FadeSlide $el 0 0 0 1 }
        return
    }
    $op = [Windows.UIElement]::OpacityProperty
    $out = New-Ease 'Quad' 'EaseOut'
    # window open: fade + settle
    $wa = New-DAnim 0 1 450 0 $out
    $wa.FillBehavior = 'Stop'
    $wa.Add_Completed({ $script:UI.Win.Opacity = 1 })
    $ui.Win.BeginAnimation($op, $wa)
    $ui.frame.RenderTransformOrigin = New-Object Windows.Point -ArgumentList 0.5, 0.5
    $fs = New-Object Windows.Media.ScaleTransform
    $fs.ScaleX = 0.965; $fs.ScaleY = 0.965
    $ui.frame.RenderTransform = $fs
    $fs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim 0.965 1 560 0 (New-Ease 'Cubic' 'EaseOut')))
    $fs.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim 0.965 1 560 0 (New-Ease 'Cubic' 'EaseOut')))
    # background gradient drifts slowly
    foreach ($prop in @([Windows.Media.RadialGradientBrush]::CenterProperty, [Windows.Media.RadialGradientBrush]::GradientOriginProperty)) {
        $pa = New-Object Windows.Media.Animation.PointAnimation
        $pa.From = New-Object Windows.Point -ArgumentList 0.44, 0.42
        $pa.To = New-Object Windows.Point -ArgumentList 0.56, 0.5
        $pa.Duration = Get-Dur 7000; $pa.AutoReverse = $true
        $pa.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $pa.EasingFunction = New-Ease 'Sine' 'EaseInOut'
        $ui.bgGrad.BeginAnimation($prop, $pa)
    }
    # glow breathes and swells
    Start-Forever $ui.glow $op 0.35 0.95 3.6 $true
    Start-Forever $ui.glowScale ([Windows.Media.ScaleTransform]::ScaleXProperty) 0.92 1.08 5.0 $true
    Start-Forever $ui.glowScale ([Windows.Media.ScaleTransform]::ScaleYProperty) 0.92 1.08 5.0 $true
    # logo mark: pop in, ring spins, glow pulses
    Start-FadeSlide $ui.logoWrap 150 0 0 600
    $ui.logoScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (New-DAnim 0.5 1 760 150 (New-Ease 'Back' 'EaseOut')))
    $ui.logoScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (New-DAnim 0.5 1 760 150 (New-Ease 'Back' 'EaseOut')))
    Start-Forever $ui.ringRot ([Windows.Media.RotateTransform]::AngleProperty) 0 360 20 $false
    Start-Forever $ui.logoFx ([Windows.Media.Effects.DropShadowEffect]::BlurRadiusProperty) 16 42 2.4 $true
    # text cascade
    Start-FadeSlide $ui.lnTag 480 10 0 520
    $i = 0
    foreach ($l in $letters) { Start-FadeSlide $l (640 + $i * 130) -48 0 720; $i++ }
    Start-FadeSlide $ui.lnSub 1100 0 70 640
    Start-FadeSlide $ui.lnLine 1500 10 0 560
    # enter button: fade, pop, then a light sweep across it
    Start-FadeSlide $ui.btnEnter 1750 0 0 500
    Start-Pop $ui.btnEnter 1750 0.86 560
    try {
        $ui.btnEnter.ApplyTemplate()
        $hl = $ui.btnEnter.Template.FindName('hlStop', $ui.btnEnter)
        if ($hl) {
            $ka = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
            $ka.Duration = Get-Dur 3600
            $ka.BeginTime = Get-Span 2600
            $ka.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            foreach ($kf in @(@(0, 0), @(1, 1300), @(1, 3600))) {
                $f = New-Object Windows.Media.Animation.LinearDoubleKeyFrame
                $f.Value = [double]$kf[0]
                $f.KeyTime = [Windows.Media.Animation.KeyTime]::FromTimeSpan((Get-Span $kf[1]))
                [void]$ka.KeyFrames.Add($f)
            }
            $hl.BeginAnimation([Windows.Media.GradientStop]::OffsetProperty, $ka)
        }
    } catch { }
    # chips, footer, window buttons
    Start-FadeSlide $ui.chipA 2000 12 0 420
    Start-FadeSlide $ui.chipB 2100 12 0 420
    Start-FadeSlide $ui.chipC 2200 12 0 420
    Start-FadeSlide $ui.lnSys 2500 0 0 600
    Start-FadeSlide $ui.lnChrome 600 0 0 500
    Start-Particles
    Start-LandingAmbient
}

function Register-Events {
    $ui = $script:UI
    $win = $ui.Win

    # landing text
    $ui.lnTag.Text   = Space-Text 'ЗАМЕР  -  НАСТРОЙКА  -  ПРОВЕРКА'
    foreach ($ch in 'OTC'.ToCharArray()) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = [string]$ch
        $tb.FontFamily = 'Bahnschrift, Segoe UI Semibold'
        $tb.FontSize = 96
        $tb.FontWeight = 'SemiBold'
        $tb.Foreground = New-Object Windows.Media.SolidColorBrush -ArgumentList (Get-Color '#F4F4F4')
        $tb.Background = [Windows.Media.Brushes]::Transparent
        $tb.Margin = '0,0,12,0'
        $tb.Opacity = 0
        $tb.Add_MouseEnter({ param($s, $e)
            if (-not $script:AnimOn) { return }
            if ($s.RenderTransform -is [Windows.Media.TranslateTransform]) { $s.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-DAnim $s.RenderTransform.Y -10 150 0 (New-Ease))) }
            $ca = New-Object Windows.Media.Animation.ColorAnimation
            $ca.To = Get-Color '#8A8A8A'; $ca.Duration = Get-Dur 150
            $s.Foreground.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca)
        })
        $tb.Add_MouseLeave({ param($s, $e)
            if (-not $script:AnimOn) { return }
            if ($s.RenderTransform -is [Windows.Media.TranslateTransform]) { $s.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-DAnim $s.RenderTransform.Y 0 240 0 (New-Ease))) }
            $ca = New-Object Windows.Media.Animation.ColorAnimation
            $ca.To = Get-Color '#F4F4F4'; $ca.Duration = Get-Dur 260
            $s.Foreground.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca)
        })
        [void]$ui.lnTitle.Children.Add($tb)
    }
    $ui.lnSub.Text   = Space-Text 'OPTI'
    Set-EnterContent 'Подготовка...' $false
    $ui.btnEnter.IsEnabled = $false

    # window chrome and dragging
    $ui.landing.Add_MouseLeftButtonDown({ param($s, $e) if ($e.ChangedButton -eq 'Left') { Start-Ripple ($e.GetPosition($script:UI.landing)); Invoke-WindowDrag } })
    $ui.landing.Add_MouseMove({ param($s, $e) Invoke-Parallax ($e.GetPosition($script:UI.landing)) })
    $ui.header.Add_MouseLeftButtonDown({ param($s, $e) if ($e.ChangedButton -eq 'Left') { Invoke-WindowDrag } })
    $ui.lnMin.Add_Click({ $script:UI.Win.WindowState = 'Minimized' })
    $ui.appMin.Add_Click({ $script:UI.Win.WindowState = 'Minimized' })
    $ui.lnClose.Add_Click({ $script:UI.Win.Close() })
    $ui.appClose.Add_Click({ $script:UI.Win.Close() })
    $ui.btnEnter.Add_Click({ Invoke-Safe { Enter-App } 'Enter' })

    # navigation
    $navs = @{ navDash = 'dash'; navColor = 'color'; navOpt = 'opt'; navInternet = 'internet'; navRestore = 'restore'; navDebloat = 'debloat'; navStartup = 'startup'; navRust = 'rust'; navSession = 'session'; navClean = 'clean'; navSettings = 'settings'; navLog = 'log' }
    foreach ($n in $navs.Keys) {
        $ui[$n].Tag = $navs[$n]
        $ui[$n].Add_Checked({ param($s, $e) Move-NavHighlight $s; Start-Pop $s.Content.Children[0] 0 0.6 300; Invoke-Safe { Show-Page ([string]$s.Tag) } 'Navigation' })
    }

    # dashboard
    $ui.btnRescan.Add_Click({ Invoke-Safe { $script:FindingsDone = $false; Update-AllCards; Update-Dashboard } 'Rescan' })
    $ui.btnGoOpt.Add_Click({ Invoke-Safe { $script:UI.navOpt.IsChecked = $true; Select-Recommended } 'Review' })

    # optimize
    $ui.btnOptApply.Add_Click({ Invoke-Safe { Invoke-OptRun $true } 'Apply' })
    $ui.btnOptRevert.Add_Click({ Invoke-Safe { Invoke-OptRun $false } 'Revert' })
    $ui.btnOptRec.Add_Click({ Invoke-Safe { Select-Recommended } 'Select' })
    $ui.btnOptGame.Add_Click({ Invoke-Safe { Select-GameOptimizations } 'Gaming optimization selection' })
    $ui.btnOptKey.Add_Click({ Invoke-Safe { Invoke-KeyActivation } 'Key' })
    $ui.btnSetKey.Add_Click({ Invoke-Safe { Invoke-KeyActivation; Update-SettingsPage } 'Key' })
    $ui.btnLogout.Add_Click({ Invoke-Safe { Invoke-Logout } 'Logout' })
    $ui.btnAccount.Add_Click({ Invoke-Safe { $script:UI.navSettings.IsChecked = $true } 'Account' })
    foreach ($item in @(
        @{ Name = 'slColorBrightness'; Tag = 'Brightness' },
        @{ Name = 'slColorContrast'; Tag = 'Contrast' },
        @{ Name = 'slColorSaturation'; Tag = 'Saturation' },
        @{ Name = 'slColorExposure'; Tag = 'Exposure' },
        @{ Name = 'slColorGamma'; Tag = 'Gamma' }
    )) {
        $ui[$item.Name].Tag = $item.Tag
        $ui[$item.Name].Add_ValueChanged({ param($s, $e) ColorSlider_ValueChanged $s $e })
    }
    Update-ColorPremiumState
    Update-ColorProfiles
    $ui.btnColorPremium.Add_Click({ Invoke-Safe { Invoke-KeyActivation } 'Color license key' })
    $ui.btnColorVivid.Add_Click({ Invoke-Safe { $script:UI.slColorSaturation.Value = 125 } 'Color expressiveness preset' })
    $ui.btnColorSaveProfile.Add_Click({ Invoke-Safe { Save-ColorProfile } 'Save color profile' })
    $ui.btnColorLoadProfile.Add_Click({ Invoke-Safe { Load-ColorProfile } 'Load color profile' })
    $ui.btnColorDeleteProfile.Add_Click({ Invoke-Safe { Remove-ColorProfile } 'Delete color profile' })
    $ui.btnColorApply.Add_Click({
        Invoke-Safe {
            Apply-ColorFilter
            $script:UI.txtColorStatus.Text = 'Фильтр применён к основному дисплею. Исходные цвета восстановятся при закрытии приложения.'
            $script:UI.txtColorStatus.Foreground = Get-Res 'Good'
        } 'Display color filter'
    })
    $ui.btnColorRestore.Add_Click({
        Invoke-Safe {
            if (Restore-ColorFilter) {
                $script:UI.txtColorStatus.Text = 'Исходные цвета дисплея восстановлены.'
                $script:UI.txtColorStatus.Foreground = Get-Res 'Good'
                Write-Log 'Original primary display colors restored.' 'ok'
            } else {
                $script:UI.txtColorStatus.Text = 'Цветовой фильтр сейчас не применён.'
            }
        } 'Restore display colors'
    })
    $ui.chkRustHolo.Add_Click({
        if (-not (Test-Ultra)) {
            $script:UI.chkRustHolo.IsChecked = $false
            return
        }
        $script:UI.pnlRustHolo.Visibility = if ($script:UI.chkRustHolo.IsChecked) { 'Visible' } else { 'Collapsed' }
        Start-RustHoloAnimation
    })
    $ui.btnRustHoloPremium.Add_Click({ Invoke-Safe { Invoke-KeyActivation } 'Rust visual ULTRA key' })
    $ui.btnDiscord.Add_Click({ Invoke-Safe { Open-Link $env:OTC_DISCORD_URL 'Discord' } 'Discord' })
    $ui.btnWeb.Add_Click({ Invoke-Safe { Open-Link $env:OTC_WEB_URL 'сайт' } 'Web' })
    $ui.btnBuy.Add_Click({ Invoke-Safe { Open-Link $env:OTC_DISCORD_URL 'Discord' } 'Buy' })
    $ui.btnBuy2.Add_Click({ Invoke-Safe { Open-Link $env:OTC_DISCORD_URL 'Discord' } 'Buy' })
    $ui.btnQuick.Add_Click({ Invoke-Safe { if ($script:Ready) { Invoke-OptimizeAll } } 'Quick optimize' })
    $ui.btnOptClear.Add_Click({ foreach ($c in $script:Cards.Values) { $c.Switch.IsChecked = $false } })

    # rust
    foreach ($n in 'loHigh', 'loExcl', 'loCpu', 'loD3d', 'loLog') { $ui[$n].Add_Click({ Update-Launch }) }
    $ui.btnCopyLaunch.Add_Click({
        Invoke-Safe {
            [Windows.Clipboard]::SetText($script:UI.txtLaunch.Text)
            $script:UI.txtLaunchNote.Text = 'Скопировано. Вставьте в Steam > Rust > Свойства > Параметры запуска.'
            Write-Log 'Rust launch options copied to the clipboard.' 'ok'
        } 'Copy'
    })
    $ui.btnPreMax.Add_Click({ Invoke-Safe { Invoke-Preset 'Max' 'Макс. FPS' } 'Preset' })
    $ui.btnPreComp.Add_Click({ Invoke-Safe { Invoke-Preset 'Competitive' 'Соревновательный' } 'Preset' })
    $ui.btnPreBal.Add_Click({ Invoke-Safe { Invoke-Preset 'Balanced' 'Сбалансированный' } 'Preset' })
    $ui.btnPreRestore.Add_Click({
        try { Restore-RustCfg; $script:UI.txtPreStatus.Text = 'Original client.cfg restored.'; $script:UI.txtPreStatus.Foreground = Get-Res 'Good'; Write-Log 'Rust client.cfg restored from backup.' 'ok' }
        catch { $script:UI.txtPreStatus.Text = $_.Exception.Message; $script:UI.txtPreStatus.Foreground = Get-Res 'Warn' }
    })

    # session
    $ui.btnSesToggle.Add_Click({
        Invoke-Safe {
            if ($script:Session.Active) { $script:SessAutoStarted = $false; Stop-GameSession }
            else { $script:SessAutoStarted = $false; Start-GameSession (Get-SessionOptions) }
            Update-SessionUi
        } 'Session'
    })
    $ui.sesAuto.Add_Click({ Update-SessionUi })
    $ui.btnKill.Add_Click({
        Invoke-Safe {
            $names = @()
            foreach ($cb in $script:UI.pnlKill.Children) { if ($cb.IsChecked) { $names += $script:KillGroups[[string]$cb.Tag] } }
            if ($names.Count -eq 0) { Write-Log 'Группы приложений не отмечены.' 'warn'; return }
            $ans = [Windows.MessageBox]::Show('Закрыть отмеченные приложения сейчас? Несохранённые данные в них будут потеряны.', 'OTC OPTI', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { return }
            $script:UI.btnKill.IsEnabled = $false
            try { Close-BackgroundApps $names } finally { $script:UI.btnKill.IsEnabled = $true }
        } 'Close apps'
    })

    # cleaner
    $ui.btnScan.Add_Click({ Invoke-Safe { Start-CleanJob $false } 'Scan' })
    $ui.btnCleanRun.Add_Click({ Invoke-Safe { Start-CleanJob $true } 'Clean' })
    $ui.btnCleanRec.Add_Click({ foreach ($t in $script:CleanTasks) { $script:CleanChk[$t.Id].IsChecked = [bool]$t.Rec } })
    $ui.btnCleanNone.Add_Click({ foreach ($cb in $script:CleanChk.Values) { $cb.IsChecked = $false } })

    # log
    $ui.btnLogFile.Add_Click({ try { Start-Process notepad.exe -ArgumentList "`"$($script:LogFile)`"" } catch { } })
    $ui.btnLogClear.Add_Click({ $script:UI.logList.Items.Clear() })

    # animations switch and count-up proxy
    $ui.countProxy.Add_ValueChanged({ $script:UI.dApplied.Text = [string][int][math]::Round($script:UI.countProxy.Value) })
    $ui.swMotion.Add_Click({
        $script:AnimOn = [bool]$script:UI.swMotion.IsChecked
        Set-Ambient; Update-ApplyGlow; Update-Side
        try { Update-BgMotion } catch { }
        Start-ColorPageAnimations
        Start-RustHoloAnimation
        Write-Log ("Animations {0}." -f $(if ($script:AnimOn) { 'on' } else { 'off' })) 'info'
    })

    # debloat
    $ui.btnDbScan.Add_Click({ Invoke-Safe { Start-DebloatScan } 'Debloat scan' })
    $ui.btnDbSafe.Add_Click({ Select-DbRows 'safe' })
    $ui.btnDbAll.Add_Click({ Select-DbRows 'all' })
    $ui.btnDbNone.Add_Click({ Select-DbRows 'none' })
    $ui.btnDbRun.Add_Click({ Invoke-Safe { Start-DebloatRemove } 'Debloat' })

    # startup
    $ui.btnStRefresh.Add_Click({ Invoke-Safe { Build-StartupPage; Start-Stagger $script:UI.pnlStartup 12 30 0 10 } 'Startup refresh' })

    # lifecycle
    $win.Opacity = 0
    $win.Add_Loaded({ Start-LandingAnimations })
    $win.Add_Closing({
        param($s, $e)
        if ($script:AnimOn -and -not $script:CloseNow) { $e.Cancel = $true; $script:CloseNow = $true; Start-CloseAnim; return }
        try { $script:SessionTimer.Stop() } catch { }
        try { Stop-GameSession } catch { }
        try { if ($script:NativeOk) { [RomNative]::ReleaseTimer() } } catch { }
        try { [void](Restore-ColorFilter) } catch {
            Write-Log "Could not restore original display colors during shutdown: $($_.Exception.Message)" 'err'
            [void][Windows.MessageBox]::Show(
                "Не удалось восстановить исходные цвета дисплея. При следующем запуске восстановление будет повторено.`n`n$($_.Exception.Message)",
                'OTC OPTI', 'OK', 'Warning')
        }
    })
}

# ---- start -------------------------------------------------------------------------
$script:AnimOn = $false
try {
    Initialize-ColorFilter
    [void](New-AppWindow)
    Register-Events
    Register-ExtraEvents
    $script:UI.swMotion.IsChecked = $false
    $script:FindingsDone = $false
    $script:SessionTimer = New-Object Windows.Threading.DispatcherTimer
    $script:SessionTimer.Interval = [TimeSpan]::FromSeconds(3)
    $script:SessionTimer.Add_Tick({ if ($script:Ready) { try { Invoke-SessionTick } catch { } } })
    $script:SessionTimer.Start()
    $script:WasPremium = (Test-Premium)
    $script:LicTimer = New-Object Windows.Threading.DispatcherTimer
    $script:LicTimer.Interval = [TimeSpan]::FromSeconds(15)
    $script:LicTimer.Add_Tick({
        try {
            if ($script:WasPremium -and -not (Test-Premium)) {
                $script:WasPremium = $false
                $n = Invoke-LicenseRevert
                try {
                    if (Restore-ColorFilter) {
                        $script:UI.txtColorStatus.Text = 'Срок лицензии истёк — исходные цвета дисплея восстановлены.'
                        $script:UI.txtColorStatus.Foreground = Get-Res 'Good'
                        Write-Log 'License expired; original display colors restored.' 'ok'
                    }
                } catch {
                    $script:UI.txtColorStatus.Text = "Срок лицензии истёк, не удалось восстановить цвета: $($_.Exception.Message)"
                    $script:UI.txtColorStatus.Foreground = Get-Res 'Bad'
                    Write-Log "Could not restore display colors after license expiry: $($_.Exception.Message)" 'err'
                }
                $script:OptBuilt = $false
                $script:Cards = @{}
                if ($script:Ready) { Build-OptPage }
                Update-KeyButton
                Update-ColorPremiumState
                try { Update-DashStats } catch { }
                try { Update-SettingsPage } catch { }
                Show-Toast "Срок тарифа истёк. Откачено оптимизаций: $n" 'warn'
            }
        } catch { }
    })
    $script:LicTimer.Start()
    $script:UI.Win.Dispatcher.Add_UnhandledException({
        param($s, $e)
        try { Write-Log "Unexpected error: $($e.Exception.Message)" 'err' } catch { }
        $e.Handled = $true
    })
    $script:UI.Win.Add_ContentRendered({ if (-not $script:Prepared) { $script:Prepared = $true; Start-Prepare } })
    [void]$script:UI.Win.ShowDialog()
} catch {
    $msg = $_.Exception.Message
    try { Add-Content -LiteralPath $script:LogFile -Value ("{0} [fatal] {1}`n{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg, $_.ScriptStackTrace) } catch { }
    [void][Windows.MessageBox]::Show("OTC OPTI: произошла ошибка, продолжить невозможно:`n`n$msg`n`nПодробности сохранены в $($script:LogFile)", 'OTC OPTI', 'OK', 'Error')
}
