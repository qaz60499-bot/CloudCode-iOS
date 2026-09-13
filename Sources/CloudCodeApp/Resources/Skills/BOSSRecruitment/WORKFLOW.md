# BOSS Recruitment Mobile Skill Workflow

This file defines only the iOS execution shape. Business eligibility, blacklists, deduplication, pacing, completion, and safety gates come exclusively from the bundled `BOSS_CONTACT_POLICY.md` snapshot.

## Execution model

1. Load and verify the canonical policy resource before planning any BOSS action.
2. Resolve `targetFinalValid` once: 5 normally, or exactly 3 only when external authorization explicitly selects canonical `EARLY_HANDOFF_3`.
3. Load/reconcile current progress before navigation. Candidate-level handled/skipped/rejected outcomes never satisfy the batch target.
4. Foreground `com.hpbr.bosszhipin` and create one fresh observation epoch.
5. Prefer AX/UI-tree semantics for navigation, text extraction, and element identity. Reuse that valid tree for all read-only decisions on the unchanged screen.
6. When AX is missing one required field, crop to the smallest relevant region and use local OCR once for that region in the current epoch.
7. Use screenshot/vision only when AX plus bounded local OCR still cannot establish the required semantic state.
8. Never persist raw screen coordinates. Coordinates may be derived only from the current observation for one immediate action and expire after any UI mutation.
9. Keep navigation and send pacing human-paced according to the canonical policy. Read-only filtering and preparation may happen during send cooldown.
10. Before opening a communication flow, re-check candidate identity, permanent deduplication, blacklist, work location, recruiter activity, and current page identity.
11. Before any send, inspect the visible chat state and reconcile prior contact. An uncertain previous send is never blindly retried.
12. Send at most once for the current candidate, then create a new post-action observation epoch and require visible confirmation before committing success to the ledger.
13. A failed or ambiguous postcondition remains pending/blocked; it must not increment batch progress.
14. After every candidate outcome, evaluate the terminal gate. If the gate is false and there is no real fail-closed blocker, continue the same batch from `discover` or the next actionable read-only state instead of returning.
15. Provider/API/network/tool-call boundaries are runtime events, not business completion. If the host cannot recover in the current invocation, preserve the checkpoint and expose an incomplete/recoverable state rather than a success label.

## Semantic state machine

`preflight -> resolve_target -> reconcile_progress -> foreground -> discover -> candidate_screen -> detail_audit -> recruiter_audit -> chat_reconcile -> draft_ready -> send_once -> verify_send -> commit_ledger -> terminal_gate`

If `terminal_gate == false`, transition back to `discover` or the next already-prepared read-only candidate state. Do not transition to a final response merely because the current candidate reached a local outcome.

Safe local recovery may return to the immediately preceding read-only state after a fresh observation. Send-related recovery always goes through `chat_reconcile` before another write is even considered. Transient host/provider failures preserve the same run target and progress; they never create a new batch implicitly.

## Perception priority and observation epochs

`AX/UI Tree -> local ROI OCR -> screenshot vision -> stop/replan`

Full-screen OCR is not a normal loop step. OCR is a gap-filler, not the primary page parser.

For one unchanged screen/epoch:

- acquire the primary AX tree once;
- extract all currently needed semantic fields from that same tree;
- OCR only unresolved ROIs, once per ROI unless the screen changed;
- reuse current screenshot/semantic targets while the epoch is valid;
- do not call AX, OCR, screenshot, and model vision serially for every single field;
- if AX fails or is clearly unhealthy, do not repeatedly probe AX again in the same epoch.

Any tap, type, scroll, swipe, navigation, dialog transition, keyboard transition, send, or other state-changing action invalidates raw geometry and begins a new epoch before another state-changing action.

## Terminal gate

The run may return a successful terminal result only when all of the following are proven:

- `finalValid == targetFinalValid`;
- all counted contacts still satisfy the canonical business rules and permanent deduplication;
- each counted send has a verified visible postcondition and committed progress/ledger evidence;
- no counted or attempted send remains ambiguous/pending;
- target 5 maps only to `COMPLETED_5`;
- target 3 maps only to explicitly authorized `EARLY_HANDOFF_3`.

`0/target`, `1/target`, `2/target`, and `4/5` are nonterminal. `candidate_handled`, `candidate_skipped`, `candidate_rejected`, `wave_done`, `tool_done`, `cooldown_wait`, `provider_retry_exhausted`, and `perception_miss` are not successful terminal states.

If a real safety gate or supply blocker prevents continuation, return the canonical blocker state with current progress and reason. Cleanup/finalization may run on any exit, but cleanup success must never be converted into business completion.

## Safety invariants

- Visible controls only.
- No hidden BOSS API, WebSocket, MQTT, or private sending protocol.
- No parallel send chains.
- No automatic CAPTCHA, account restriction, login-expiry, or rate-limit bypass.
- No success accounting without a verified postcondition.
- No second send after an ambiguous first send without reconciliation.
- No business-rule override inside this mobile workflow.
