using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

static class Setup
{
    static TextBox installPath;
    static CheckBox desktopShortcut;
    static Button installButton;
    static Label status;

    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        Form form = new Form();
        form.Text = "OTC OPTI Setup";
        form.ClientSize = new Size(520, 310);
        form.MinimumSize = new Size(536, 349);
        form.StartPosition = FormStartPosition.CenterScreen;
        form.FormBorderStyle = FormBorderStyle.FixedDialog;
        form.MaximizeBox = false;
        form.MinimizeBox = false;
        try { form.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
        catch { }

        Label title = new Label();
        title.Text = "Nainstalovat OTC OPTI";
        title.Font = new Font("Segoe UI", 18, FontStyle.Bold);
        title.Location = new Point(28, 24);
        title.Size = new Size(455, 36);
        form.Controls.Add(title);

        Label description = new Label();
        description.Text = "Instalace pro tento účet Windows. Při spuštění potvrďte výzvu správce.";
        description.Font = new Font("Segoe UI", 9.5f);
        description.ForeColor = Color.FromArgb(91, 99, 120);
        description.Location = new Point(30, 68);
        description.Size = new Size(455, 42);
        form.Controls.Add(description);

        Label locationLabel = new Label();
        locationLabel.Text = "Umístění instalace";
        locationLabel.Font = new Font("Segoe UI", 9, FontStyle.Bold);
        locationLabel.Location = new Point(30, 126);
        locationLabel.Size = new Size(180, 22);
        form.Controls.Add(locationLabel);

        installPath = new TextBox();
        installPath.Text = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"Programs\OTC OPTI");
        installPath.Font = new Font("Segoe UI", 9);
        installPath.Location = new Point(30, 151);
        installPath.Size = new Size(365, 25);
        form.Controls.Add(installPath);

