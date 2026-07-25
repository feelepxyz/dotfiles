---
name: tdd
description: Implement or change software through a focused test-driven loop. Use when user or agent explicitly uses 'tdd' or invoked for behavior with an appropriate automated test seam, including a shape-work validation contract or mission worker feature.
---

# TDD

Use executable examples to drive a behavior change and leave the system ready
for the next one.

## Establish the boundary

Read the request, relevant `shape-work` validation contracts or mission feature,
repository instructions, current behavior, and nearby tests.

- Treat validation contracts as the required outcome. Do not rewrite them into
  implementation-shaped criteria.
- Choose the cheapest test seam with enough fidelity to catch the material
  failure. Prefer stable behavior over internal collaboration.
- Do not introduce mocks, interfaces, or layers solely to make a test isolated.
  Test friction is evidence to inspect the design, not proof that more
  indirection is needed.
- If the behavior has no honest automated seam yet, or the work is primarily
  exploratory, visual, or non-deterministic, use a more suitable feedback loop
  and state why TDD is not driving this change.

For untested legacy behavior that must remain stable, characterize only the
relevant behavior before changing it. For a defect, reproduce it with a
regression test at the narrowest stable boundary.

## Make the test list

List the behavioral scenarios needed for this change before editing production
code. Include the normal case and only material boundaries, failures, and
regressions. Map scenarios to validation contract IDs when present.

Keep the list behavioral; defer implementation design. Do not turn the whole
list into test code upfront. Select the next scenario that yields useful
behavior or design information with the least setup.

Scale the list to risk rather than coverage targets. Add generative or fuzz
tests when correctness is better expressed as an invariant over a large,
hostile, or combinatorial input space. Run fuzzing only in a disposable,
bounded environment; retain the seed and reduce any failure to a deterministic
regression case.

## Evolve one example at a time

For each scenario:

1. Write one concrete test, working backward from an independently derived
   expected outcome.
2. Run it and confirm it fails for the intended reason. If it passes, determine
   whether the behavior already exists or the test cannot detect the gap.
3. Make the smallest coherent production change that passes this test and all
   prior tests. Add newly discovered scenarios to the list.
4. Refactor only while green. Improve the interface or implementation when the
   new evidence warrants it; do not generalize ahead of another scenario.
5. Run the relevant suite, then choose the next scenario.

When confidence in a test is uncertain, perturb the relevant production
behavior or use targeted mutation testing and confirm the test detects it.
Remove tests that add no distinct confidence unless they materially improve
the executable explanation of behavior.

## Hand off

Return:

- scenarios completed, deferred, or discovered, with contract mappings;
- tests and production behavior changed;
- the failing and passing commands and what each demonstrated;
- consequential design feedback or deviations; and
- remaining gaps or unsuitable seams.

In a mission, report which contracts the work contributes to but do not mark
them passed. Worker tests guide implementation; fresh validators still produce
the contract's required independent evidence.
