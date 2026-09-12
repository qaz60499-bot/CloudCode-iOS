---
name: boss-recruitment
description: Use when the user explicitly selects the BOSS 招聘联系 skill or asks Cloud Code to run the bounded BOSS直聘 recruitment/contact workflow on iPhone. Apply the bundled canonical business policy, use fresh device observations, prefer AX when healthy with local OCR/screenshot fallbacks, preserve permanent deduplication and exactly-once send safety, and stop rather than guessing when a safety gate cannot be verified.
---

# BOSS 招聘联系

This is a mobile execution skill, not an authority grant. ToolRouter capabilities, permission policy, confirmations, fresh observations, idempotency guards, and postcondition verification always remain in force.

## Progressive loading

1. Use this file for routing and execution shape.
2. Read `BOSS_CONTACT_POLICY.md` before evaluating or contacting any candidate. Its integrity hash is verified by the app and it is the only source of business eligibility, blacklist, deduplication, pacing, completion, and safety rules.
3. Read `WORKFLOW.md` when the task reaches the BOSS App execution phase. It defines the iOS observation/action/reconciliation sequence.
4. Do not load unrelated skill resources into the provider context.

## Runtime rules

- Work from the current BOSS App state; never trust coordinates or UI state from an earlier run.
- Prefer semantic AX observations when they are fast and healthy. If AX is slow/unavailable, use bounded local OCR from the current screenshot, then screenshot vision only when still needed.
- Reuse fresh observations and cached semantic targets within their validity window instead of rescanning the entire screen before every action.
- Use deterministic local bounded operations for finite repeated browsing/collection when available instead of one provider round-trip per item.
- Before any irreversible contact/send action, reconcile current chat/contact state and permanent deduplication state.
- After a send candidate is dispatched, verify the postcondition. If the postcondition is uncertain, do not send again automatically.
- Stop on ambiguity, protected confirmation surfaces, stale observations, policy mismatch, or exhausted recovery budget.

## Completion

A batch is complete only when the canonical policy's completion condition is satisfied and the local progress/ledger state agrees with the verified UI outcome. Opening BOSS, typing text, or changing pixels is not completion by itself.
