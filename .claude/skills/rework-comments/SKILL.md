---
name: rework-comments
description: Audit and rework code comments across AltTab so they help an AI agent instead of misleading it. Triages every comment by whether its claim is verifiable and non-derivable, deletes process narration and repeated lessons, shrinks history to test names, and flags comments that have drifted out of sync with the code. Use for a whole-codebase pass, for one file or folder that feels over-commented, after a big refactor, or whenever an agent has been misled by a comment.
---

# /rework-comments

Rework comments so the ones that survive are the ones an agent can act on. Runs on the whole of `src/`, or on a path you pass as an argument.

## Why this exists (the evidence)

Measured on recent models, including Claude Code on Sonnet 4.6:

- **Wrong beats absent, by a lot.** Misleading comments cost ~13.5pp on code-reasoning benchmarks; *removing* comments costs 2.4–8.2pp ([CodeCrash](https://arxiv.org/pdf/2504.14119)). A stale comment is 2–6x more expensive than no comment. It also inflates reasoning tokens 2–3x.
- **Volume is not the lever.** 660 Claude Code trials on minimal-pair repos found no pass-rate difference from cleanliness, and a dedicated comment-volume ablation showed comment lines are *not* what drives agent token cost or file re-reads ([Trivedi & Schmitt, SonarSource 2026](https://arxiv.org/abs/2605.20049)).
- **Short and single-intent beats long and mixed.** Across 80k translations, ~5-word descriptive comments outperformed 19-word author comments that mixed several intents ([study](https://co-r-e.com/method/code-comments-translation)).
- **Repetition and conflict cost attention.** Anthropic cut 80%+ of Claude Code's system prompt with no eval loss, and names redundancy across sources and conflicting statements as the specific costs ([Claude 5 context engineering](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models)).

So: **do not cut on line count. Cut on drift surface.** The goal is fewer claims that can go stale, not fewer characters. A correct, non-obvious comment stays no matter how long it is.

## The triage rule

For each comment, ask two questions in order.

**1. Can a reader verify this claim from the code in front of them?**

- **No, and it is a fact about the outside world** (macOS / CGS / SkyLight / AppKit behaviour, an OS timing quirk, a measured capture, an API contract) → **KEEP**. This is the irreplaceable category. It cannot be re-derived without reproducing the bug.
- **No, and it is a fact about our own history or process** ("this used to be X", "we tried Y and reverted", "this comment used to say", "the lesson written three times in this file") → **CUT**. An agent cannot act on it, and it reads as a live claim about current code.
- **Yes, it restates what the code says** → **CUT**, unless it names a consequence the code doesn't show.

**2. What breaks if it goes?**

- *"Someone re-simplifies this and reintroduces a bug"* → **KEEP, but shrink to the guardrail.** One sentence for the constraint, plus the test name that enforces it. The test is what actually holds the line; the prose only needs to point at it.
- *"Nothing"* → **CUT.**

Everything else is a judgment call, and the default on a judgment call is keep. A wrongly-deleted true comment costs more than a kept mediocre one.

## Categories, in priority order

Work these in order. The first is the one that pays.

**P1 — Drifted comments (the only category that hurts correctness).**
A comment whose claim contradicts the code beside it, names a symbol that no longer exists, describes a branch that moved, or states an ordering the code no longer has. Fix the comment, or delete it if the fact is gone. **Never fix by changing the code to match the comment** — report that as a possible bug instead and leave both alone.

**P2 — Repeated lessons.**
The same rule stated in more than one place in a file (or across sibling files). Keep the clearest statement at the highest-scope declaration (the `enum`/`struct`/file header), delete the restatements. If a restatement carries a detail the canonical one lacks, move the detail up rather than keeping both.

**P3 — Process narration and meta-commentary.**
Abandoned approaches, "this was tried and reverted", commentary about what a previous version of the comment said, apologies, self-aware asides about the comment itself. If a reverted approach is genuinely load-bearing (someone will obviously retry it), compress to one clause: `// tried pairing with newlyDiscovered; breaks testX`.

**P4 — Restatement of the code.**
`// increment the counter` above `count += 1`. Delete outright. Per AGENTS.md, if a block needs a comment to be followable, prefer splitting it into a named sub-method.

**P5 — Structurally broken comments.**
Bullet lists interrupted mid-flow by a paragraph so the trailing bullets appear to belong to a different list; comments whose indentation detached them from the statement they explain; doc comments that drifted above the wrong declaration. Partial reads of these give wrong answers, so they behave like P1.

## What always survives

Do not touch these, even in a file that is 2:1 comments to code:

- Invariants and preconditions stated once at the top of a type (e.g. the fullscreen Space invariant in `TabGroupResolver.swift`).
- Non-derivable OS/API behaviour, especially with measured evidence (`the OS creates a new tab at 0×0 and sizes it ~640ms later`).
- Private-API notes, `#`-issue references, and undocumented-behaviour warnings.
- Doc comments on kernel entry points that the matching `*Specs.md` refers to.
- The reason a guard exists, when the guard looks removable without it.
- Licence headers, `// MARK:` structure, `swiftlint` directives.

## Workflow

1. **Scope and baseline.** Default to `src/`; use the path argument if given.
   ```sh
   find src -name '*.swift' -not -path '*_test-support*' | wc -l
   ```
   Measure comment-to-code ratio per file and repo-wide:
   ```sh
   for f in $(find src -name '*.swift' -not -path '*_test-support*'); do
     awk -v F="$f" '{ if ($0 ~ /^[[:space:]]*(\/\/|\/\*|\*)/) c++; else if ($0 !~ /^[[:space:]]*$/) k++ }
       END { if (k > 0) printf "%.2f %d %d %s\n", c/k, c, k, F }' "$f"
   done | sort -rn | head -40
   ```
   Report the repo baseline ratio and the outliers. **The ratio picks reading order, it is not a target.** A 3:1 file of measured OS facts is fine; a 0.4:1 file of stale restatement is not.

2. **Read whole files, never grep for comments in isolation.** Every triage question is about the comment *against its code*. A comment excerpt cannot be judged.

3. **Triage per file.** Walk the comments top to bottom, tag each P1–P5 or KEEP. For P1, verify the drift by reading the code the comment describes — if you cannot confirm it drifted, it stays.

4. **Apply.** Edit comments only. One file at a time. On a whole-codebase run, checkpoint progress to `.claude/scratch/rework-comments-progress.md` (file · status · findings) after each file, so an interrupted run resumes without re-reading.

5. **Verify nothing but comments changed.** This is the safety property of the whole skill:
   ```sh
   git diff -U0 -- '*.swift' | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
     | grep -vE '^[+-][[:space:]]*(//|/\*|\*|\*/)' | grep -vE '^[+-][[:space:]]*$'
   ```
   This must print nothing. If it prints a line, you changed code — revert that hunk. The one false positive: editing a **trailing** comment (`let x = 2  // note`) rewrites a code line, so it shows up here. Confirm by eye that the code before the `//` is byte-identical, then move on.

6. **Build.** Copy the commands from `ai/build.sh` and run them. Comment-only edits can still break a build (an unterminated block comment, a doc comment detached from its declaration).

7. **Cross-check the specs.** If you touched a kernel's doc comments, run `/audit-specs-tests` for the affected triads — the `*Specs.md` may quote the prose you changed.

## Reporting

- Repo baseline ratio, and a table of the files you reworked: path · before/after comment lines · categories applied.
- **P1 findings listed separately and first**, each with file:line, the claim, and what the code actually does. These are the ones the user most needs to see, and the ones most likely to indicate a real bug rather than a doc error.
- Anything you deliberately kept that looks over-commented, with the one-line reason (usually: measured OS behaviour).
- Any place where the comment and the code disagreed and **the comment looked right** — a suspected bug, left untouched, for the user to decide.
- If a file is already in good shape, say so and move on. Do not manufacture edits to show effort.
