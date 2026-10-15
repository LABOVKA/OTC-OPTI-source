# OTC OPTI

OTC OPTI is a Windows desktop utility for system diagnostics, reversible
settings, gaming-session tools, and display color profiles.

## Build

Requirements:

- Windows with the .NET Framework 4.x C# compiler (`csc.exe`)
- Python 3
- Python package `cryptography` (`python -m pip install cryptography`)

Run `1-SESTAVIT.bat` to build `dist\OTC-OPTI.exe`. Run
`3-VYTVORIT-SETUP.bat` to build the per-user installer. Generated executables
are intentionally excluded from source control.

## License signing keys

Run `python keygen.py init` once to create a local P-256 signing key and set
the active public key in `Program.cs`. The private key and issued-key log are
stored under `%LOCALAPPDATA%\OTC OPTI\Signing`, outside the source tree. Keep
the private key offline and private; never publish it. Each public release
contains only public verification keys.

The application keeps retired public keys so previously issued licenses can
continue to validate after the active signing key is rotated.

## Color shader

`shaders\OTC-Vivid.fx` is a GPU post-processing shader with saturation,
selective vibrance, hue rotation, contrast, and blend controls. It is source
code only; OTC OPTI does not install or inject it into games. Use it only with
software and post-processing tools that explicitly allow ReShade. Do not
inject shaders or overlays into Rust or bypass Easy Anti-Cheat restrictions.
The built-in OTC OPTI color filter remains a reversible Windows display gamma
adjustment, not a game-specific GPU shader.

See `THIRD-PARTY-NOTICES.md` for source attribution.
