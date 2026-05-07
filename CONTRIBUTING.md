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
   pip install -r requirements-dev.txt
   pip install ruff
   ruff check .
   ```

4. Run the unit tests (fast — no Azure resources required):

   ```pwsh
   # from src/api
   pytest                                       # 30 tests, ~5 s
   pytest --cov --cov-report=term-missing       # with coverage (gate: 80%)
   bandit -r . -ll -c pyproject.toml            # security scan
   ```

   Tests use [respx](https://lundberg.github.io/respx/) to mock the
   APIM gateway, so they run fully offline. The coverage gate is
   enforced in CI; see [`.github/workflows/validate.yml`](.github/workflows/validate.yml).

5. (Optional) Preview the docs site locally:

   ```pwsh
   # from repo root
   pip install -r docs/requirements.txt
   $env:PYTHONPATH = "src/api"   # so mkdocstrings can import function_app
   mkdocs serve                   # http://127.0.0.1:8000
   ```

6. Lint Bicep locally: `az bicep build --file infra/main.bicep` (this
   surfaces every diagnostic CI will run).
7. Smoke-test against your own `azd` environment:

   ```pwsh
   azd up
   pwsh ./scripts/test-deployment.ps1 -Batch -Locale en-US
   pwsh ./scripts/load-test.ps1 -Count 6 -MaxParallel 6
   ```

8. Commit with a descriptive message and open a PR.

## PR checklist

- [ ] `az bicep build --file infra/main.bicep` is clean (no warnings)
- [ ] `ruff check src/api` passes
- [ ] `pytest --cov` passes with coverage **≥ 80 %** (run from `src/api`)
- [ ] `bandit -r . -ll -c pyproject.toml` reports no high-severity findings
- [ ] `pwsh ./scripts/load-test.ps1 -Count 6` returns "PASS" on your
      own deployment
- [ ] README / docs (`docs/`) updated if behaviour, parameters, or the
      public API surface changed
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
