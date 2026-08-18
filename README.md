# PhotoUSBBackup v2.8 — Fast Skip + Collision-Only Dedup

v2.8 is tuned for large libraries where many files are already backed up.

## Performance strategy

### Fast path: known completed files

For each Photos resource, v2.8 checks the manifest first.

If:
- asset identifier matches,
- resource type matches,
- recorded file exists,
- file size matches,

the resource is skipped immediately.

No PhotoKit fetch.
No staging.
No recursive search.
No SHA-256.

### New files

If the manifest does not know the resource and there is no same-name file in the destination index:

- fetch original,
- copy normally,
- record file size/path,
- no SHA-256.

### Collision-only verification

SHA-256 is used only when a same-name file already exists and the app would otherwise create `_1`, `_2`, etc.

Process:

1. compare byte sizes,
2. if size differs -> genuine conflict,
3. if size matches -> hash staged file and same-name candidate,
4. identical -> adopt existing file + skip,
5. different -> create `_1`, `_2`, etc.

This keeps strong duplicate protection without hashing thousands of routine files.

## One-time filename index

At backup start, v2.8 scans existing backup files once and builds an in-memory filename index.

After that, same-name lookups are fast dictionary lookups instead of repeated recursive SSD scans.

Newly created files are added to the index immediately.

## Resume

Manifest is saved every 5 processed assets and again on stop/completion.

## GPS/original logic retained

- `.photo` / `.video` original resources first
- retries + `requestData` streaming fallback
- iCloud network access
- Live Photo paired resource handling
- GPS comparison
- `Originals/`
- `Metadata-Disputed/Original/`
- `Metadata-Disputed/GPS-Merged/`
- XMP fallback for unsupported merge formats

## Duplicate report

Collision decisions are recorded in:

`PhotoUSBBackup-duplicate-report.json`

The app does not automatically delete old `_1` / `_2` files.

## Windows build

1. Extract the ZIP.
2. Upload all project contents over your existing GitHub repo.
3. Keep the bundle ID unchanged:
   `com.paritosh.PhotoUSBBackup`
4. GitHub -> Actions -> Build iPhone IPA.
5. Download `PhotoUSBBackup-v2.8-unsigned-ipa`.
6. Extract `PhotoUSBBackup-v2.8-unsigned.ipa`.
7. Install over the existing app through AltStore.


## v2.8 local staging fix

v2.8 preserves the v2.7 feature set and changes the PhotoKit staging path:

`PhotoKit/iCloud -> app local temporary directory -> verify -> USB .partial -> verify -> final rename`

This avoids asking `PHAssetResourceManager.requestData()` to stream directly into a security-scoped external-drive staging path. It specifically targets the prior failure pattern where PhotoKit returned `PHPhotosErrorDomain error -1` and the stream fallback then reported that the external `.partial` file did not exist.

All v2.7 GPS reconciliation, metadata-dispute handling, fast manifest skip, SHA-256 collision deduplication, duplicate reporting, resume behavior, and original-resource fallback logic are intended to remain unchanged.
