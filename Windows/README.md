# StratagemDesk Public — Windows

Download this repository's Windows ZIP and extract the entire folder. Run `StratagemDeskPublic.exe`; keep all DLLs, `Artwork/`, `licenses/` and notices beside it. The portable x64 build includes .NET and does not require an SDK installation.

Hold **Ctrl+Alt+S**, enter a directional sequence, and press Enter when confirmation is enabled. Release the shortcut to hide the HUD. First review each operation, approve it, enable the entry and save. The catalog contains 115 game entries with bundled third-party icons and eight original desktop examples. Game entries start disabled with no operation steps; configure them before enabling. Existing desktop-example profiles remain available.

The editor supports batch enable/disable, independent default/current/saved profiles, workflow editing and testing, JSON import/export, sensitive-output redaction, timeout/cancellation, notifications and login startup. PowerShell uses `$args` for structured arguments. macOS actions and paths need rebinding on Windows.

Configuration, backups and the last-run log live under `%LOCALAPPDATA%\StratagemDesk-Public\`. The public edition has its own singleton and login entry. Custom configuration paths preserve parent-directory permissions; newly written app files use private ACLs. PowerShell payload files are private and cleaned after commands finish, cancel or fail to start; forced termination may leave private temporary files.

Only project-owned code, eight desktop examples and desk.* artwork use the project MIT license. The 115 game entries, zero.* icons and original upstream files are excluded from MIT. Source URLs, pinned revisions, hashes, copyright notices and unmodified upstream license ship in Artwork/game-data/, Artwork/game-icons-sources.json and Artwork/GAME_CONTENT_NOTICE.md. This candidate repository remains private. SharpVectors.Wpf and the .NET runtime retain their own notices. See `THIRD_PARTY.md`, `THIRD_PARTY.txt` and `licenses/`.

Automated builds, native tests and WPF smoke run on GitHub Actions Windows runners. Physical keyboard layouts, fullscreen, mixed DPI, lock/suspend and consumer desktop integration require manual acceptance. This preview is unsigned and does not elevate itself.

Artwork safety: importing configurations resets file-based image references to a bundled/default icon. Select a local image again after import. Only local drive files are loaded; UNC/network drives, device paths and reparse points are rejected. SVG external resources and processing instructions are blocked; PNG/JPEG/BMP decoding uses bounded local bytes. Invalid null presentation fields are rejected before configuration replacement.
