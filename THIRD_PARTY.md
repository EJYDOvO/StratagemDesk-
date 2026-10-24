# Licensing scope and third-party content

**The root MIT license covers project-owned code and original desktop demonstrations only. It does not cover bundled game catalog data, game icons, upstream files or third-party dependencies.** Attribution and MIT exclusion do not create additional permission or establish readiness for public distribution.

## Project-owned MIT content

Copyright (c) 2026 EJYDOvO. Project-owned Swift/C# code, `Sources/StratagemCore/Resources/desktop-examples.json` and eight original `desk.*.svg` geometric icons are MIT licensed. Their license is also in `Artwork/ORIGINAL-DESKTOP-LICENSE.txt`. Those eight icons contain no copied game art or extracted fonts.

## Game content — excluded from project MIT

The following content is **not licensed by this project's MIT license**:

- `Sources/StratagemCore/Resources/builtins.json`: all 115 derived game catalog entries.
- `Sources/StratagemCore/Artwork/zero.*.svg`: all 115 third-party game icon files.
- `Sources/StratagemCore/Artwork/game-data/**`: original upstream JSON, original license and provenance.
- `Sources/StratagemCore/Artwork/game-icons-sources.json` and game entries in the mixed `sources.json` and `index.json`: attribution/mappings, not an additional grant of rights.

### Stratagem Zero data

- Authors: Stratagem Zero Authors. Game names/content retain their respective owners' rights.
- Repository: https://github.com/aslepenkov/stratagem-zero
- Fixed revision: `c6654bacff48373214e6136ecc7a1269daefaae2`.
- Data: https://github.com/aslepenkov/stratagem-zero/blob/c6654bacff48373214e6136ecc7a1269daefaae2/data/stratagems.json
- License: https://github.com/aslepenkov/stratagem-zero/blob/c6654bacff48373214e6136ecc7a1269daefaae2/LICENSE
- Reuse: 115 names/direction sequences and six original icon URL mappings; no Go application code. IDs, browsing categories and system-symbol fallbacks are local metadata, not official classifications.
- Upstream labels its license MIT, but its text includes `Copyright (a)` and `subject to sunshine conditions`. It is retained **verbatim**, without replacement or relicensing, in `Artwork/game-data/StratagemZero-LICENSE.txt`. The unusual wording remains unconfirmed.
- Original JSON, pinned URLs and SHA-256 hashes are in `Artwork/game-data/`. The entire derived game catalog is excluded from this project's MIT scope.

### Game SVG artwork

- **109 entries**: Nicolas Vigneux / contributors, https://github.com/nvigneux/Helldivers-2-Stratagems-icons-svg at `69f5cd62ad4b815a0eeb04bab672e1731ed95aa5`.
- That README states: "Feel free to use them in your own projects !" No formal LICENSE was identified. We retain this usage statement without treating it as MIT or proof of rights in the underlying game artwork.
- **6 entries**: original https://helldivers.wiki.gg/ SVG URLs in the pinned Stratagem Zero data (four distinct image URLs). Individual image licenses remain unconfirmed.
- Exact filenames, source URLs and SHA-256 hashes: `Artwork/game-icons-sources.json`. The mixed `Artwork/sources.json` marks each game entry `projectMitApplies: false`. The local `LicenseRef-ThirdParty-Game-Content` label is not a standard license or permission grant.
- HELLDIVERS names, designs and artwork retain their respective game copyright/trademark holders' rights; SVG contributions retain their authors' applicable rights. This unofficial desktop command launcher claims no ownership or endorsement.

Game data and images are bundled for offline use. No game screenshots or extracted fonts are included. Both application distributions include this document, `Artwork/NOTICE.txt`, `Artwork/GAME_CONTENT_NOTICE.md`, the original upstream license and provenance. Runtime image loading is local, without a downloader.

## Windows dependencies

- **SharpVectors.Wpf 1.8.6**: BSD-3-Clause, used for SVG rendering. Original copyright, terms, disclaimer and included Brotli/MinIoC notices remain in `Windows/THIRD_PARTY.txt` and the Windows distribution. Source: https://github.com/ElinamLLC/SharpVectors .
- **.NET / WPF runtime**: retains its own upstream terms; LICENSE and THIRD-PARTY-NOTICES files ship in Windows `licenses/`. Sources: https://github.com/dotnet/runtime and https://github.com/dotnet/wpf .
- MSTest and Microsoft.NET.Test.Sdk are build/test dependencies, not included in the application ZIP.

macOS uses system frameworks and system fonts. User-imported artwork, scripts and configurations are not automatically covered by this project's MIT license.
