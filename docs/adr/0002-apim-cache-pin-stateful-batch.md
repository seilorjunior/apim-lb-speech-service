# ADR-0002: APIM cache pin for stateful batch transcription

- Status: Accepted
- Date: 2024-12-01
- Deciders: Project maintainers

## Context

Azure Speech Batch Transcription v3.2 is a *stateful* API: a `POST` to
`/transcriptions` returns a jobId, and *all* subsequent operations on
that jobId — `GET` for status, `GET` for files, `DELETE` — must hit
the **same regional Speech account** that minted the jobId. The job
data does not replicate.

We need to load-balance multiple Speech accounts behind APIM (for
quota and failover) without breaking this affinity.

Three options were considered:

### Option A — Client-side affinity

The Function App returns `{ "jobId": "...", "region": "scus" }` to the
caller, who then has to thread `region` back through every subsequent
request. The Function App routes per the client's hint.

**Rejected**: leaks an implementation detail to the caller, breaks
the abstraction that the API is "one Speech endpoint", and any client
that loses the hint loses the job.

### Option B — APIM cache pin (chosen)

APIM stores `jobId → backend-id` on submit and reads it on every
subsequent operation. The client is unaware that a pool exists.

### Option C — Function-app-side state store

Keep the same idea as Option B, but in a separate state store
(Cosmos DB / Redis) read by the Function App, which then sends an
explicit backend hint to APIM.

**Rejected**: adds a state component (Cosmos / Redis) that we can
avoid because APIM Basic v2 already has a built-in cache that supports
the operations we need (`cache-store-value`, `cache-lookup-value`).

## Decision

Use **Option B**: APIM-native cache pinning.

Implementation specifics:

- **Submit (POST)**: outbound policy on `2xx` parses the upstream
  `Location` header, derives the jobId (last path segment) and the
  backend-id (from the host), then writes:
  ```text
  cache-store-value
    key      = speech-job-<jobId>
    value    = <backend-id>
    duration = 86400        // 24 h
  ```
- **Poll / files / delete**: inbound policy reads
  `speech-job-<jobId>` and forces the request to that backend. Cache
  miss falls back to the round-robin pool (acceptable for cold reads;
  a 404 from the wrong backend is the load-test failure signal).
- **Caching tier**: `caching-type="prefer-external"`. Default = APIM
  internal cache (free, per-instance). Opt-in (`AZURE_USE_EXTERNAL_CACHE=true`)
  attaches **Azure Managed Redis** as the APIM external cache for
  cross-instance + durable storage.

## Consequences

- **Easier**: client treats the API as a single Speech endpoint; no
  hints, no leaks. No new state component in the default deployment.
- **Harder**: the policy XML is non-trivial — escapes for `<`/`&` in
  attribute values, no single-statement `if (...) return ...;` (Razor
  parser rejects it; must use `if (...) { return ...; }`). See the
  policy-XML lint job in CI for guardrails.
- **Lock-in**: tied to APIM as the pinning point. Migrating away from
  APIM means re-implementing pin lookup somewhere else (and any
  idempotency layer riding the same cache). This is acceptable —
  APIM is a load-bearing component for many other reasons (auth,
  retry, circuit breaker, observability) that we are not willing to
  re-implement either.

## Notes

- Idempotency for `POST /submit-batch` and `POST /transcribe` re-uses
  the same APIM cache (`speech-idem-*` keys). One state store, one
  TTL story, one operational surface.
- The 24 h TTL is calibrated to the maximum lifetime of a Speech
  batch job. Polls past 24 h will fall back to the pool and may
  legitimately 404 — that is expected.
