# PhotoUSBBackup v2.6 — Dedup + Resume Repair

This build keeps the v2.5 original-resource and GPS reconciliation design and fixes resume-created duplicates.

Before creating `_1`, `_2`, etc., v2.6 recursively searches the selected backup for the same original filename, filters by exact file size, and then compares SHA-256. If the bytes match, it adopts the existing file into the manifest and skips the new copy. A numbered filename is created only when same-name content is genuinely different.

The manifest and duplicate report are saved after every processed asset. Duplicate decisions are written to `PhotoUSBBackup-duplicate-report.json`. Existing `_1`/`_2` files are never automatically deleted.

The bundle identifier remains `com.paritosh.PhotoUSBBackup`. Build through the included GitHub Actions workflow and install `PhotoUSBBackup-v2.6-unsigned.ipa` over the existing AltStore app.
