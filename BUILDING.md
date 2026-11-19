# Building a tvOS IPA

`scripts/build-tvos-ipa.sh` archives the `NuvioTV` scheme for a physical Apple TV and writes an `.ipa`. It runs on a Mac with Xcode. It does not run on Linux.

## Prerequisites

The script checks these and prints an install hint if one is missing.

- macOS and Xcode, with the tvOS platform installed (`sudo xcode-select -s /Applications/Xcode.app` if `xcodebuild` points at the command line tools only)
- Git, so the MPVKit submodule can be fetched
- Tuist, pinned in `mise.toml`. From the repo root: `mise install`, or `brew install tuist`
- Network access, the first time Swift packages are resolved

Clone with submodules:

```bash
git clone --recurse-submodules <repository-url> NuvioTVOS
cd NuvioTVOS
```

## Unsigned IPA (default)

```bash
./scripts/build-tvos-ipa.sh
```

This generates the Xcode project, resolves packages, archives Release for `generic/platform=tvOS` with code signing disabled, and zips `Payload/NuvioTV.app` into an IPA. The last line of output is the file to sideload:

```text
IPA: /path/to/NuvioTVOS/build-ipa/NuvioTV-<version>-unsigned-release.ipa
```

The IPA is ad-hoc signed with the Top Shelf App Group so a sideloader can re-sign it and the shelf can still see the feed. Set `NUVIO_IPA_OUTPUT_DIR` to write the IPA somewhere else.

## Signed IPA

With an Apple Developer team that can sign tvOS apps:

```bash
TEAM_ID=ABCDE12345 ./scripts/build-tvos-ipa.sh
```

The script writes an `ExportOptions.plist` (`method` = `development`, automatic signing, that team) and exports with `xcodebuild -exportArchive`. The last line is:

```text
IPA: /path/to/NuvioTVOS/build-ipa/NuvioTV-<version>.ipa
```

Certificates and provisioning profiles stay on the Mac. The script does not store signing secrets.
