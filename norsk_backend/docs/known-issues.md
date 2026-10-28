# Known issues

Found while refactoring.

## Worth fixing

1. **Real-looking credentials in `.env.example`.** It contains a personal email,
   a bootstrap password and an `APP_SECRET`. If those values are (or were) used
   in a real `.env`, change them. Anyone who sees the example file can log in
   as admin or forge tokens. Replace them with placeholders.

## Fixed

These have regression tests in `tests/test_recording_lifecycle.py`.

- **Couldn't delete a recording whose audio file was missing** (500 error).
  `storage.delete()` now does nothing if the file is already gone, in both the
  local and Google Drive backends.
- **Deleting a recording during transcription brought it back.** The worker now
  checks the recording and that language's audio still exist before saving its
  result (`worker.save_result`). The usage record is still written, because
  the AI minutes were spent.
- **Worker restart mid-transcription left a recording stuck in `processing`.**
  At startup the worker now puts any `processing` audio back to `pending`
  (`worker.recover_interrupted_jobs`). This relies on there being only one worker.

- **Non-Latin text crashed the JSON store on Windows.** Files were read and
  written in the platform's default encoding (cp1252), which can't hold
  Cyrillic, Greek or Hebrew. `JsonRepo` now always uses UTF-8. Data files
  written earlier with non-ASCII Latin letters (e.g. `ø`) on Windows would need
  converting to UTF-8 once.

## Limitations (by design for now)

- **JSON storage is single-machine.** The upload lock only works inside one API
  process. Running several uvicorn workers can let uploads exceed quotas. For the
  same reason, the worker's "still exists?" check and its save aren't atomic with
  respect to the API process. A delete landing in that millisecond gap can still
  re-create the recording.
- **Lists are not sorted by date.** In JSON mode they come back ordered by
  (random) ID. In PostgreSQL mode the order is undefined. The app should sort.
- **Every list reads every file.** `GET .../recordings` loads all recordings of
  all groups. Fine for hundreds, slow for many thousands.
- **Google Drive**: credentials are re-read on every request, refreshed tokens
  are not saved, and `data/cache/` is never cleaned up.
- **Tokens can't be revoked** individually. Disabling the user, or changing
  `APP_SECRET` (logs everyone out), are the only options.
- **Sentences split at 8-minute chunk boundaries** (see transcription.md).
