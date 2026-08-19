# PhotoUSBBackup v3.2 — Album Copy

This is a simplified branch focused on copying the Photos album/folder structure already organized on the iPhone to an external USB/SSD.

## Features

- Select a top-level user album or Photos folder.
- Recursively recreate nested Photos folder/album structure on USB.
- Prefer the current full-size Photos rendition (`fullSizePhoto` / `fullSizeVideo`).
- Fall back to the ordinary photo/video resource when needed.
- Allow iCloud download.
- Stage one asset at a time in the app's local temporary directory.
- Copy to `filename.partial` on USB first.
- Verify byte size before final rename.
- Resume with a simple skip: if the final file already exists and is non-zero, skip it.
- Keep only the most recent 30 failures in UI memory.
- Reuse the same bundle ID: `com.paritosh.PhotoUSBBackup`.

## Important

Photos albums are references, not physical storage folders. If one photo appears in multiple albums, it will be copied into each corresponding USB album folder.

This branch intentionally does not perform the old GPS reconciliation, RAW/original recovery, metadata-dispute folders, or SHA-256 dedup logic. The priority is reliable copying of the already-organized album structure.

## Windows build

1. Extract this ZIP.
2. Upload the contents to the existing GitHub repository.
3. Open GitHub → Actions → **Build iPhone IPA**.
4. Run the workflow.
5. Download `PhotoUSBBackup-v3.0-Album-Copy-unsigned-ipa`.
6. Extract the artifact to get the IPA.
7. Install with AltStore.

## First test

Use one small album/folder first. Confirm the USB hierarchy matches Photos, files open correctly, and a second run reports the existing files as skipped.


## v3.0.1 USB streaming fix

v3.0.1 keeps the v3.0 album-copy design unchanged and replaces only the
local-temp → USB copy operation.

Old path:

`local temp -> FileManager.copyItem -> USB .partial`

New path:

`local temp -> 1 MiB streamed chunks -> USB .partial -> flush/close -> size verify -> rename -> final size verify`

Failure messages now identify the exact stage and include the underlying
NSError domain, code, and message, for example:

`USB write USB failed for IMG_3053.MOV.partial [NSCocoaErrorDomain 512]: ...`

This makes external-drive failures much easier to diagnose.

## v3.2 collision-safe filenames

Every exported asset now receives a deterministic filename suffix derived from its Photos local identifier. Distinct assets that share generic names such as `FullSizeRender.jpeg` can no longer overwrite or falsely skip one another. The same asset receives the same name on later runs, so same-size restart skipping remains available.
