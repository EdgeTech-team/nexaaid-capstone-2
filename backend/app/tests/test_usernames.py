# tests/test_usernames.py
import pytest

from core.usernames import clean_username


@pytest.mark.parametrize("raw, expected", [
    ("cebu_redcross", "cebu_redcross"),
    ("CTU.CICT", "ctu.cict"),
    ("  Test_Org1  ", "test_org1"),
    ("abcd", "abcd"),
    ("a" * 30, "a" * 30),
])
def test_valid_usernames_are_lowercased(raw, expected):
    assert clean_username(raw) == expected


@pytest.mark.parametrize("raw", [
    "",              # empty
    "abc",           # too short
    "a" * 31,        # too long
    "1abcd",         # starts with a number
    "_abcd",         # starts with an underscore
    "ab cd",         # space
    "ab@cd",         # "@" is reserved for emails
    "ab-cd",         # hyphen not allowed
    "ab..cd",        # two periods in a row
    "abcd.",         # ends with a period
    "admin",         # reserved
    "Administrator", # reserved, any case
    "nexaaid",       # reserved
])
def test_invalid_usernames_are_rejected(raw):
    with pytest.raises(ValueError):
        clean_username(raw)