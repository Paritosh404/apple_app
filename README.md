# PhotoUSBBackup v2.2 — Originals Only

This build fixes the Photos-permission crash by defining
`NSPhotoLibraryUsageDescription` in both:

1. `project.yml` through XcodeGen `info.properties`
2. the physical `PhotoUSBBackup/Info.plist`

The GitHub Actions workflow also verifies the privacy key twice:
- before compilation
- inside the final built `.app`

If either check fails, the workflow stops instead of producing a broken IPA.

## Main features

- Exports unmodified Photos originals using PhotoKit.
- Prefers `fullSizePhoto` / `fullSizeVideo`.
- Includes Live Photo paired video.
- Includes alternate photo resources when exposed by Photos.
- Allows iCloud originals to download.
- Uses `.partial` writes.
- Renames only after successful completion.
- Verifies output file size.
- Keeps a resume manifest on the destination drive.
- Preserves unrelated existing files rather than overwriting them.
- Logs failed items.
- Uses iOS 26 continued-processing support where available.

## Build from Windows

1. Extract this ZIP.
2. Create or update your GitHub repository.
3. Upload all project contents, including `.github`.
4. Open GitHub → Actions.
5. Run **Build iPhone IPA**.
6. Wait for all steps to turn green.
7. Download artifact:
   `PhotoUSBBackup-v2.1-unsigned-ipa`
8. Extract it to get:
   `PhotoUSBBackup-v2.1-unsigned.ipa`
9. Sideload through AltStore.

## Important

Delete the previous crashing build from the iPhone before installing v2.1.

On first launch, tap **Allow Photos Access**. iOS should now show the system Photos-permission dialog instead of terminating the app.

For the first test:
- use a fresh test folder on the USB/SSD,
- copy a small sample,
- verify normal photos, videos, and Live Photos,
- then run the full library.


## v2.2 startup fix

v2.2 no longer waits for `BGContinuedProcessingTask` to launch before copying.

When **Start Originals Backup** is tapped:

1. `isRunning` becomes true immediately, disabling the Start button.
2. The Photos library is fetched immediately.
3. The asset counter appears.
4. Copying begins immediately in the foreground.
5. A continued-processing request is submitted separately for background eligibility.
6. A delayed background callback cannot start a duplicate transfer.

This fixes the v2.1 symptom where the UI could remain on
`Starting originals backup…` with no files copied while the Start button
remained tappable.
