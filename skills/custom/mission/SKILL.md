---
name: mission
description: Orchestrate projects too large or complex for one reliable agent context. Use only when explicitly invoked to define correctness before implementation, decompose work into bounded features for fresh workers, externalize shared state, and drive independent milestone validation until the mission passes or reaches a genuine blocker.
disable-model-invocation: true
---

# Mission

Run large work through focused contexts and independent judgment. Keep the
orchestrator at low resolution; delegate investigation, implementation, and
validation.

## Separate the roles

- **Orchestrator:** Own the destination, validation contract, decomposition,
  shared state, scheduling, and completion decision. Do not implement features
  or perform their final validation.
- **Worker:** Implement one bounded feature, verify its own work, and return
  results. Do not decide whether the mission is complete.
- **Validator:** Start fresh, evaluate assigned work, and report evidence and
  gaps. Do not implement fixes.

Give each run only the goal and state relevant to its role. Do not pass worker
reasoning or conclusions to validators when raw artifacts and behavior are
available.

## 1. Frame the mission

Clarify the observable destination, scope, non-goals, boundaries, and material
unknowns. Reuse an existing `shape-work` brief and validation contracts when
available. Define correctness before planning features.

Write a finite validation contract of independently verifiable behavioral
facts:

```md
### PROJ-NAME-001: <verifiable fact>
Goal: <precondition or action and its observable outcome>
Tool: <tool or verification method>
Evidence: <specific artifact, assertion, response, screenshot, log, or metric>
```

Prefer black-box contracts for user-visible behavior. If a required fact has no
feasible tool or concrete evidence, resolve that blocker before decomposition.

## 2. Externalize only shared state

Use a dedicated mission directory supplied to agents; do not scatter mission
files in the product repository root.

Create only what the mission needs:

- `mission.md`: destination, scope, boundaries, milestones, and current status;
- `validation-contract.md`: the authoritative definition of success;
- `features.json`: executable feature state and contract coverage;
- `knowledge.md`: durable facts and decisions future agents need; and
- `operations.yaml`: commands and services, only when they are not already
  discoverable from the repository.

Do not store transcripts or running narratives. Update shared state with concise
facts, decisions, evidence pointers, and blockers.

## 3. Decompose against correctness

Create features only after the validation contract. Each feature must fit one
focused worker context and declare its dependencies, milestone, expected
behavior, verification steps, and the contracts it contributes to:

```json
{
  "id": "<feature-id>",
  "description": "<bounded implementation outcome>",
  "skills": ["tdd"],
  "milestone": "<milestone-id>",
  "dependsOn": [],
  "expectedBehavior": [],
  "verificationSteps": [],
  "fulfills": ["PROJ-NAME-001"],
  "status": "pending"
}
```

Use the optional `skills` field to name workflows the worker must explicitly
invoke. Assign `tdd` only when the behavior has an appropriate automated test
seam; do not force it onto exploratory, visual, or non-deterministic work.

Every contract must be covered. Avoid features that merely divide files or
technical layers without delivering a coherent behavior or enabling another
feature.

## 4. Execute with fresh workers

Select features whose dependencies are complete. Run independent features in
parallel only when resources and boundaries make that safe.

Give each worker:

- its feature object;
- the relevant validation contracts;
- mission boundaries and operational commands;
- relevant accumulated knowledge; and
- applicable repository instructions.

Have the worker explicitly invoke assigned skills. Where no assigned workflow
governs implementation, define verification before changing code and write
behavioral tests first when the repository has an appropriate test seam.
Require the worker to return the work performed, checks run, implementation
evidence, knowledge updates, and blockers. Worker verification demonstrates
feature progress but cannot pass a validation contract; only a fresh validator
may record a contract as passed, failed, or blocked. Update shared state from
that structured handoff rather than loading the worker's full trajectory.

## 5. Validate milestones independently

When a milestone's features are complete, start fresh validators. Run at least
one independent validation pass; separate these axes when both matter:

- **Scrutiny:** Review the implementation, tests, standards, and alignment with
  the feature and mission constraints.
- **User testing:** Exercise the system as a black box and evaluate validation
  contracts using their named tools and evidence.

Record each contract as passed, failed, or blocked with evidence. Validators
surface issues only.

Convert actionable findings into bounded fix features linked to the affected
contracts. Send them to fresh workers, then re-run the milestone's relevant
validation. Repeat until it passes.

## Complete or halt

Complete the mission only when every validation contract has independently
produced its required evidence, all features are complete, and no in-scope
blocker remains.

If progress requires unavailable access, a user decision, unsafe boundary
expansion, or an unresolvable dependency, halt and return the exact blocker,
affected contract and feature IDs, attempts made, and the action needed from the
user.
