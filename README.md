# PhotoUSBBackup v2 — Originals Only

Copies unmodified Photos originals to a user-selected external USB/SSD folder.

Features: PhotoKit original resources, full-size photo/video preference, Live Photo paired MOV, alternate/RAW resource preservation when exposed, iCloud original download, .partial writes, resume manifest, file-size verification, failure JSON log, iOS 26 continued-processing support.

## Build from Windows
1. Extract this ZIP.
2. Create a GitHub repository.
3. Upload all project files including `.github/workflows/build-ios.yml`.
4. Open Actions → Build iPhone IPA → Run workflow.
5. Download artifact `PhotoUSBBackup-v2-unsigned-ipa`.
6. Extract it to get `PhotoUSBBackup-v2-unsigned.ipa`.
7. Install using AltStore Classic / AltServer on Windows.

## Test first
Use a new empty USB folder, run a small backup, verify photos/videos open from the drive, stop and restart to confirm resume behavior, then run the whole library.

The app never deletes Photos-library items.
