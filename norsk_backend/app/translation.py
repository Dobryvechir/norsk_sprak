"""
Translating a recording's sentences (after AI transcription) with OpenAI.

    translate_sentences(texts, source, target) -> list of the same length

The sentences are sent in batches as a JSON object {"0": "...", "1": "..."}; the
model answers with the same keys. A sentence missing from the answer is sent
again on its own, so the result always has one translation per sentence and
sentence i stays sentence i in every language.
"""

import json

from .config import settings

BATCH_SIZE = 40

LANGUAGE_NAMES = {
    "en": "English", "nb": "Norwegian Bokmål", "nn": "Norwegian Nynorsk", "uk": "Ukrainian",
    "ru": "Russian", "de": "German", "da": "Danish", "sv": "Swedish", "cs": "Czech",
    "bg": "Bulgarian", "pl": "Polish", "pt": "Portuguese", "es": "Spanish", "fr": "French",
    "el": "Greek", "he": "Hebrew", "it": "Italian",
}


def _prompt(source, target) -> str:
    return (
        f"You translate sentences of a spoken text from {LANGUAGE_NAMES.get(source, source)} "
        f"to {LANGUAGE_NAMES.get(target, target)} for language learners. You get a JSON object "
        "whose values are sentences in order. Reply with only a JSON object with exactly the "
        "same keys, each value being the translation of that key's sentence. Never merge, "
        "split, skip or explain sentences; keep names as they are."
    )


def _ask(client, model, source, target, items: dict) -> dict:
    response = client.chat.completions.create(
        model=model,
        response_format={"type": "json_object"},
        temperature=0,
        messages=[
            {"role": "system", "content": _prompt(source, target)},
            {"role": "user", "content": json.dumps(items, ensure_ascii=False)},
        ],
    )
    try:
        answer = json.loads(response.choices[0].message.content or "{}")
    except ValueError:
        return {}
    return answer if isinstance(answer, dict) else {}


def translate_sentences(texts, source, target, api_key=None, model=None, client=None) -> list[str]:
    """Translate `texts` (sentences in `source`) into `target`, one result per sentence."""
    if source == target or not texts:
        return list(texts)
    if client is None:
        api_key = api_key or settings.openai_api_key
        if not api_key:
            raise ValueError("No OpenAI API key configured")
        from openai import OpenAI  # imported here so the API server doesn't need it at startup
        client = OpenAI(api_key=api_key)
    model = model or settings.translation_model

    result = [""] * len(texts)
    for start in range(0, len(texts), BATCH_SIZE):
        batch = {str(i): texts[i] for i in range(start, min(start + BATCH_SIZE, len(texts))) if texts[i].strip()}
        if not batch:
            continue
        answer = _ask(client, model, source, target, batch)
        for key, text in batch.items():
            value = answer.get(key)
            if not isinstance(value, str) or not value.strip():
                value = _ask(client, model, source, target, {"0": text}).get("0")
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"Translation to {target} failed for sentence {int(key) + 1}")
            result[int(key)] = value.strip()
    return result
