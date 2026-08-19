# PhotoUSBBackup v3.7.5 — Album Copy

This is a simplified branch focused on copying the Photos album/folder structure already organized on the iPhone to an external USB/SSD.

## Features

- Select a top-level user album or Photos folder.
- Recursively recreate nested Photos folder/album structure on USB.
- Copy the original Photos resource (`photo` / `video`) so edited or rendered versions are not substituted in a backup.
- Fall back to the adjustment base and then the current full-size rendition only when Photos does not expose the original resource.
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

## v3.7 background Wi-Fi transfers

- Wi-Fi assets are staged into durable Application Support storage before upload.
- A persistent background `URLSession` hands file uploads to iOS so queued transfers can continue when another app is opened or the screen locks.
- The same receiver `/health`, `/check`, and `/upload` protocol is preserved; no PC receiver update is required.
- Active tasks are restored when iOS relaunches the app after normal system termination.
- The transfer screen separately displays preparation progress, current-file bytes, saved, queued, skipped, and failed totals.
- Pausing stops new preparation while uploads already handed to iOS continue safely.

iOS cancels background transfers if the user explicitly swipes the app away from the app switcher. Reopen Album Copy and use Resume Transfer after a force quit.

### v3.7.1 progress-screen fixes

- Finished preparation now shows **Uploads Running** instead of exposing a Resume button while queued uploads are active.
- Resume is available only when preparation actually stopped before reaching the end of the selected source.
- Fast-changing filenames stay on one fixed-height, middle-truncated line, and status text reserves a stable height so the transfer screen no longer jumps.

### v3.7.2 queue controls

- **Pause All Operations** suspends queued background upload tasks and stops further photo preparation without deleting staged files.
- **Resume All Operations** resumes the same upload tasks and continues incomplete preparation.
- **Stop Transfer and Clear Queue** requires confirmation, cancels queued tasks, and removes only their staged app files; completed files on the PC remain untouched.
- User-cancelled task callbacks are excluded from the failed counter.

### v3.7.3 accurate transfer indicator

- The main progress bar now counts only files newly saved on the PC plus same-size files verified as already present.
- Photo preparation and queued background uploads are displayed as separate values, so completing preparation can no longer make the transfer appear finished.
- The progress screen uses the same **Complete on PC** definition and does not count failed files as successful completion.

### v3.7.4 true preparation resume

- Each processed item is tracked by its Photos album identifier plus asset identifier for the lifetime of the transfer.
- Resume skips those identifiers before staging or checking the receiver, instead of rereading the selected source from item 1.
- The prepared counter is derived from the unique processed-item set and cannot exceed the selected-source total.
- Choosing a different source, starting a genuinely new transfer, or confirming Stop clears the resume set.

### v3.7.5 original media and size integrity

- Photo and video staging now explicitly selects the original Photos resource before any adjusted or rendered resource.
- The PC receiver continues to accept a file only after the received byte count exactly matches the staged source byte count.
- Compare exact byte counts when checking sizes. iPhone commonly displays decimal GB while Windows displays binary GiB values but labels them GB; for example, 6.4 billion bytes is about 5.96 GiB.

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
