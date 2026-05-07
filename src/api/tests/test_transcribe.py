"""Tests for ``/api/transcribe`` (stateless Fast Transcription proxy)."""

from __future__ import annotations

import httpx


_FAST_TRANSCRIBE_URL = (
    "https://apim.test.azure-api.net/speech/speechtotext/transcriptions:transcribe"
)


def test_transcribe_passes_through_upstream_response(
    function_app, make_request, respx_mock
):
    upstream_body = b'{"combinedPhrases":[{"text":"hello world"}]}'
    route = respx_mock.post(url__startswith=_FAST_TRANSCRIBE_URL).mock(
        return_value=httpx.Response(200, content=upstream_body, headers={"Content-Type": "application/json"})
    )

    req = make_request(
        method="POST",
        url="http://localhost/api/transcribe",
        body=b"\x52\x49\x46\x46fake-wav-bytes",
        headers={"Content-Type": "audio/wav"},
        params={"locale": "en-US"},
    )
    resp = function_app.transcribe(req)

    assert resp.status_code == 200
    assert resp.get_body() == upstream_body
    assert route.called
    # api-version query param flowed through
    assert "api-version=2024-11-15" in str(route.calls.last.request.url)


def test_transcribe_rejects_empty_body(function_app, make_request):
    req = make_request(
        method="POST",
        url="http://localhost/api/transcribe",
        body=b"",
        headers={"Content-Type": "audio/wav"},
    )
    resp = function_app.transcribe(req)

    assert resp.status_code == 400
    assert b"Empty" in resp.get_body()


def test_transcribe_returns_502_when_upstream_fails(
    function_app, make_request, respx_mock
):
    respx_mock.post(url__startswith=_FAST_TRANSCRIBE_URL).mock(
        side_effect=httpx.ConnectError("connection refused")
    )

    req = make_request(
        method="POST",
        url="http://localhost/api/transcribe",
        body=b"audio-bytes",
        headers={"Content-Type": "audio/wav"},
    )
    resp = function_app.transcribe(req)

    assert resp.status_code == 502
    assert b"upstream_failure" in resp.get_body()


def test_transcribe_returns_500_when_apim_url_missing(
    monkeypatch, function_app, make_request
):
    # Re-import the module after blanking APIM_GATEWAY_URL so the
    # module-level constant picks up the empty value.
    import sys

    monkeypatch.setenv("APIM_GATEWAY_URL", "")
    if "function_app" in sys.modules:
        del sys.modules["function_app"]
    import function_app as fa  # noqa: WPS433 — intentional re-import

    req = make_request(
        method="POST",
        url="http://localhost/api/transcribe",
        body=b"audio",
        headers={"Content-Type": "audio/wav"},
    )
    resp = fa.transcribe(req)

    assert resp.status_code == 500
    assert b"APIM_GATEWAY_URL not configured" in resp.get_body()
