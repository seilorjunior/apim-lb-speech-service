# Contributing

Thanks for taking the time to contribute! This is a community sample. Bug
reports, fixes, and improvement PRs are all welcome.

## Ground rules

- **Be kind** — see the [Code of Conduct](CODE_OF_CONDUCT.md).
- **Keep it dev-only.** This template is intentionally a small, public,
  dev-only reference. Big architectural changes (private endpoints,
  multi-tenant auth, prod hardening) are better suited for a fork.
- **No secrets.** Never commit real keys, tokens, principal IDs, or
  tenant identifiers. The `.gitignore` already excludes `.azure/`,
  `local.settings.json`, and `*.env`.

## Reporting bugs

Open a [GitHub issue](../../issues/new?template=bug_report.yml) with:

- What you expected vs. what happened
- The exact `azd` / `pwsh` / `python` versions
- The relevant slice of `azd up` output, APIM trace, or App Insights
  request id (scrub anything sensitive)

## Suggesting changes

Open a [feature request issue](../../issues/new?template=feature_request.yml)
before sending a large PR — a short discussion saves rework.

## Development workflow

1. Fork & clone the repo.
2. Create a feature branch off `main`: `git checkout -b feat/short-name`.
3. Set up a local Python env for the Function App:

   ```pwsh
   cd src/api
   python -m venv .venv
   .venv\Scripts\Activate.ps1
   pip install -r requirements.txt
   pip install ruff
   ruff check .
   ```

4. Lint Bicep locally: `az bicep build --file infra/main.bicep` (this
   surfaces every diagnostic CI will run).
5. Smoke-test against your own `azd` environment:

   ```pwsh
   azd up
   pwsh ./scripts/test-deployment.ps1 -Batch -Locale en-US
   pwsh ./scripts/load-test.ps1 -Count 6 -MaxParallel 6
   ```

6. Commit with a descriptive message and open a PR.

## PR checklist

- [ ] `az bicep build --file infra/main.bicep` is clean (no warnings)
- [ ] `ruff check src/api` passes
- [ ] `pwsh ./scripts/load-test.ps1 -Count 6` returns "PASS" on your
      own deployment
- [ ] README / docs updated if behaviour or parameters changed
- [ ] No secrets, real principal IDs, or tenant identifiers committed

## Style

- **Bicep:** run `az bicep format` before committing. Prefer `param`
  descriptions over inline comments.
- **Python:** ruff defaults; keep functions small; type hints encouraged
  but not required.
- **PowerShell:** prefer full cmdlet names over aliases; use
  `[CmdletBinding()]` and `param()` blocks for any script with options.
- **APIM policies:** edit the XML files under
  `infra/modules/policies/`, not the Bicep. Always brace-wrap
  conditional bodies in `@{...}` expressions — even one-liners.
