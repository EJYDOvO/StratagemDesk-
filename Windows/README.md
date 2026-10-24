# StratagemDesk — Windows

Download the Windows x64 ZIP from Releases and extract the entire folder. Run `StratagemDeskPublic.exe`; keep all DLLs, `Artwork/`, `licenses/` and notices beside it. The package includes the .NET runtime. This preview is unsigned.

## Use

Hold **Ctrl + Alt + S**, enter a direction sequence, and press Enter when confirmation is enabled. Release the shortcut to hide the HUD; an already started workflow continues.

Entries start disabled. Review and configure each operation, approve it, enable the entry and save. The catalog contains 115 game entries with icons and eight desktop examples. Game entries have no operation steps until you configure them.

The editor supports custom entries, batch enable/disable, independent default/current/saved profiles, workflow editing and testing, JSON import/export, sensitive-log hiding, timeouts, cancellation, notifications and login startup. PowerShell uses `$args` for structured arguments.

Imported entries are disabled and their operation approvals are revoked. File-based icon references reset to a default icon; select a local image again if needed. Network drives, UNC/device paths, file links and SVG external resources are not supported. macOS-specific actions and paths need reconfiguration.

## Configuration and safety

Configuration, backups and the last-run log live under `%LOCALAPPDATA%\StratagemDesk-Public\`.

Operations run with your current user permissions. Review scripts, arguments and target paths before approving them. Configuration files retain execution parameters; avoid storing or sharing passwords and tokens. See the repository’s `SECURITY.md` for reporting security issues.

## License

Project-owned code, eight desktop examples and `desk.*` icons use the project MIT license (`LICENSE` in the repository, `LICENSE.txt` in the application package). The 115 game entries, `zero.*` icons and original upstream files are excluded from that license and retain their original rights and terms. See `THIRD_PARTY.md` for sources and copyright details, and `THIRD_PARTY.txt` for SharpVectors notices. Runtime notices are included in the application package's `licenses/` folder.
