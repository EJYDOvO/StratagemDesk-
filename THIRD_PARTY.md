# Licensing scope

Copyright (c) 2026 EJYDOvO. Project-owned Swift/C# code, desktop demonstration catalog and eight original geometric SVGs are MIT licensed. The SVGs are simple vector geometry authored for this edition; no third-party shapes, game icons, fonts or images were copied into them.

## Included Windows dependencies

- **SharpVectors.Wpf 1.8.6**: BSD-3-Clause. Used for SVG rendering. The original copyright, conditions and disclaimer are preserved in `Windows/THIRD_PARTY.txt` and the Windows distribution. Its included Brotli and MinIoC notices are preserved there as well. Source: https://github.com/ElinamLLC/SharpVectors .
- **.NET / WPF runtime**: redistributed under their own upstream terms with LICENSE and THIRD-PARTY-NOTICES files in the Windows `licenses/` directory. The project MIT license does not replace those terms. Source: https://github.com/dotnet/runtime and https://github.com/dotnet/wpf .
- MSTest and Microsoft.NET.Test.Sdk are build/test dependencies and are not included in the application ZIP. They retain their upstream licenses.

macOS uses system frameworks and system fonts. No extracted font files are distributed.

## Deliberately excluded

No game SVGs, game catalog data, upstream game-data JSON, historical screenshots, game-art manifests or old distribution packages are included. The excluded data source described itself as MIT but its actual license contained nonstandard wording; the excluded icon project had no formal LICENSE, and individual Wiki image rights were unconfirmed. Rather than relicense those materials, this edition supplies new desktop examples and original artwork.

User-supplied local artwork, scripts and imported configurations remain the user's responsibility and are not automatically covered by this repository's MIT license.
