"""
Audio analysis and speech-to-text.

    get_duration(path)  - length of an audio file in seconds (uses ffprobe)
    transcribe(path)    - Norwegian speech -> list of timed sentences (OpenAI Whisper)
    segment(words)      - group timed words into sentences

Requires the `ffmpeg` and `ffprobe` command-line tools to be installed.
See docs/transcription.md for a walkthrough of the pipeline.
"""

import json
import pathlib
import re
import subprocess
import tempfile

from .config import settings

# Long recordings are cut into 8-minute pieces. Re-encoded as 48 kbps mono MP3,
# each piece stays comfortably below Whisper's 25 MB upload limit.
CHUNK_SECONDS = 480

# A sentence ends at a word ending in . ! or ? (optionally followed by a closing
# quote like " ” or »), or when the speaker pauses for longer than this:
SENTENCE_END_PATTERN = re.compile(r'[.!?]["”»]?$')
MAX_PAUSE_MS = 1100


def get_duration(path) -> float:
    """Return the length of an audio file in seconds.

    Raises if ffprobe is missing or the file isn't valid audio.
    """
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
        capture_output=True, text=True, check=True,
    )
    return float(json.loads(result.stdout)["format"]["duration"])


def transcribe(path, provider="openai", model="whisper-1", api_key=None):
    """Transcribe a Norwegian audio file into timed sentences.

    Returns a list like:
        [{"index": 0, "text": "Hei.", "start_ms": 0, "end_ms": 400}, ...]

    Only provider="openai" / model="whisper-1" is implemented.
    """
    if provider != "openai" or model != "whisper-1":
        raise ValueError(
            "Only openai/whisper-1 is implemented; other provider configurations "
            "are reserved for future adapters"
        )
    api_key = api_key or settings.openai_api_key
    if not api_key:
        raise ValueError("No OpenAI API key configured")

    from openai import OpenAI  # imported here so the API server doesn't need it at startup

    client = OpenAI(api_key=api_key)
    total_seconds = get_duration(path)
    words = []

    with tempfile.TemporaryDirectory() as tmp:
        chunk_start = 0
        chunk_number = 0
        while chunk_start < total_seconds:
            # 1. Cut out one chunk and shrink it (mono, 16 kHz, 48 kbps MP3).
            chunk_path = pathlib.Path(tmp) / f"{chunk_number}.mp3"
            subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                 "-ss", str(chunk_start), "-t", str(CHUNK_SECONDS), "-i", str(path),
                 "-ac", "1", "-ar", "16000", "-b:a", "48k", str(chunk_path)],
                check=True,
            )

            # 2. Send it to Whisper, asking for a timestamp on every word.
            with chunk_path.open("rb") as f:
                result = client.audio.transcriptions.create(
                    model=model, file=f, language="no",
                    response_format="verbose_json", timestamp_granularities=["word"],
                )

            # 3. Whisper's timestamps are relative to the chunk, in seconds.
            #    Convert to milliseconds from the start of the whole recording.
            for word in result.words or []:
                words.append({
                    "text": word.word.strip(),
                    "start_ms": round((chunk_start + word.start) * 1000),
                    "end_ms": round((chunk_start + word.end) * 1000),
                })

            chunk_start += CHUNK_SECONDS
            chunk_number += 1

    return segment(words)


def segment(words):
    """Group timed words into sentences.

    `words` is a list of {"text", "start_ms", "end_ms"} in spoken order.
    A sentence is closed when a word ends with sentence punctuation, when the
    pause before the next word exceeds MAX_PAUSE_MS, or at the last word.
    """
    sentences = []
    current = []  # words of the sentence being built

    for i, word in enumerate(words):
        current.append(word)

        is_last_word = i == len(words) - 1
        pause_after_ms = 0 if is_last_word else words[i + 1]["start_ms"] - word["end_ms"]

        if SENTENCE_END_PATTERN.search(word["text"]) or pause_after_ms > MAX_PAUSE_MS or is_last_word:
            sentences.append({
                "index": len(sentences),
                "text": " ".join(w["text"] for w in current),
                "start_ms": current[0]["start_ms"],
                "end_ms": current[-1]["end_ms"],
            })
            current = []

    return sentences