        Button browse = new Button();
        browse.Text = "Procházet...";
        browse.Font = new Font("Segoe UI", 9);
        browse.Location = new Point(405, 150);
        browse.Size = new Size(90, 27);
        browse.Click += delegate
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "Vyberte složku v uživatelském profilu.";
                dialog.SelectedPath = installPath.Text;
                if (dialog.ShowDialog(form) == DialogResult.OK)
                    installPath.Text = dialog.SelectedPath;
            }
        };
        form.Controls.Add(browse);

        desktopShortcut = new CheckBox();
        desktopShortcut.Text = "Vytvořit také zástupce na ploše";
        desktopShortcut.Checked = true;
        desktopShortcut.Font = new Font("Segoe UI", 9);
        desktopShortcut.Location = new Point(30, 192);
        desktopShortcut.Size = new Size(300, 25);
        form.Controls.Add(desktopShortcut);

        status = new Label();
        status.Text = "Licence a uživatelská nastavení zůstanou zachována.";
        status.Font = new Font("Segoe UI", 8.5f);
        status.ForeColor = Color.FromArgb(91, 99, 120);
        status.Location = new Point(30, 225);
        status.Size = new Size(460, 34);
        form.Controls.Add(status);

        installButton = new Button();
        installButton.Text = "Nainstalovat";
        installButton.Font = new Font("Segoe UI", 10, FontStyle.Bold);
        installButton.BackColor = Color.FromArgb(120, 89, 230);
        installButton.ForeColor = Color.White;
        installButton.FlatStyle = FlatStyle.Flat;
        installButton.FlatAppearance.BorderSize = 0;
        installButton.Location = new Point(354, 266);
        installButton.Size = new Size(140, 34);
        installButton.Click += InstallClicked;
        form.Controls.Add(installButton);

        form.AcceptButton = installButton;
        Application.Run(form);
    }

    static bool TryGetInstallPath(out string fullPath, out string error)
    {
        fullPath = null;
        error = null;
        try
        {
            string value = installPath.Text.Trim();
            if (value.Length == 0 || value.IndexOfAny(Path.GetInvalidPathChars()) >= 0)
                throw new ArgumentException("Zadejte platnou složku pro instalaci.");

            fullPath = Path.GetFullPath(value).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string localPrograms = Path.GetFullPath(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"))
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (!fullPath.StartsWith(localPrograms + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Pro instalaci bez práv správce vyberte složku uvnitř %LOCALAPPDATA%\\Programs.");

            if (fullPath.IndexOf('"') >= 0 || fullPath.IndexOf('\r') >= 0 || fullPath.IndexOf('\n') >= 0)
                throw new ArgumentException("Cesta obsahuje nepovolené znaky.");
            return true;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }

    static bool IsAppRunning(string targetExe)
    {
        Process[] processes = Process.GetProcessesByName("OTC-OPTI");
        try
        {
            foreach (Process process in processes)
            {
                try
                {
                    if (String.Equals(process.MainModule.FileName, targetExe,
                        StringComparison.OrdinalIgnoreCase))
                        return true;
                }
                catch (SystemException)
                {
                    throw new InvalidOperationException(
                        "Nelze ověřit, zda je OTC OPTI spuštěný. Zavřete jeho okno a spusťte instalaci znovu.");
                }
            }
            return false;
        }
        finally
        {
            foreach (Process process in processes) process.Dispose();
        }
    }

    static void InstallClicked(object sender, EventArgs args)
    {
        string destination;
        string error;
        if (!TryGetInstallPath(out destination, out error))
        {
            MessageBox.Show(error, "OTC OPTI Setup", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        try
        {
            if (IsAppRunning(Path.Combine(destination, "OTC-OPTI.exe")))
            {
                MessageBox.Show("Před instalací zavřete OTC OPTI a spusťte instalaci znovu.",
                    "OTC OPTI Setup", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "OTC OPTI Setup", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        installButton.Enabled = false;
        status.Text = "Instalace probíhá...";
        status.ForeColor = Color.FromArgb(91, 99, 120);
        bool noDesktopShortcut = !desktopShortcut.Checked;

        BackgroundWorker worker = new BackgroundWorker();
        worker.DoWork += delegate
        {
            Install(destination, noDesktopShortcut);
        };
        worker.RunWorkerCompleted += delegate(object completedSender, RunWorkerCompletedEventArgs completed)
        {
            installButton.Enabled = true;
            if (completed.Error != null)
            {
                status.Text = "Instalace se nezdařila.";
                status.ForeColor = Color.FromArgb(190, 43, 73);
                MessageBox.Show("Instalace se nezdařila:\r\n\r\n" + completed.Error.Message,
                    "OTC OPTI Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            status.Text = "OTC OPTI je nainstalován. Spusťte ho ze zástupce v nabídce Start.";
            status.ForeColor = Color.FromArgb(28, 142, 105);
            installButton.Text = "Hotovo";
            installButton.Click -= InstallClicked;
            installButton.Click += delegate { Application.Exit(); };
        };
        worker.RunWorkerAsync();
    }

    static void Install(string destination, bool noDesktopShortcut)
    {
        string temp = Path.Combine(Path.GetTempPath(), "OTC-OPTI-Setup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            ExtractResource("OTC-OPTI.exe", Path.Combine(temp, "OTC-OPTI.exe"));
            ExtractResource("install.ps1", Path.Combine(temp, "install.ps1"));
            ExtractResource("uninstall.ps1", Path.Combine(temp, "uninstall.ps1"));

            StringBuilder script = new StringBuilder();
            script.Append("& '").Append(PowerShellQuote(Path.Combine(temp, "install.ps1"))).Append("' ");
            script.Append("-InstallDir '").Append(PowerShellQuote(destination)).Append("' ");
            if (noDesktopShortcut) script.Append("-NoDesktopShortcut ");
            script.Append("; exit $LASTEXITCODE");

            string encodedCommand = Convert.ToBase64String(Encoding.Unicode.GetBytes(script.ToString()));
            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = powershell;
            start.Arguments = "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand " +
                encodedCommand;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;

            using (Process process = Process.Start(start))
            {
                if (process == null) throw new InvalidOperationException("PowerShell se nepodařilo spustit.");
                process.WaitForExit();
                if (process.ExitCode != 0)
                    throw new InvalidOperationException("Instalační proces skončil s chybou. Zkontrolujte instalační okno a oprávnění ke složce.");
            }
        }
        finally
        {
            try
            {
                if (Directory.Exists(temp)) Directory.Delete(temp, true);
            }
            catch { }
        }
    }

    static string PowerShellQuote(string value)
    {
        return value.Replace("'", "''");
    }

    static void ExtractResource(string name, string path)
    {
        using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (source == null)
                throw new InvalidDataException("V instalačním balíčku chybí soubor " + name + ".");
            using (FileStream destination = new FileStream(path, FileMode.CreateNew, FileAccess.Write))
                source.CopyTo(destination);
        }
    }
}
