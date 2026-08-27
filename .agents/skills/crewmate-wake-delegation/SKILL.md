---
name: crewmate-wake-delegation
description: >-
  Route crewmate-originated wakes to a spawned sub-agent so the captain-facing main conversation stays free for captain input. Load at every actionable wake whose source is a crewmate or scout direct report (signal:, stale:, or check: naming a crewmate task), before handling it inline. The sub-agent resolves the wake (steers the crewmate, reconciles state, makes any in-authority decision) and escalates ONLY a genuinely captain-relevant outcome back to the main conversation.
user-invocable: false
metadata:
  internal: true
---

# crewmate-wake-delegation

This skill is the single owner of the crewmate-wake-to-sub-agent routing procedure.
It exists so the captain's main firstmate pane stays free for captain input: crewmate messages coming up to firstmate are handled by a disposable sub-agent (option-A sibling pane, Phase 4 primitive), not in the main conversation.

## When to load

Load at the start of every wake-handling turn, after the wake queue is drained, when one or more queued wakes originate from a crewmate or scout direct report (a `signal:`, `stale:`, or `check:` wake whose key names a task recorded in this home with `kind=ship` or `kind=scout`).
Do not load for fleet-wide heartbeats, Relay mentions, startup-network checks, watcher-failure alarms, or any wake the captain is already reading directly.
Do not load when the fleet is empty (no crewmate is live) or when away mode is active (the away daemon owns wake handling).

## Procedure

1. Classify each drained wake by source:
   - **Crewmate-originated** (the wake names a live ship/scout task): delegate to a sub-agent.
   - **Fleet-wide or infrastructure** (heartbeat, watcher-failure, startup-network, Relay): handle inline per the emitted supervision protocol; these are not crewmate work.
   - **Captain-originated** (an inbox note, a captain-held decision): handle inline; the captain is already in the loop.

2. For each crewmate-originated wake, spawn a sub-agent to resolve it:
   - `bin/fm-spawn.sh <new-id> --sub-agent <this-session-task-id> --harness pi --scout` (a scout sub-agent; it is disposable and self-terminates via `fm_complete` from Phase 3).
   - Brief the sub-agent with the wake's reason line, the crewmate task's id, and the authority boundary: it may steer the crewmate, reconcile current state, and decide anything within firstmate's own authority, but it must NOT merge PRs, perform destructive actions, or answer ask-user findings - those escalate back.
   - The sub-agent inherits the crewmate doorbell extension (Phase 2 steer lanes) and clean self-exit (Phase 3) by composition; it is born fully capable.

3. While a sub-agent is resolving a crewmate wake, the main conversation does not block on it:
   - Continue draining any remaining wakes.
   - If the captain sends a message, respond immediately; the sub-agent works independently in its sibling pane.
   - The sub-agent reports its outcome through its status file (a `done:` or `failed:` line) and self-terminates; the watcher surfaces the terminal outcome as a routine branch outcome, not a main-conversation turn, unless it is captain-relevant.

4. Escalate back to the main conversation ONLY when the sub-agent's resolution is genuinely captain-relevant:
   - A PR ready for the captain's review (with the full PR URL).
   - A real blocker or failure the sub-agent could not resolve.
   - A gate finding that `ask-user-authority` escalates.
   - Anything destructive, irreversible, or security-sensitive.
   Routine progress, state reconciliation, and ordinary crewmate steering do NOT escalate.

## Authority boundary

A wake-delegation sub-agent operates within firstmate's own authority:
- It may steer crewmates (via `fm-send.sh`), reconcile state (via `fm-crew-state.sh`), update the backlog, and append status.
- It may NOT merge PRs, discard unlanded work, perform destructive or irreversible actions, or answer ask-user findings; those still require the main conversation and, where applicable, the captain's explicit word.
- It may NOT spawn its own sub-agents (no recursive delegation in v1); if it needs to, it escalates back.

## What this does not change

- The live supervision cycle, the wake-queue drain order, and the `--ack-through` acknowledgement are unchanged; the sub-agent is spawned AFTER the drain, and the acknowledgement still runs after all wakes are handled.
- The captain's main conversation still receives every fleet-wide wake, every watcher-failure alarm, and every captain-originated message directly.
- Away mode still owns wake handling when active; this skill does not load then.

## Composition note

This skill composes the Phase 4 sub-agent spawn primitive (`--sub-agent`, option-A sibling pane), the Phase 2 crewmate doorbell extension (the sub-agent can steer crewmates in-process), and the Phase 3 scout self-termination gate (the sub-agent appends `done:` then calls `fm_complete`). A wake-delegation sub-agent is born with all three capabilities by construction.
