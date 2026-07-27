---
name: shape
description: Create clear, actionable contracts that define project goals, implementation details, and success validation criteria. Use this skill when you need to outline project objectives and ensure all key factors are addressed before moving forward with implementation.
disable-model-invocation: true
---

# Shape

Enter /plan mode and create a compact contract between intent, implementation, and validation.

## 1. Make the destination clear

Name the observable destination first: what must become true and what lies
outside this effort.

- Inspect the relevant territory before prescribing the solution.
- Resolve facts from available sources. Put consequential decisions to the
  user, with a recommended answer.
- Choose the cheapest method that reduces material uncertainty: inspection,
  research, comparison, prototype, or question.
- When quality is difficult to describe, use reference artifacts and name the properties that should transfer.
- Reframe the work when evidence invalidates the original premise.

When useful, distinguish:

- **known knowns:** explicit outcomes, constraints, facts, and decisions;
- **known unknowns:** recognized gaps that may change the work;
- **unknown knowns:** tacit preferences or criteria to surface as hypotheses;
  and
- **unknown unknowns:** relevant blind spots outside the current framing.

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
