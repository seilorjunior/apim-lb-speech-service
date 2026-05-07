"""Tests for the stateful Batch Transcription proxy routes."""

from __future__ import annotations

import json

import httpx


_BATCH_BASE = "https://apim.test.azure-api.net/speech/speechtotext/v3.2/transcriptions"
_SAMPLE_JOB_ID = "abc-123"
_SAMPLE_SELF = f"https://eastus.api.cognitive.microsoft.com/speechtotext/v3.2/transcriptions/{_SAMPLE_JOB_ID}"


# --------------------------------------------------------------------------
# submit_batch
# --------------------------------------------------------------------------


def test_submit_batch_extracts_job_id_from_self(function_app, make_request, respx_mock):
    respx_mock.post(_BATCH_BASE).mock(
        return_value=httpx.Response(
            201,
            json={"self": _SAMPLE_SELF, "status": "NotStarted"},
        )
    )

    req = make_request(
        method="POST",
        url="http://localhost/api/submit-batch",
        body=json.dumps({"contentUrls": ["https://x/y.wav"], "locale": "en-US"}).encode(),
        headers={"Content-Type": "application/json"},
    )
    resp = function_app.submit_batch(req)

    assert resp.status_code == 201
    body = json.loads(resp.get_body().decode("utf-8"))
    assert body["jobId"] == _SAMPLE_JOB_ID
    assert body["speechSelf"] == _SAMPLE_SELF
    assert body["status"] == "NotStarted"


def test_submit_batch_passes_through_non_201(function_app, make_request, respx_mock):
    respx_mock.post(_BATCH_BASE).mock(
        return_value=httpx.Response(400, json={"error": "InvalidRequest"})
    )

    req = make_request(
        method="POST",
        url="http://localhost/api/submit-batch",
        body=b'{"bad": true}',
        headers={"Content-Type": "application/json"},
    )
    resp = function_app.submit_batch(req)

    assert resp.status_code == 400
    assert b"InvalidRequest" in resp.get_body()


def test_submit_batch_rejects_empty_body(function_app, make_request):
    req = make_request(
        method="POST",
        url="http://localhost/api/submit-batch",
        body=b"",
        headers={"Content-Type": "application/json"},
    )
    resp = function_app.submit_batch(req)
    assert resp.status_code == 400


def test_submit_batch_502_on_upstream_error(function_app, make_request, respx_mock):
    respx_mock.post(_BATCH_BASE).mock(side_effect=httpx.ReadTimeout("timeout"))

    req = make_request(
        method="POST",
        url="http://localhost/api/submit-batch",
        body=b'{"contentUrls":[]}',
        headers={"Content-Type": "application/json"},
    )
    resp = function_app.submit_batch(req)
    assert resp.status_code == 502


# --------------------------------------------------------------------------
# batch_status
# --------------------------------------------------------------------------


def test_batch_status_passes_through(function_app, make_request, respx_mock):
    respx_mock.get(f"{_BATCH_BASE}/{_SAMPLE_JOB_ID}").mock(
        return_value=httpx.Response(200, json={"status": "Succeeded"})
    )

    req = make_request(
        method="GET",
        url=f"http://localhost/api/batch-status/{_SAMPLE_JOB_ID}",
        route_params={"jobId": _SAMPLE_JOB_ID},
    )
    resp = function_app.batch_status(req)

    assert resp.status_code == 200
    assert b"Succeeded" in resp.get_body()


def test_batch_status_rejects_invalid_job_id(function_app, make_request):
    req = make_request(
        method="GET",
        url="http://localhost/api/batch-status/bad%20id",
        route_params={"jobId": "bad id"},
    )
    resp = function_app.batch_status(req)
    assert resp.status_code == 400
    assert b"Invalid jobId" in resp.get_body()


# --------------------------------------------------------------------------
# batch_files
# --------------------------------------------------------------------------


def test_batch_files_passes_through(function_app, make_request, respx_mock):
    respx_mock.get(f"{_BATCH_BASE}/{_SAMPLE_JOB_ID}/files").mock(
        return_value=httpx.Response(200, json={"values": []})
    )

    req = make_request(
        method="GET",
        url=f"http://localhost/api/batch-files/{_SAMPLE_JOB_ID}",
        route_params={"jobId": _SAMPLE_JOB_ID},
    )
    resp = function_app.batch_files(req)
    assert resp.status_code == 200


def test_batch_files_rejects_invalid_job_id(function_app, make_request):
    req = make_request(
        method="GET",
        url="http://localhost/api/batch-files/../etc/passwd",
        route_params={"jobId": "../etc/passwd"},
    )
    resp = function_app.batch_files(req)
    assert resp.status_code == 400


# --------------------------------------------------------------------------
# batch_delete
# --------------------------------------------------------------------------


def test_batch_delete_passes_through(function_app, make_request, respx_mock):
    respx_mock.delete(f"{_BATCH_BASE}/{_SAMPLE_JOB_ID}").mock(
        return_value=httpx.Response(204)
    )

    req = make_request(
        method="DELETE",
        url=f"http://localhost/api/batch/{_SAMPLE_JOB_ID}",
        route_params={"jobId": _SAMPLE_JOB_ID},
    )
    resp = function_app.batch_delete(req)
    assert resp.status_code == 204


def test_batch_delete_rejects_invalid_job_id(function_app, make_request):
    req = make_request(
        method="DELETE",
        url="http://localhost/api/batch/with;semicolon",
        route_params={"jobId": "with;semicolon"},
    )
    resp = function_app.batch_delete(req)
    assert resp.status_code == 400
