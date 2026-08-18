# PhotoUSBBackup v2.4 — Originals + GPS

This build focuses on two goals:

1. Preserve the best available **unmodified/original Photos resource**.
2. Preserve **GPS and capture-date metadata** even when Photos stores that metadata separately from the file bytes.

## Resource strategy

Photo:
1. `.photo` — original
2. `.adjustmentBasePhoto` — fallback when available
3. `.fullSizePhoto` — last-resort rendered fallback

Video:
1. `.video` — original
2. `.adjustmentBaseVideo` — fallback when available
3. `.fullSizeVideo` — last-resort rendered fallback

Live Photo:
- still-image chain above
- `.pairedVideo` first
- `.fullSizePairedVideo` as fallback

Alternate photo resources are exported separately.

## PHPhotosErrorDomain -1 resilience

Each resource is attempted with PhotoKit `writeData` up to 3 times.
If that still fails, v2.4 uses `requestData` and streams the resource into the `.partial` file.

`isNetworkAccessAllowed = true` is enabled for both methods so iCloud-backed originals can be downloaded.

## GPS preservation

The actual HEIC/JPEG/RAW/MOV file is never rewritten, because injecting GPS into it would change the original bytes.

Instead, each exported file receives a sibling `.xmp` sidecar:

`IMG_1234.HEIC`
`IMG_1234.HEIC.xmp`

The sidecar stores:
- latitude
- longitude
- altitude when available
- Photos creation date
- Photos modification date
- Photos local asset identifier
- exported resource type
- whether the exported resource was `original`, `adjustmentBase`, or `renderedFallback`

The same data is also stored in `.PhotoUSBBackup-manifest.json`.

This gives you the original file plus a separate archival record of Photos-library GPS.

## Resume and safety

- writes go to `.partial` first
- completed files are size-verified
- manifest is saved every 20 assets
- existing verified files are skipped
- unrelated existing files are not overwritten
- failure details go to `PhotoUSBBackup-failures.json`

## Build on Windows

1. Extract this ZIP.
2. Upload all project contents to the existing GitHub repo.
3. Keep the same bundle ID: `com.paritosh.PhotoUSBBackup`.
4. GitHub → Actions → **Build iPhone IPA** → Run workflow.
5. Download `PhotoUSBBackup-v2.4-unsigned-ipa`.
6. Extract `PhotoUSBBackup-v2.4-unsigned.ipa`.
7. Install it over your existing app through AltStore.

Do not change the bundle ID between versions.

## How to judge the result

The app reports:
- `original` — preferred original resource succeeded
- `fallback` — original could not be retrieved and an adjustment-base/rendered resource was used
- `failed` — no candidate resource could be exported

For an archival backup, inspect the counts after the run. A high fallback count means the library/device could not provide many original resources at that time.
