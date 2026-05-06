# Security Policy

## Scope

This repository is a **dev-only Azure sample**. It deploys public-facing
APIM, Function App, and Speech endpoints with no client authentication
on the API (`subscriptionRequired: false`). It is **not** intended for
production workloads. See the *Notes & limitations* section of the
[README](README.md) for the hardening steps required before any
production use.

## Reporting a vulnerability

If you discover a security issue in this template — for example, a
default that leaks credentials, a policy that bypasses managed-identity
auth, or a Bicep mis-configuration that grants unintended access:

1. **Do not** open a public GitHub issue.
2. Open a private security advisory via
   [Security → Advisories → New draft security advisory](../../security/advisories/new)
   on this repository, or contact the maintainers directly.
3. Include reproduction steps, the commit SHA, and any relevant logs
   (with secrets redacted).

We aim to acknowledge reports within five business days and to publish
a fix or mitigation guidance as soon as practical.

## Out of scope

The following are intentional choices for a dev-only sample and are not
considered vulnerabilities here:

- The `speech-stt` API does not require an APIM subscription key.
- Public network access is enabled on APIM, the Function App, the
  Storage account, and both Speech accounts.
- The Function App runs `http_auth_level=ANONYMOUS` on every route.

If you need any of those locked down, fork the template and apply the
hardening notes from the README before deploying.
