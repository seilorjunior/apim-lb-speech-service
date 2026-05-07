# API reference

This page is generated from the docstrings in [`src/api/function_app.py`](https://github.com/seilorjunior/apim-lb-speech-service/blob/main/src/api/function_app.py).

The Function App is anonymous-auth and exposes six routes. APIM is the
real gateway: client auth, throttling, and routing happen there.

## Routes at a glance

| Route | Method | Purpose | Stateful? |
|---|---|---|---|
| `/api/health` | GET | Liveness probe — returns the configured APIM URL | No |
| `/api/transcribe` | POST | Stateless Fast Transcription (one-shot) | No |
| `/api/submit-batch` | POST | Submits a Batch v3.2 transcription job | Yes (mints jobId) |
| `/api/batch-status/{jobId}` | GET | Polls a batch job | Yes (cache pin) |
| `/api/batch-files/{jobId}` | GET | Lists transcription result files | Yes (cache pin) |
| `/api/batch/{jobId}` | DELETE | Deletes a batch job | Yes (cache pin) |

## Module reference

::: function_app
    options:
      show_root_heading: true
      show_source: false
      heading_level: 3
      members_order: source
      docstring_section_style: spacy
      filters:
        - "!^_[^_]"
