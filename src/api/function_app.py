import json
import logging
import os
from urllib.parse import urlencode

import azure.functions as func
import httpx

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

APIM_GATEWAY_URL = os.environ.get("APIM_GATEWAY_URL", "").rstrip("/")
APIM_STT_PATH = os.environ.get("APIM_STT_PATH", "speech").strip("/")
FAST_TRANSCRIBE_API_VERSION = "2024-11-15"


@app.route(route="health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    """Liveness probe."""
    return func.HttpResponse(
        json.dumps({"status": "ok", "apim": APIM_GATEWAY_URL}),
        status_code=200,
        mimetype="application/json",
    )


@app.route(route="transcribe", methods=["POST"])
def transcribe(req: func.HttpRequest) -> func.HttpResponse:
    """
    Forwards an audio payload to APIM, which load-balances across the
    primary + secondary Speech accounts using the Fast Transcription API.

    Request:
        POST /api/transcribe
        Content-Type: <audio/wav | audio/ogg | audio/mp3 | ...>
        Query (optional): locale=pt-BR  (default), profanityFilterMode=Masked
        Body: raw audio bytes

    Response:
        200 OK: passthrough JSON from Speech (combinedPhrases, phrases, etc.)
        Anything else: APIM/Speech response surfaced verbatim.
    """
    if not APIM_GATEWAY_URL:
        return func.HttpResponse(
            "APIM_GATEWAY_URL not configured", status_code=500
        )

    audio = req.get_body()
    if not audio:
        return func.HttpResponse("Empty audio body", status_code=400)

    locale = req.params.get("locale", "pt-BR")
    profanity = req.params.get("profanityFilterMode", "Masked")

    # Fast Transcription expects multipart/form-data with two parts:
    #   * audio   - the audio file
    #   * definition - JSON with locales, profanity filter, etc.
    definition = {
        "locales": [locale],
        "profanityFilterMode": profanity,
    }
    files = {
        "audio": (
            "audio.bin",
            audio,
            req.headers.get("Content-Type", "application/octet-stream"),
        ),
        "definition": (None, json.dumps(definition), "application/json"),
    }

    qs = urlencode({"api-version": FAST_TRANSCRIBE_API_VERSION})
    url = (
        f"{APIM_GATEWAY_URL}/{APIM_STT_PATH}"
        f"/speechtotext/transcriptions:transcribe?{qs}"
    )
    logging.info("Calling APIM: %s (audio=%d bytes)", url, len(audio))

    try:
        with httpx.Client(timeout=120.0) as client:
            resp = client.post(url, files=files)
    except httpx.HTTPError as ex:
        logging.exception("APIM call failed")
        return func.HttpResponse(
            json.dumps({"error": "upstream_failure", "detail": str(ex)}),
            status_code=502,
            mimetype="application/json",
        )

    # Surface the upstream response verbatim.
    return func.HttpResponse(
        body=resp.content,
        status_code=resp.status_code,
        mimetype=resp.headers.get("Content-Type", "application/json"),
    )


# ---------------------------------------------------------------------
# Batch Transcription proxy routes.
# Speech Batch Transcription jobs are stateful — created on a single
# Speech account and only readable from that same account.  APIM
# caches jobId -> backend mapping (24h) so polls get pinned to the
# correct backend regardless of which one originally accepted the POST.
# ---------------------------------------------------------------------


def _job_id_from_self(self_url: str) -> str:
    """Extract the trailing jobId from a Speech 'self' URL."""
    if not self_url:
        return ""
    path = self_url.split("?", 1)[0].rstrip("/")
    return path.rsplit("/", 1)[-1]


@app.route(route="submit-batch", methods=["POST"])
def submit_batch(req: func.HttpRequest) -> func.HttpResponse:
    """
    Submit a batch transcription job.

    Request body (JSON):
        {
          "displayName": "...",
          "locale": "en-US",
          "contentUrls": ["https://.../audio.wav"],
          "properties": { "wordLevelTimestampsEnabled": true }
        }

    Response: { "jobId": "<uuid>", "speechSelf": "<original-self-url>" }
    """
    if not APIM_GATEWAY_URL:
        return func.HttpResponse("APIM_GATEWAY_URL not configured", status_code=500)

    body = req.get_body()
    if not body:
        return func.HttpResponse("Empty request body", status_code=400)

    url = f"{APIM_GATEWAY_URL}/{APIM_STT_PATH}/speechtotext/v3.2/transcriptions"
    try:
        with httpx.Client(timeout=60.0) as client:
            resp = client.post(
                url,
                content=body,
                headers={"Content-Type": "application/json"},
            )
    except httpx.HTTPError as ex:
        logging.exception("APIM submit-batch failed")
        return func.HttpResponse(
            json.dumps({"error": "upstream_failure", "detail": str(ex)}),
            status_code=502,
            mimetype="application/json",
        )

    if resp.status_code != 201:
        return func.HttpResponse(
            body=resp.content,
            status_code=resp.status_code,
            mimetype=resp.headers.get("Content-Type", "application/json"),
        )

    try:
        upstream = resp.json()
    except Exception:
        upstream = {}

    job_id = _job_id_from_self(upstream.get("self", ""))
    return func.HttpResponse(
        json.dumps({
            "jobId": job_id,
            "speechSelf": upstream.get("self", ""),
            "status": upstream.get("status", ""),
        }),
        status_code=201,
        mimetype="application/json",
    )


@app.route(route="batch-status/{jobId}", methods=["GET"])
def batch_status(req: func.HttpRequest) -> func.HttpResponse:
    job_id = req.route_params.get("jobId", "")
    if not job_id:
        return func.HttpResponse("Missing jobId", status_code=400)
    url = f"{APIM_GATEWAY_URL}/{APIM_STT_PATH}/speechtotext/v3.2/transcriptions/{job_id}"
    try:
        with httpx.Client(timeout=30.0) as client:
            resp = client.get(url)
    except httpx.HTTPError as ex:
        logging.exception("APIM batch-status failed")
        return func.HttpResponse(
            json.dumps({"error": "upstream_failure", "detail": str(ex)}),
            status_code=502,
            mimetype="application/json",
        )
    return func.HttpResponse(
        body=resp.content,
        status_code=resp.status_code,
        mimetype=resp.headers.get("Content-Type", "application/json"),
    )


@app.route(route="batch-files/{jobId}", methods=["GET"])
def batch_files(req: func.HttpRequest) -> func.HttpResponse:
    job_id = req.route_params.get("jobId", "")
    if not job_id:
        return func.HttpResponse("Missing jobId", status_code=400)
    url = f"{APIM_GATEWAY_URL}/{APIM_STT_PATH}/speechtotext/v3.2/transcriptions/{job_id}/files"
    try:
        with httpx.Client(timeout=30.0) as client:
            resp = client.get(url)
    except httpx.HTTPError as ex:
        logging.exception("APIM batch-files failed")
        return func.HttpResponse(
            json.dumps({"error": "upstream_failure", "detail": str(ex)}),
            status_code=502,
            mimetype="application/json",
        )
    return func.HttpResponse(
        body=resp.content,
        status_code=resp.status_code,
        mimetype=resp.headers.get("Content-Type", "application/json"),
    )


@app.route(route="batch/{jobId}", methods=["DELETE"])
def batch_delete(req: func.HttpRequest) -> func.HttpResponse:
    job_id = req.route_params.get("jobId", "")
    if not job_id:
        return func.HttpResponse("Missing jobId", status_code=400)
    url = f"{APIM_GATEWAY_URL}/{APIM_STT_PATH}/speechtotext/v3.2/transcriptions/{job_id}"
    try:
        with httpx.Client(timeout=30.0) as client:
            resp = client.delete(url)
    except httpx.HTTPError as ex:
        logging.exception("APIM batch-delete failed")
        return func.HttpResponse(
            json.dumps({"error": "upstream_failure", "detail": str(ex)}),
            status_code=502,
            mimetype="application/json",
        )
    return func.HttpResponse(
        body=resp.content,
        status_code=resp.status_code,
        mimetype=resp.headers.get("Content-Type", "application/json"),
    )
