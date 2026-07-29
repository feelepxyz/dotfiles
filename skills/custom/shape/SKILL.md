---
name: shape
description: Turn a request into a compact contract — the observable destination, the implementation brief, and the validation contracts that prove it. Use before committing to implementation.
disable-model-invocation: true
---

# Shape

Create a compact contract between intent, implementation, and validation. Use
EnterPlanMode when the shaped work will be implemented in this session; shaping
an analysis or a decision needs no plan mode.

## 1. Make the destination clear

Name the observable destination first: what must become true and what lies
outside this effort.

- Inspect the relevant territory before prescribing the solution.
- Choose the cheapest method that reduces material uncertainty: inspection,
  research, comparison, prototype, or question.
- When quality is difficult to describe, use reference artifacts and name the properties that should transfer.
- Reframe the work when evidence invalidates the original premise.

Surface tacit criteria as explicit hypotheses, and name the blind spots outside
the current framing — those are the gaps that reshape the work, not the ones
already on the list.

Ask together only decisions whose prerequisites are settled. Leave dependent
questions as fog until earlier answers make them precise. Stop exploring when
remaining details can safely be resolved during implementation.

## 2. Define the implementation brief

Include only what the implementer needs:

- the destination and observable behavior;
- constraints and non-goals;
- consequential decisions and unresolved blockers; and
- the smallest coherent implementation boundary.

## 3. Derive validation contracts

After the destination and blocking decisions are clear, decompose success into
the smallest useful set of independently verifiable facts.

Each contract must:

- use stable sequential IDs derived from a short project name
- prove one observable fact, not describe an implementation task;
- state the scenario or action and expected outcome in **Goal**;
- name a feasible verification mechanism in **Tool**; and
- specify the concrete artifact or observation that demonstrates success in
  **Evidence**.

Together, the contracts must be sufficient to prove the destination. Remove
duplicates. Include failure cases, boundaries, compatibility, security, or
non-functional properties only when the destination makes them material.

If a required fact has no feasible tool or concrete evidence, first try to design and calibrate a credible verifier. If none is feasible, treat that as an unresolved blocker and return to shaping.

## Return

Return one package containing the implementation brief followed by the
validation contracts. Keep it in the response unless it must persist across
sessions or collaborators.

Shaping is complete when the destination is clear, consequential uncertainty is
resolved or named as a blocker, and every required success fact has a feasible
way to produce evidence. Do not implement production code unless asked.
