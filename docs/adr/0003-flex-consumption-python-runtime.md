# ADR-0003: Flex Consumption (FC1) for the Python Function App

- Status: Accepted
- Date: 2024-12-01
- Deciders: Project maintainers

## Context

The Function App is a thin proxy in front of APIM. It is short-lived,
bursty, and has no warm-state requirement of its own (state lives in
APIM's cache and on the Speech accounts). It needs to:

- Run Python 3.11.
- Scale to zero when idle.
- Scale up quickly under load (the load-test script ramps from 1 to 50
  concurrent submitters).
- Use managed identity to reach Storage and APIM.
- Avoid shared-key auth on its deployment storage.

We considered three Function App hosting plans:

| Plan | Pros | Cons |
|---|---|---|
| **Consumption (Y1)** | Cheapest, scales to zero | Cold start on Python is heavy; Linux Python on Y1 has historically had quirks; deployment-storage MI support is limited |
| **Premium (EP1+)** | Always-warm, VNet integration | Always-on cost; overkill for a public dev sample |
| **Flex Consumption (FC1)** | Scales to zero, faster cold start than Y1, first-class Python 3.11, MI-based deployment storage out of the box | GA but newer; fewer third-party tutorials |

## Decision

Use **Flex Consumption (FC1)**.

Configuration:

- `httpsOnly: true`
- `functionAppConfig.runtime`: `python 3.11`
- `functionAppConfig.scaleAndConcurrency`: instanceMemoryMB 2048,
  maximumInstanceCount 100 (override via parameters).
- Deployment storage uses managed identity (`authentication.type =
  SystemAssignedIdentity`) — Function MI gets `Storage Blob Data Owner`
  on the deployment container.
- TLS 1.2 minimum, FTPS disabled.

## Consequences

- **Easier**: cold-start UX is acceptable for a public dev sample; MI-
  based deployment is "the path of least friction" on FC1; Bicep
  resource shapes are well-defined.
- **Harder**: third-party tutorials still trail Y1 / EP1. When in doubt,
  read the Microsoft docs page for FC1 before assuming a Y1-shaped
  config will work.
- **Lock-in**: FC1 is Azure-Functions-specific. Migrating to a
  container-based runtime (Container Apps, Kubernetes) would require
  re-templating, but the Python code itself is plain `azure-functions`
  v2 model and is portable.
