"""Pytest fixtures shared across the suite.

Three responsibilities:

1. Configure environment variables ``function_app`` reads at import time
   (``APIM_GATEWAY_URL``, ``APIM_STT_PATH``).
2. Provide a ``respx`` mock router so every outbound ``httpx`` call is
   intercepted with a deterministic response — no real network.
3. Build minimal ``azure.functions.HttpRequest`` instances to drive the
   route handlers directly (no Functions host required).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# Ensure the Function App module is importable when pytest is invoked
# from the repo root or from src/api/.
_API_ROOT = Path(__file__).resolve().parent.parent
if str(_API_ROOT) not in sys.path:
    sys.path.insert(0, str(_API_ROOT))


@pytest.fixture(autouse=True)
def _apim_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Stub APIM env vars before ``function_app`` does anything network-y."""

    monkeypatch.setenv("APIM_GATEWAY_URL", "https://apim.test.azure-api.net")
    monkeypatch.setenv("APIM_STT_PATH", "speech")


@pytest.fixture
def respx_mock():
    """Yield a respx router that asserts all calls were made."""

    import respx  # imported lazily so module-level import errors surface clearly

    with respx.mock(assert_all_called=False, assert_all_mocked=True) as router:
        yield router


def _make_http_request(
    *,
    method: str,
    url: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    params: dict[str, str] | None = None,
    route_params: dict[str, str] | None = None,
):
    """Build an ``azure.functions.HttpRequest`` for direct handler calls."""

    import azure.functions as func

    return func.HttpRequest(
        method=method,
        url=url,
        headers=headers or {},
        params=params or {},
        route_params=route_params or {},
        body=body or b"",
    )


@pytest.fixture
def make_request():
    """Factory fixture so each test can spell out only the params it cares about."""

    return _make_http_request


@pytest.fixture
def function_app(monkeypatch):
    """Import (or re-import) ``function_app`` after env stubs are applied."""

    if "function_app" in sys.modules:
        del sys.modules["function_app"]
    import function_app  # noqa: WPS433 — intentional late import

    return function_app
