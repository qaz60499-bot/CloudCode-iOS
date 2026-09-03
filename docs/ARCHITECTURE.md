# Architecture

## Core

```text
Cloud Code iOS
├── Agent Core
│   ├── SessionStore
│   ├── AgentCore tool loop
│   ├── Provider Catalog (Provider → Key → Model)
│   ├── ProviderClientRouter
│   │   ├── Anthropic Messages
│   │   ├── OpenAI Chat Completions
│   │   └── OpenAI Responses
│   ├── conservative retry / same-Provider Key failover
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

## Provider catalog and credentials

The iOS app uses a build-time metadata snapshot of the enabled desktop CloudRuntime Provider registry. SeekAI is intentionally excluded. Tabitoken is a native iOS Provider and talks directly to `https://tabitoken.com/v1/messages`; the Windows localhost relay is never copied into the mobile runtime.

Selection is user-owned and scoped as `Provider → Key Slot → Model`. Per-Key model catalogs override Provider-wide models when verified metadata exists. The protocol router selects Anthropic Messages, OpenAI Chat, or OpenAI Responses from Provider/Key/Model metadata rather than from a UI protocol switch. Automatic cross-Provider failover is forbidden. Tabitoken may rotate to the next configured Tabitoken Key only for explicit credential or quota/capacity evidence, never for 429, generic 5xx, ambiguous network failures, or after stream output has begun.

Provider metadata and selected IDs may be persisted. Raw credentials may not. API Keys are stored in iOS Keychain under a Provider/Key-Slot reference. The public GitHub artifact is `PUBLIC_UNSIGNED_IPA` and contains no bootstrap credentials. A private local bootstrap can be generated with `scripts/generate_private_bootstrap.py`; the bootstrap is Git-ignored, imported once into Keychain, verified by fingerprint, and the plaintext source is then deleted. If deletion fails, the app reports that condition instead of claiming a safe import.

Custom Providers are added with Label, HTTPS Base URL and API Key. The app discovers `/v1/models`, detects the working auth mode and performs one-token probes for Anthropic Messages, OpenAI Chat, and OpenAI Responses before making the Provider selectable.

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

The design assumes iOS suspension/termination. Agent requests persist session state and a checkpoint for each round. Active runs use a 90-minute Cloud Code background-continuation window, but this is not a promise that iOS will grant 90 minutes of uninterrupted execution: if iOS revokes background time earlier, the run is cancelled at a safe boundary and the checkpoint is preserved for automatic resume. Provider sessions wait for connectivity and use bounded retries for transient connection/timeout failures before model or tool output begins. `NSURLErrorCannotParseResponse` (-1017) is additionally eligible for a clean reconnect after HTTP headers when no model text or tool-call material has been emitted yet. Once any model text or tool-call material has started, a later transport loss is normalized to an interruption and the full request is never blindly replayed; recovery proceeds from the persisted Agent checkpoint. Explicit HTTP failures such as retryable 429/5xx remain eligible for bounded retry before output. Long operations should be decomposed into idempotent steps before privileged helpers or background processing expand further.
