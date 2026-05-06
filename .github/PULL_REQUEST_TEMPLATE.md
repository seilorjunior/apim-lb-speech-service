<!--
Thanks for sending a PR! Please make sure the boxes below are ticked.
-->

## What does this PR do?

<!-- Brief description; link the issue with `Fixes #123` if applicable. -->

## Verification

- [ ] `az bicep build --file infra/main.bicep` is clean
- [ ] `ruff check src/api` passes
- [ ] `pwsh ./scripts/load-test.ps1 -Count 6` returned PASS on my own deployment
- [ ] README / docs updated if behaviour or parameters changed
- [ ] No secrets, real principal IDs, tenant identifiers, or endpoints
      committed

## Notes for reviewers

<!-- Anything reviewers should pay extra attention to. -->
