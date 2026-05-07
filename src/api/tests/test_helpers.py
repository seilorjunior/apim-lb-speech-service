"""Unit tests for module-level helpers in ``function_app``."""

from __future__ import annotations

import pytest


# Each parametrize block is scoped to a single helper so failures point
# back at the helper that broke, not at a bag of mixed assertions.
@pytest.mark.parametrize(
    ("job_id", "valid"),
    [
        ("abc123", True),
        ("ABC-123-XYZ", True),
        ("a", True),
        ("0" * 64, True),
        ("", False),
        ("0" * 65, False),
        ("with space", False),
        ("with/slash", False),
        ("../etc/passwd", False),
        ("job;DROP TABLE", False),
        ("ünïcödé", False),
    ],
)
def test_is_valid_job_id(function_app, job_id: str, valid: bool) -> None:
    assert function_app._is_valid_job_id(job_id) is valid


@pytest.mark.parametrize(
    ("self_url", "expected"),
    [
        (
            "https://eastus.api.cognitive.microsoft.com/speechtotext/v3.2/transcriptions/abc-123",
            "abc-123",
        ),
        (
            "https://eastus.api.cognitive.microsoft.com/speechtotext/v3.2/transcriptions/abc-123/",
            "abc-123",
        ),
        (
            "https://eastus.api.cognitive.microsoft.com/speechtotext/v3.2/transcriptions/abc-123?api-version=3.2",
            "abc-123",
        ),
        ("", ""),
    ],
)
def test_job_id_from_self(function_app, self_url: str, expected: str) -> None:
    assert function_app._job_id_from_self(self_url) == expected
