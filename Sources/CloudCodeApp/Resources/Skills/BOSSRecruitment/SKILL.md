---
name: boss-recruitment
description: Use when the user explicitly selects the BOSS 招聘联系 skill or asks Cloud Code to run the bounded BOSS直聘 recruitment/contact workflow on iPhone. Apply the bundled canonical business policy, keep the same batch nonterminal until its real terminal state is proven, reuse fresh observations instead of rescanning, prefer AX with bounded OCR/screenshot fallbacks, preserve permanent deduplication and exactly-once send safety, and never treat one candidate outcome as batch completion.
---

# BOSS 招聘联系

This is a mobile execution skill, not an authority grant. ToolRouter capabilities, permission policy, confirmations, fresh observations, idempotency guards, and postcondition verification always remain in force.

## Progressive loading

1. Use this file for routing and execution shape.
2. Read `BOSS_CONTACT_POLICY.md` before evaluating or contacting any candidate. Its integrity hash is verified by the app and it is the only source of business eligibility, blacklist, deduplication, pacing, completion, and safety rules.
3. Read `WORKFLOW.md` when the task reaches the BOSS App execution phase. It defines the iOS observation/action/reconciliation sequence.
4. Do not load unrelated skill resources into the provider context.

## Run target and no-premature-exit rule

Resolve the batch target once when the run starts and retain it for the whole run. Normal execution targets 5 final-valid contacts. Only explicit external authorization may select the canonical early-handoff target of exactly 3. Never infer early handoff from elapsed time, one tool returning, a Provider/API failure, one candidate being handled, or a partial count.

A candidate-level outcome is never a batch terminal state. Rejected, skipped, duplicate, already-contacted, ambiguous, or otherwise handled candidates return control to the same batch loop. A discovery wave ending, a cooldown boundary, a local perception miss, or one provider request ending also remains nonterminal.

If the Cloud Code host itself must stop the current invocation because runtime recovery is exhausted, preserve progress/checkpoint state and report the run as incomplete or blocked. Never translate a host/transport boundary into "processed", "done", or successful BOSS batch completion.

## Fast observation rules

- Work from the current BOSS App state; never trust coordinates or UI state from an earlier mutated screen.
- Treat one unchanged screen as one observation epoch. Within that epoch, reuse the first valid AX tree, extracted text, semantic targets, screenshot, and ROI OCR results instead of reacquiring the whole screen for each field.
- Perform at most one primary AX acquisition for the same unchanged screen unless direct contradictory evidence proves the observation stale or corrupt.
- If AX already contains a required field or target, do not OCR that field merely to reconfirm it.
- When AX misses a required field, use one bounded OCR pass on the smallest relevant region. Full-screen OCR is not a normal loop step.
- If AX is unavailable or slow in the current epoch, stop repeatedly probing the same AX path and continue through the bounded local fallback path.
- Use screenshot/model vision only after AX plus local ROI OCR still cannot establish a required semantic fact.
- Collect all fields needed for the current read-only decision from the same observation where possible; do not create one provider round-trip per field.
- Any state-changing UI action starts a new observation epoch. Before the next state-changing action, obtain fresh evidence for that new epoch.
- Raw coordinates expire when the screen changes. Reusable semantic facts may survive only while their page identity remains proven.

## Runtime rules

- Provider/API retry, stream reconnection, backoff, checkpoint persistence, and app/background recovery belong to the Cloud Code host, not this Skill.
- A transient Provider/API/network/stream failure does not mark the BOSS batch complete.
- If an externally visible action may already have happened, recovery must return through fresh observation and reconciliation instead of blind replay.
- Use deterministic local bounded operations for finite repeated browsing/collection when available instead of one provider round-trip per item.
- Before any irreversible contact/send action, reconcile current chat/contact state and permanent deduplication state.
- After a send candidate is dispatched, verify the postcondition. If the postcondition is uncertain, do not send again automatically.
- Stop only on a canonical terminal state or a real fail-closed blocker such as a protected confirmation surface, account safety gate, policy mismatch, or exhausted safe recovery budget.

## Completion

A successful batch return requires the canonical completion condition and matching local progress/ledger evidence. For a normal run the terminal label is `COMPLETED_5`; for explicitly authorized early handoff it is `EARLY_HANDOFF_3`. Opening BOSS, screening one candidate, typing text, changing pixels, or finishing one tool call is never completion by itself. Nonterminal work must continue in the same batch rather than returning merely because something was "handled".
