"""Capitalize each word of a person's name (UC-D1 / UC-A2 registration).

The Flutter form does the same while typing (mobile/lib/ui/input_formatters.dart),
but the backend repeats it so API clients can't store "jUAN dela cruz".
Only the first letter of each part is changed; the rest is kept as typed,
so "McDonald" and "DeLa Cruz" stay as the person wrote them.
"""
import re

# A new word starts after a space, hyphen, apostrophe or period.
_WORD_START = re.compile(r"(^|[\s\-'.])([^\W\d_])", re.UNICODE)


def capitalize_words(value: str) -> str:
    value = re.sub(r"\s+", " ", value.strip())
    return _WORD_START.sub(lambda m: m.group(1) + m.group(2).upper(), value)


def capitalize_org_words(value: str) -> str:
    """Organization names: first letter of every word, split on spaces only.

    Unlike capitalize_words (people's names), an apostrophe or period does not
    start a new word, so "St. Mary's" stays "St. Mary's" and not "St. Mary'S".
    The rest of each word is kept as typed, so "NGO" and "CSWS" are untouched.
    """
    value = re.sub(r"\s+", " ", value.strip())
    return " ".join(w[:1].upper() + w[1:] for w in value.split(" "))