# ADR-0001: Record architecture decisions

- Status: Accepted
- Date: 2024-12-01
- Deciders: Project maintainers

## Context

We need to record the architectural decisions made on this project.
Without that record, the rationale gets lost — newcomers reverse-
engineer choices from the code, propose churn that has already been
considered and rejected, or quietly drift away from the design.

## Decision

We will use **Architecture Decision Records** (ADRs) following the
template proposed by Michael Nygard
([source](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)).

ADRs live under `docs/adr/`, are numbered sequentially, and are written
in Markdown. They are immutable once accepted: subsequent decisions
that supersede an ADR get a new number and reference the predecessor
in their `Status` line.

## Consequences

- **Easier**: onboarding, design review, retrospective sense-making.
- **Harder**: requires discipline to keep current. Decisions that
  bypass an ADR slip into tribal knowledge.
- **Lock-in**: very low — ADRs are plain markdown and have no tooling
  dependency. They render in GitHub and in the MkDocs site.
