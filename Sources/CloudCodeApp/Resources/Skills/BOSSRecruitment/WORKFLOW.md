# BOSS Recruitment Mobile Skill Workflow

This file defines only the iOS execution shape. Business eligibility, blacklists, deduplication, pacing, completion, and safety gates come exclusively from the bundled `BOSS_CONTACT_POLICY.md` snapshot.

## Execution model

1. Load and verify the canonical policy resource before planning any BOSS action.
2. Foreground `com.hpbr.bosszhipin` and take a fresh semantic observation.
3. Prefer AX/UI-tree semantics for navigation, text extraction, and element identity.
4. When AX is missing one required field, crop to the smallest relevant region and use local OCR once for that region.
5. Use screenshot/vision only when AX plus bounded local OCR still cannot establish the required semantic state.
6. Never persist raw screen coordinates. Coordinates may be derived only from the current observation for one immediate action.
7. Keep navigation and send pacing human-paced according to the canonical policy. Read-only filtering and preparation may happen during send cooldown.
8. Before opening a communication flow, re-check candidate identity, permanent deduplication, blacklist, work location, recruiter activity, and current page identity.
9. Before any send, inspect the visible chat state and reconcile prior contact. An uncertain previous send is never blindly retried.
10. Send at most once for the current candidate, then obtain a fresh post-action observation and require visible confirmation before committing success to the ledger.
11. A failed or ambiguous postcondition remains pending/blocked; it must not increment batch progress.
12. Continue the same batch state until the canonical policy says the batch is complete or a fail-closed safety state requires user action.

## Semantic state machine

`preflight -> foreground -> discover -> candidate_screen -> detail_audit -> recruiter_audit -> chat_reconcile -> draft_ready -> send_once -> verify_send -> commit_ledger -> batch_progress`

Safe local recovery may return to the immediately preceding read-only state after a fresh observation. Send-related recovery always goes through `chat_reconcile` before another write is even considered.

## Perception priority

`AX/UI Tree -> local ROI OCR -> screenshot vision -> stop/replan`

Full-screen OCR is not a normal loop step. OCR is a gap-filler, not the primary page parser.

## Safety invariants

- Visible controls only.
- No hidden BOSS API, WebSocket, MQTT, or private sending protocol.
- No parallel send chains.
- No automatic CAPTCHA, account restriction, login-expiry, or rate-limit bypass.
- No success accounting without a verified postcondition.
- No second send after an ambiguous first send without reconciliation.
- No business-rule override inside this mobile workflow.
