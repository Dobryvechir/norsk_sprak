"""Tests for turning timed words into sentences (app.transcription.segment)."""

from app.transcription import segment


def test_splits_on_sentence_punctuation():
    words = [
        {"text": "Hei.", "start_ms": 0, "end_ms": 400},
        {"text": "God", "start_ms": 500, "end_ms": 700},
        {"text": "dag!", "start_ms": 710, "end_ms": 900},
    ]
    result = segment(words)
    assert len(result) == 2
    assert result[1]["text"] == "God dag!"
