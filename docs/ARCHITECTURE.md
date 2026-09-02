# Architecture

## Core

```text
Cloud Code iOS
├── Agent Core
│   ├── SessionStore
│   ├── AgentCore tool loop
│   ├── streaming provider client
│   ├── conservative retry
│   ├── checkpoints
│   └── verification
├── Phone Intelligence
│   ├── ProgressiveResourceIndex
│   ├── CapabilityProfile
│   ├── AppKnowledgeRegistry
│   └── ResourceResolver
├── Tool Router
│   ├── StructuredToolExecutor
│   ├── IOSSystemExecutor
│   ├── private/privileged adapter slot
│   ├── URL scheme adapter slot
│   └── GUIFallbackExecutor
├── Services
│   ├── Files
│   ├── Apps / Containers
│   ├── Storage
│   ├── IPA
│   └── future Photos/System/Automation adapters
├── Safety
│   ├── ToolDescriptor + ToolRisk
│   ├── PolicyEngine
│   ├── SensitivityClassifier
│   ├── PathGuard
│   ├── TransactionEngine
│   ├── TrashService
│   ├── AuditLogStore
│   └── ToolOutputEnvelope
└── SwiftUI
    ├── Chat
    ├── Tasks
    ├── Phone
    ├── Apps
    ├── Files
    ├── Activity
    ├── Trash
    └── Settings
```

## Tool-first routing

The core does not use screenshots as the default observation mechanism. A request such as “why is Telegram using so much storage?” should resolve the app, dynamically resolve its current container, analyze directory/file metadata and return a structured result. GUI automation is only selected if typed/native/CLI/private/intent paths cannot satisfy the task and a GUI backend has proven availability.

The GUI interface is backend-neutral: open app, tree, screenshot, tap, type, scroll, swipe and verify. The phase-1 app ships with an unavailable backend rather than claiming XCTest/WDA support on a device where it was not proven.

## Resource identity

Container UUID paths are runtime locations, not durable identity. The persistent graph stores logical identifiers such as:

- `app://org.telegram.Telegram`
- `container://org.telegram.Telegram/Documents`
- `file:///...`
- `ipa:///...`

The resolver asks the active app/container adapter for the current real path each time.

## Progressive indexing

Startup seeds only lightweight app/capability nodes. Deep file traversal is triggered by a bounded tool invocation for a target resource. This prevents first-launch whole-device scans.

## Permission separation

Capability Probe detects whether a backend is available. Policy Engine decides whether the Agent may invoke a state-changing tool.

- Safe: reads and ordinary creation may proceed; important writes, deletion, install/uninstall, external side effects and permanent destruction require approval.
- Balanced: ordinary changes may proceed; deletion goes to Trash; important/irreversible operations still require approval.
- Full: user-selected mode can skip most confirmations, while audit/transactions/backups remain active where feasible.

The Agent has no tool that changes its own permission mode.

## Transaction invariant

Important replacement follows:

1. Validate target and allowed root.
2. Snapshot target identity.
3. Read original and generate diff/summary.
4. Ask for approval when policy requires it.
5. Re-check identity to reduce TOCTOU risk.
6. Create backup.
7. Write temporary data and atomically replace.
8. Re-read/verify postcondition.
9. Commit transaction and audit.
10. On failure, restore backup and record rollback.

## Untrusted content

Text from files, websites, app data, IPA metadata and GUI trees is represented as untrusted data. It can inform planning but cannot become a system instruction or implicitly elevate tool permissions.

## Background lifecycle

The design assumes iOS suspension/termination. Agent requests persist session state and a checkpoint for each round. Cancellation/interruption leaves an interrupted checkpoint visible on the next launch. Long operations should be decomposed into idempotent steps before phase 2 expands privileged helpers or background processing.
