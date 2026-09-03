# Harness Mapping

Cloud Code iOS must not create a second competing agent loop beside `AgentCore`.

This mapping was rebuilt from the current local Windows state before the iOS changes:

- `D:\wendangcodex\CloudRuntime\README.md` states that the official Claude Code binary remains the actual desktop Harness and that the provider relays are transport infrastructure only.
- `D:\wendangcodex\CloudRuntime\tabitoken_relay.py` explicitly keeps tool-result normalization, tool-history sanitization/compaction, tool-loop guard, schema pruning and text repair disabled at the relay boundary because the Harness owns the tool manifest, tool history, permissions, planning and context management.
- `D:\wendangcodex\CrowdCode\CLAUDE.md` is the user's enhanced Harness policy layer: autonomous bounded execution, batched independent tool work, safe retries, explicit steering, long-running task behavior, multi-agent limits, memory discipline and convergence rules.

## iOS ownership

The iOS implementation reuses the existing `AgentCore` as the single Harness owner:

| Harness responsibility | iOS owner |
| --- | --- |
| Agent/tool loop | `AgentCore` |
| Tool schema + routing | `ToolRegistry` + `ToolRouter` |
| Permission/risk boundary | `PolicyEngine` + executor approvals |
| State-changing idempotency | `ToolExecutionLedger` + stable `ToolCall` IDs |
| Transaction/rollback | `TransactionEngine` |
| Steering | `AgentSteeringMailbox` |
| Session history | `SessionStore` |
| Checkpoint/restart recovery | `TaskCheckpointStore` |
| Provider interruption recovery | `ProviderStreamingTransport` + `AgentCore` checkpoint semantics |
| Context management | `HarnessContextManager` + Hermes recall |
| Long tasks / background lifecycle | `AppEnvironment` 90-minute continuation window + checkpoints |
| Durable memory | `HermesMemoryStore` |

## Rules retained from the desktop Harness

1. Provider relays/transports do not own the agent loop or tool history.
2. Retry must be bounded and must not replay a request after model/tool output has started.
3. A provider transport failure must not implicitly rotate to another provider.
4. Tool execution remains typed and state-changing calls are idempotent/reconciled before replay.
5. Steering is applied at safe boundaries; an already-running destructive tool is not abandoned halfway through.
6. Long-running work is checkpointed rather than relying on a permanently alive process.
7. Context compression changes only what is sent to the model. Full local session history is retained.
8. Memory is context data, not policy authority, and never bypasses `CapabilityProbe`, `ToolRouter`, `PolicyEngine`, approval, audit or final-state verification.

## What was intentionally not copied

- No desktop relay or provider adapter becomes an iOS Harness.
- No second planner/tool loop was introduced around `AgentCore`.
- No root shell is granted directly to the model.
- No automatic cross-provider fallback is added.
- No desktop-only watchdog or process model is copied literally; iOS uses lifecycle cancellation + durable checkpoints instead.
