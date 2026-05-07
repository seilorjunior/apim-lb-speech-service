# Architecture Decision Records

This directory captures the *why* behind significant design choices in
the project. The format follows [Michael Nygard's lightweight ADR
template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-apim-cache-pin-stateful-batch.md) | APIM cache pin for stateful batch transcription | Accepted |
| [0003](0003-flex-consumption-python-runtime.md) | Flex Consumption (FC1) for the Python Function App | Accepted |

## When to write an ADR

Add an ADR when:

- A choice has long-lived consequences (data model, auth boundary,
  protocol).
- A choice has ongoing cost implications (SKU, region, scale unit).
- A choice has more than one reasonable answer and the team picked
  one — record what was rejected and why.

Skip an ADR for purely tactical decisions that any contributor could
revisit safely (linting rules, file layout inside a module).

## Template

```markdown
# ADR-NNNN: <decision>

- Status: Proposed | Accepted | Superseded by ADR-XXXX
- Date: YYYY-MM-DD
- Deciders: <names / roles>

## Context
What is the issue we are seeing that motivates this decision?

## Decision
What we decided. Be specific. Include the *not-chosen* alternatives.

## Consequences
What becomes easier? What becomes harder? What does this lock us into?
```
