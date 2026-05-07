"""Tests for the ``/api/health`` route."""

from __future__ import annotations

import json


def test_health_returns_ok_and_apim_gateway(function_app, make_request):
    req = make_request(method="GET", url="http://localhost/api/health")
    resp = function_app.health(req)

    assert resp.status_code == 200
    body = json.loads(resp.get_body().decode("utf-8"))
    assert body["status"] == "ok"
    # The fixture sets the env var; the handler echoes it.
    assert body["apim"] == "https://apim.test.azure-api.net"
