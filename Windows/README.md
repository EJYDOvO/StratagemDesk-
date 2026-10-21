# StratagemDesk Public — Windows

Download this repository's Windows ZIP and extract the entire folder. Run `StratagemDeskPublic.exe`; keep all DLLs, `Artwork/`, `licenses/` and notices beside it. The portable x64 build includes .NET and does not require an SDK installation.

Hold **Ctrl+Alt+S**, enter a directional sequence, and press Enter when confirmation is enabled. Release the shortcut to hide the HUD. First review each operation, approve it, enable the entry and save. Defaults use eight original desktop examples with original geometric icons; no game catalog or game artwork is bundled.

The editor supports batch enable/disable, independent default/current/saved profiles, workflow editing and testing, JSON import/export, sensitive-output redaction, timeout/cancellation, notifications and login startup. PowerShell uses `$args` for structured arguments. macOS actions and paths need rebinding on Windows.

Configuration, backups and the last-run log live under `%LOCALAPPDATA%\StratagemDesk-Public\`. The public edition has its own singleton and login entry. Custom configuration paths preserve parent-directory permissions; newly written app files use private ACLs. PowerShell payload files are private and cleaned after commands finish, cancel or fail to start; forced termination may leave private temporary files.

The MIT project license and original artwork notice ship with the application. SharpVectors.Wpf and the .NET runtime retain their own notices. See `THIRD_PARTY.md`, `THIRD_PARTY.txt` and `licenses/`.

Automated builds, native tests and WPF smoke run on GitHub Actions Windows runners. Physical keyboard layouts, fullscreen, mixed DPI, lock/suspend and consumer desktop integration require manual acceptance. This preview is unsigned and does not elevate itself.
