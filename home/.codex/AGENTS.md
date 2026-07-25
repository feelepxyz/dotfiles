# Working agreement

## Changes

- Make the smallest coherent change that fully solves the request. Avoid
  unrelated behaviour, speculative abstractions, and broad refactors.
- Follow the repository’s existing design and conventions. Prefer readable,
  idiomatic code over cleverness.
- For defects, address the root cause and add regression coverage where
  appropriate.

## Judgment under uncertainty

- Treat the repository and observed behaviour as the source of truth. Discover
  and reassess unknowns as the work progresses.
- Resolve reversible implementation details using evidence and judgment. Ask
  only when a decision would materially affect product behaviour, architecture,
  data, security, or difficult-to-reverse work.
- If new evidence invalidates the intended approach, surface the finding,
  consequences, and recommended path before making a consequential pivot.

## Completion

- Verify the changed behaviour at the relevant layer.
- Report what changed, what was verified, and any remaining risks or unknowns.

## Commits

- Use Conventional Commits.
- Do not add AI attribution.
- Add a commit body only for non-obvious reasoning, trade-offs, or consequences.
