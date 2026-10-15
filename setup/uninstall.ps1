param(
    [string]$InstallDir = $PSScriptRoot,
    [switch]$NoIntegration,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

try {
    $installPath = [IO.Path]::GetFullPath($InstallDir)
    $programFiles = [IO.Path]::GetFullPath($env:ProgramFiles)
    $localPrograms = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs'))
    if (-not $installPath.StartsWith($localPrograms + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $installPath.StartsWith($programFiles, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cesta instalace je mimo očekávanou uživatelskou složku; odstranění bylo zrušeno.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $installPath 'OTC-OPTI.exe') -PathType Leaf)) {
        throw 'Ve složce nebyla nalezena instalace OTC OPTI.'
    }

    if (-not $NoIntegration -and -not $Quiet) {
        $answer = [Windows.Forms.MessageBox]::Show(
            'Opravdu chcete odinstalovat OTC OPTI? Uživatelské nastavení a licence zůstanou zachovány.',
            'Odinstalovat OTC OPTI',
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { exit 0 }
    }

    $installedExe = Join-Path $installPath 'OTC-OPTI.exe'
    $running = @(Get-Process -Name 'OTC-OPTI' -ErrorAction SilentlyContinue | Where-Object {
        try { [string]::Equals($_.Path, $installedExe, [StringComparison]::OrdinalIgnoreCase) }
        catch { $false }
    })
    if ($running.Count -gt 0) {
        if ($Quiet) {
            Write-Error 'Před odinstalací zavřete OTC OPTI.'
        } else {
            [void][Windows.Forms.MessageBox]::Show(
                'Před odinstalací zavřete OTC OPTI a spusťte odinstalaci znovu.',
                'Odinstalovat OTC OPTI',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Information)
        }
        exit 1
    }

    if (-not $NoIntegration) {
        $shortcuts = @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\OTC OPTI\OTC OPTI.lnk'),
            (Join-Path ([Environment]::GetFolderPath('Desktop')) 'OTC OPTI.lnk')
        )
        foreach ($shortcut in $shortcuts) {
            if (Test-Path -LiteralPath $shortcut) {
                Remove-Item -LiteralPath $shortcut -Force
            }
        }
        $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\OTC OPTI'
        if (Test-Path -LiteralPath $startMenu) {
            Remove-Item -LiteralPath $startMenu -Force
        }
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree(
            'Software\Microsoft\Windows\CurrentVersion\Uninstall\OTC-OPTI',
            $false)
    }

    $cleanupCommand = '$parent = Get-Process -Id {0} -ErrorAction SilentlyContinue; if ($parent) {{ $parent.WaitForExit() }}; Remove-Item -LiteralPath ''{1}'' -Recurse -Force' -f $PID, $installPath.Replace("'", "''")
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupCommand))
    [void](Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encodedCommand
    ) -WindowStyle Hidden -PassThru)
    if (-not $Quiet) {
        [void][Windows.Forms.MessageBox]::Show(
            'OTC OPTI byl odinstalován. Licence a nastavení zůstávají v uživatelském profilu.',
            'Odinstalovat OTC OPTI',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information)
    }
    exit 0
} catch {
    [void][Windows.Forms.MessageBox]::Show(
        ("Odinstalace se nezdařila:`n`n{0}" -f $_.Exception.Message),
        'Odinstalovat OTC OPTI',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
