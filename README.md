# QLCAD

A macOS Quick Look extension and viewer for STEP CAD files (`.step` / `.stp`). Press Space on a
file in Finder to rotate and inspect the model, and get 3D thumbnails in Finder.

## Build

You need macOS on Apple Silicon, the Xcode Command Line Tools, and CMake through
[mise](https://mise.jdx.dev/).

```sh
./scripts/build_occt.sh   # once: downloads and compiles Open CASCADE Technology
./scripts/build.sh        # builds build/QLCAD.app
./scripts/install.sh      # installs to ~/Applications and registers the extensions
./scripts/make_dmg.sh     # optional: builds the release files in build/
```

## Licence

QLCAD's own code is under the [MIT License](LICENSE).

QLCAD uses [Open CASCADE Technology](https://dev.opencascade.org/) (OCCT), which is statically
linked into the app. OCCT and its use in QLCAD are covered by the
[GNU LGPL 2.1](LICENSES/LGPL-2.1.txt) with the
[Open CASCADE exception](LICENSES/OCCT_LGPL_EXCEPTION.txt). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for all notices and for how to relink the app
against a modified OCCT.

## Publishing a release

The LGPL requires OCCT's source to be offered from the same place as the app. Attach both of these
files from `build/` to each GitHub release:

- `QLCAD.dmg`
- `OCCT-source.tar.gz`
