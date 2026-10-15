#!/usr/bin/env python3
"""Compile the self-contained OTC OPTI Windows setup executable."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
APP_EXE = DIST / "OTC-OPTI.exe"
SETUP_SOURCE = ROOT / "setup" / "Setup.cs"
INSTALL_SCRIPT = ROOT / "setup" / "install.ps1"
UNINSTALL_SCRIPT = ROOT / "setup" / "uninstall.ps1"
MANIFEST = ROOT / "app.manifest"
OUTPUT = DIST / "OTC-OPTI-Setup-Admin.exe"


def find_compiler():
    windir = Path(os.environ.get("WINDIR", r"C:\Windows"))
    for relative in (
        Path("Microsoft.NET") / "Framework64" / "v4.0.30319" / "csc.exe",
        Path("Microsoft.NET") / "Framework" / "v4.0.30319" / "csc.exe",
    ):
        candidate = windir / relative
        if candidate.is_file():
            return candidate
    raise RuntimeError(".NET Framework 4.x C# compiler (csc.exe) was not found.")


def main():
    for source in (APP_EXE, SETUP_SOURCE, INSTALL_SCRIPT, UNINSTALL_SCRIPT, MANIFEST, ROOT / "otc.ico"):
        if not source.is_file():
            raise RuntimeError("Required setup input is missing: %s" % source)
    if APP_EXE.stat().st_size < 100_000:
        raise RuntimeError("The OTC OPTI executable is unexpectedly small.")

    DIST.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="OTC-OPTI-setup-build-") as temp:
        build = Path(temp) / "OTC-OPTI-Setup.exe"
        command = [
            str(find_compiler()),
            "/nologo",
            "/target:winexe",
            "/platform:anycpu",
            "/optimize+",
            "/out:" + str(build),
            "/win32icon:" + str(ROOT / "otc.ico"),
            "/win32manifest:" + str(MANIFEST),
            "/reference:System.Windows.Forms.dll",
            "/reference:System.Drawing.dll",
            "/resource:%s,OTC-OPTI.exe" % APP_EXE,
            "/resource:%s,install.ps1" % INSTALL_SCRIPT,
            "/resource:%s,uninstall.ps1" % UNINSTALL_SCRIPT,
            str(SETUP_SOURCE),
        ]
        result = subprocess.run(
            command,
            cwd=str(ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=120,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                "Installer compilation failed with exit code %s:\n%s"
                % (result.returncode, result.stdout[-6000:])
            )
        if not build.is_file() or build.stat().st_size <= APP_EXE.stat().st_size:
            raise RuntimeError("The compiler did not produce a complete setup executable.")
        with build.open("rb") as stream:
            if stream.read(2) != b"MZ":
                raise RuntimeError("The setup output is not a Windows executable.")

        os.replace(str(build), str(OUTPUT))

    print("Setup created: %s" % OUTPUT)
    print("Size: %s bytes" % OUTPUT.stat().st_size)
    print("Install location: %%LOCALAPPDATA%%\\Programs\\OTC OPTI")
    print("The setup includes OTC-OPTI.exe and preserves user license/settings.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("Setup build failed: %s" % error, file=sys.stderr)
        sys.exit(1)
