param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\OTC OPTI'),
    [switch]$NoIntegration,
    [switch]$NoDesktopShortcut,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

function Show-InstallError {
    param([string]$Message)
    if ($Quiet) { Write-Error $Message; return }
    [void][Windows.Forms.MessageBox]::Show(
        $Message,
        'OTC OPTI Setup',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error)
}

try {
    $sourceExe = Join-Path $PSScriptRoot 'OTC-OPTI.exe'
    if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) {
        throw 'Instalační soubory jsou neúplné. Znovu stáhněte OTC-OPTI-Setup.exe.'
    }

    $installPath = [IO.Path]::GetFullPath($InstallDir)
    $programFiles = [IO.Path]::GetFullPath($env:ProgramFiles)
    if ($installPath.StartsWith($programFiles, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OTC OPTI Setup je per-user instalátor. Zvolte cestu v uživatelském profilu.'
    }

    $existingExe = Join-Path $installPath 'OTC-OPTI.exe'
    if (Test-Path -LiteralPath $existingExe -PathType Leaf) {
        $running = @(Get-Process -Name 'OTC-OPTI' -ErrorAction SilentlyContinue | Where-Object {
            try { [string]::Equals($_.Path, $existingExe, [StringComparison]::OrdinalIgnoreCase) }
            catch { $false }
        })
        if ($running.Count -gt 0) {
            [void][Windows.Forms.MessageBox]::Show(
                'Před instalací zavřete OTC OPTI a spusťte instalátor znovu.',
                'OTC OPTI Setup',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Information)
            exit 1
        }
    }

    [void][IO.Directory]::CreateDirectory($installPath)
    $destinationExe = Join-Path $installPath 'OTC-OPTI.exe'
    $temporaryExe = Join-Path $installPath ('OTC-OPTI.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $sourceExe -Destination $temporaryExe -Force
        if (Test-Path -LiteralPath $destinationExe) {
            $backupExe = Join-Path $installPath ('OTC-OPTI.' + [Guid]::NewGuid().ToString('N') + '.bak')
            try {
                [IO.File]::Replace($temporaryExe, $destinationExe, $backupExe)
                Remove-Item -LiteralPath $backupExe -Force
            } finally {
                if (Test-Path -LiteralPath $backupExe) {
                    Remove-Item -LiteralPath $backupExe -Force
                }
            }
        } else {
            [IO.File]::Move($temporaryExe, $destinationExe)
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryExe) {
            Remove-Item -LiteralPath $temporaryExe -Force
        }
    }

    $uninstallerSource = Join-Path $PSScriptRoot 'uninstall.ps1'
    if (Test-Path -LiteralPath $uninstallerSource -PathType Leaf) {
        Copy-Item -LiteralPath $uninstallerSource -Destination (Join-Path $installPath 'uninstall.ps1') -Force
    }

    if (-not $NoIntegration) {
        $shell = New-Object -ComObject WScript.Shell
        $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\OTC OPTI'
        [void][IO.Directory]::CreateDirectory($startMenu)

        $shortcutPaths = @((Join-Path $startMenu 'OTC OPTI.lnk'))
        if (-not $NoDesktopShortcut) {
            $shortcutPaths += Join-Path ([Environment]::GetFolderPath('Desktop')) 'OTC OPTI.lnk'
        }
        foreach ($shortcutPath in $shortcutPaths) {
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $destinationExe
            $shortcut.WorkingDirectory = $installPath
            $shortcut.Description = 'OTC OPTI'
            $shortcut.IconLocation = "$destinationExe,0"
            $shortcut.Save()
        }

        $uninstallKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(
            'Software\Microsoft\Windows\CurrentVersion\Uninstall\OTC-OPTI')
        try {
            $uninstallCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
                (Join-Path $installPath 'uninstall.ps1') + '"'
            $uninstallKey.SetValue('DisplayName', 'OTC OPTI', [Microsoft.Win32.RegistryValueKind]::String)
            $uninstallKey.SetValue('DisplayIcon', $destinationExe, [Microsoft.Win32.RegistryValueKind]::String)
            $uninstallKey.SetValue('Publisher', 'OTC OPTI', [Microsoft.Win32.RegistryValueKind]::String)
            $uninstallKey.SetValue('UninstallString', $uninstallCommand, [Microsoft.Win32.RegistryValueKind]::String)
            $uninstallKey.SetValue('InstallLocation', $installPath, [Microsoft.Win32.RegistryValueKind]::String)
            $uninstallKey.SetValue('NoModify', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
            $uninstallKey.SetValue('NoRepair', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        } finally {
            $uninstallKey.Dispose()
        }
    }

    $shortcutMessage = if ($NoDesktopShortcut) { 'Zástupce najdete v nabídce Start.' } else { 'Zástupce najdete na ploše a v nabídce Start.' }
    if (-not $Quiet) {
        [void][Windows.Forms.MessageBox]::Show(
            ("Instalace OTC OPTI je dokončena.`n`nUmístění: {0}`n{1}" -f $installPath, $shortcutMessage),
            'OTC OPTI Setup',
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information)
    }
    exit 0
} catch {
    Show-InstallError ("Instalace se nezdařila:`n`n{0}" -f $_.Exception.Message)
    exit 1
}
