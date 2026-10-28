# Transcription pipeline

Code: `app/worker.py` (the loop) and `app/transcription.py` (the work).

## The worker loop

```
at startup:
    convert recordings in the old single-language format
    any audio still "processing" → back to "pending"
      (it was interrupted by a crash/restart)

forever:
    find the first audio (any recording, any language) with status "pending"
    none?  → sleep 3 s, try again
    set its status "processing"
    try:
        audio path ← storage.get(audio_key)
        sentences  ← transcribe(audio path, language)
        sentences[lang] ← their texts; audio start_ms/end_ms ← their timings
        status "ready", save a usage record
    on any error:
        status "failed", error message (max 500 chars)
```

Results are saved by `save_result`, which re-reads the recording and changes
only that language's audio entry and sentences, and only if the audio is still
the same (same `audio_key`). So deleting the recording, replacing that audio,
or editing other languages during a transcription is not undone by the worker.

It handles one audio at a time. Run exactly **one** worker. Two workers could
pick the same recording, and the startup recovery would reset the other
worker's active job.

## `transcribe(path)` step by step

Whisper accepts at most 25 MB per request, and a 60-minute recording is much
bigger. So:

1. **Measure** the length with `ffprobe`.
2. **Cut** the audio into 8-minute chunks (`CHUNK_SECONDS = 480`) with `ffmpeg`,
   re-encoding each as mono, 16 kHz, 48 kbps MP3 (~3 MB per chunk).
3. **Send** each chunk to OpenAI Whisper in the audio's language (our `nb` is Whisper's `no`) asking for
   **word-level timestamps**.
4. **Shift** each word's timestamps by the chunk's start time, so they're
   relative to the whole recording, and convert to milliseconds.
5. **Group** the words into sentences with `segment()`.

## `segment(words)`: words → sentences

Walk through the words, collecting them into the "current sentence". Close the
sentence (and start a new one) after a word when **any** of these is true:

- the word ends in `.`, `!` or `?` (optionally followed by `"`, `”` or `»`)
- the gap before the next word is more than **1.1 s** (`MAX_PAUSE_MS`)
- it's the last word

Each sentence gets `index`, `text` (words joined by spaces), `start_ms` (first
word's start) and `end_ms` (last word's end).

Example:

| word | start–end ms | closes sentence? |
|---|---|---|
| `Hei.` | 0–400 | yes (ends in `.`) |
| `God` | 500–700 | no |
| `dag` | 710–900 | yes (next word is 1.2 s later) |
| `igjen` | 2100–2500 | yes (last word) |

→ `"Hei."`, `"God dag"`, `"igjen"`

## Limitations

- A sentence spoken across an 8-minute boundary is split in two, and Whisper
  may mishear the cut-off words. Overlapping chunks would fix this.
- Only `openai` / `whisper-1` works. Other values in a group's AI config make
  the job fail with a clear error.
- Mistakes can be corrected afterwards with
  `PATCH /api/recordings/{id}/sentences/{lang}/{index}`.
- Re-transcribing a language's audio may produce a different number of
  sentences, so translations in other languages can stop lining up by index.
