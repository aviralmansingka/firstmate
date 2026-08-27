# subagent-integration-validation-guide

**Session date:** 2026-08-27
**Scope:** Per-PR validation walkthroughs for the 6-stacked-PR interactive sub-agent integration.
**Audience:** Captain review (morning merge), and any secondmate/crewmate shepherding the stack.
Each section is self-contained: the PR goal, the acceptance criteria from the captain-approved plan, the verification commands, and the expected observable output. Run the commands from a firstmate checkout that has the stacked branch checked out (or, after merge, from `main`).

## PR 1 — Phase 1: polling surface (`fm/phase1-fleet-poll`, base `main`)

### Goal
A read-only precedence-ranked fleet poll over DECLARED signals, surfaced in `/bearings` as a "Fleet Pulse" section. No `--peek` (that is Phase 5).

### Acceptance criteria
- `fm-fleet-poll.sh --json` emits valid `fm-fleet-poll.v1` with a `ranked[]` array where each item carries `{tier, id, kind, key, summary, age_s, source}` and the ordering matches the ladder (tiers 1-5; tier 6 absent in Phase 1).
- `fm-fleet-poll.sh` (human mode) prints the `digest` + the ranked rows.
- `/bearings` renders a "Fleet Pulse" section.
- Read-only: no `state/*.status` mtime change after a poll run.
- No `--peek` flag in the Phase 1 code path (behavioral: `--peek` rejected as unknown, exit 2 with usage).

### Verification
```sh
# 1. JSON schema + ranking against the live fleet
fm-fleet-poll.sh --json | jq '.schema, [.ranked[].tier]'
# Expect: "fm-fleet-poll.v1" and tiers ascending 1..5 (only populated tiers appear)

# 2. Human digest
fm-fleet-poll.sh
# Expect: "Fleet Pulse: N captain-held · M needs-decision ..." then one row per ranked item

# 3. Read-only proof (run against the live fleet)
before=$(find "$FM_HOME/state" -name '*.status' -exec stat -c '%Y %n' {} + 2>/dev/null | sort | sha256sum)
fm-fleet-poll.sh --json >/dev/null
after=$(find "$FM_HOME/state" -name '*.status' -exec stat -c '%Y %n' {} + 2>/dev/null | sort | sha256sum)
[ "$before" = "$after" ] && echo "READ-ONLY OK" || echo "MUTATED"

# 4. --peek rejected in Phase 1 (behavioral)
fm-fleet-poll.sh --peek --json; echo "rc=$?"
# Expect: rc=2, usage printed to stderr

# 5. Bearings integration
fm-bearings-snapshot.sh --json | jq '{fleet_pulse_digest, count: (.fleet_pulse|length), first: .fleet_pulse[0]}'
# Expect: a non-empty fleet_pulse with the same ranked rows
```

### Colocated test
```sh
bash tests/fm-fleet-poll.test.sh
# Expect: all tests passed (13 cases)
```

---

## PR 2 — Phase 2: fm-send --deliver + crewmate doorbell (`fm/phase2-send-deliver`, base PR 1)

### Goal
An in-process steer/followUp delivery lane for pi-harness crewmates. `steer` lands at the next turn boundary; `followUp` (default) lands on full stop.

### Acceptance criteria
- `fm-send.sh <id> --deliver steer <text>` writes the durable record with `deliver=steer` FIRST, then the doorbell extension injects at the next turn boundary (not the typed ring).
- `--deliver followUp` (default) delivers on full stop — identical to today.
- Non-pi harness OR extension absent → today's typed-ring + re-ring ladder, bit-for-bit.
- `--deliver steer` on a non-pi harness degrades to followUp-equivalent.
- The ack contract (move to `handled/`) is unchanged.
- Typed-plane carve-outs and `--resolve-key` semantics untouched.

### Verification
```sh
# 1. --deliver steer records the header
fm-send.sh <scout> --deliver steer "change X" ; echo "rc=$?"
# Expect: rc=0; then:
grep '^deliver=' "$FM_HOME/state/<scout>.inbox/001.msg"   # Expect: deliver=steer

# 2. Default is followUp
fm-send.sh <scout> "change Y"
grep '^deliver=' "$FM_HOME/state/<scout>.inbox/002.msg"   # Expect: deliver=followUp

# 3. Invalid mode rejected
fm-send.sh <scout> --deliver bogus "Z"; echo "rc=$?"
# Expect: rc!=0, stderr names "steer or followUp"

# 4. Liveness check: with a fresh doorbell heartbeat, fm_task_inbox_ring skips the typed ring
# (unit-level, see the colocated test)
```

### Colocated tests
```sh
bash tests/fm-send-inbox.test.sh          # delivers + carve-outs + ack
bash tests/fm-task-inbox.test.sh          # deliver= header, heartbeat-fresh skip, re-ring ladder
```

### Live harness proof (optional, needs a pi crewmate)
With a pi scout mid-turn, `fm-send.sh <scout> --deliver steer "..."` → the steer lands at the next turn boundary (the scout's next turn reflects it); the durable record carries `deliver=steer`.

---

## PR 3 — Phase 3: scout self-termination + 🏁/🛑 (`fm/phase3-scout-termination`, base PR 2)

### Goal
Pi-harness scouts self-terminate: append `done:`/`failed:` durable first, then call `fm_complete`, which exits the process at `agent_settled`. The observer reads a clean self-exit as 🏁 (routine), not 🛑.

### Acceptance criteria
- A pi scout appends `done:` then calls `fm_complete` → process exits; observer emits 🏁 (verdict:routine), not the stale/wedge ladder.
- A scout killed externally (no terminal status) → the unchanged ladder emits 🛑.
- `fm_complete` refuses if the status tail lacks `done:`/`failed:` (store-first gate).
- Non-pi scouts and secondmates are unaffected (still use fm-control's external exit).
- Scout meta carries `self_terminate=expected`; ship and secondmate meta omit it.

### Verification
```sh
# 1. Store-first gate (the fm_complete tool refuses without a terminal status)
#    Read the doorbell extension's fm_complete execute body: it checks the status tail.
grep -n 'terminalVerbOf\|done:\|failed:' .pi/extensions/fm-crewmate-doorbell.ts

# 2. Scout meta carries self_terminate=expected; ship meta omits it
bash tests/fm-spawn-dispatch-profile.test.sh
# Expect: "scout meta carries self_terminate=expected" and "ship meta omits self_terminate" pass

# 3. Scout brief tells a pi scout to call fm_complete
grep -n 'fm_complete\|store-first gate' bin/fm-brief.sh
```

### Live harness proof (needs a pi scout)
Run a pi scout to completion → it appends `done:` and exits itself → observe 🏁 in the branch outcome store (`fm_branch_outcomes`). SIGKILL a scout mid-work (no terminal status) → observe 🛑 through the unchanged ladder.

---

## PR 4 — Phase 4: sub-agent spawn path (`fm/phase4-subagent-spawn`, base PR 3) — HIGHEST RISK

### Goal
Spawn a sub-agent as a named, pane-visible pi session beside its parent (option A: sibling pane split in the parent's tab). Composes PR 2+3: sub-agents inherit steer lanes + clean self-exit.

### Acceptance criteria
- A sub-agent spawned via `--sub-agent <parent>` is a named herdr agent (`herdr agent list` → `fm-<id>` kind=pi) in a sibling pane; `--no-focus` honored.
- `state/<id>.meta` carries `parent_task`, `parent_pane`, and the herdr id triple.
- `fm-fleet-snapshot --json` shows the child task row with its `parent_task`.
- `fm-crew-state <sub-id>` resolves via herdr `agent_status`, not `unknown codex-unverified`.
- Teardown closes ONLY the recorded sub-pane; the parent's tab survives.
- Crewmate option-B topology (existing fm-spawn tab path) unchanged.

### Verification
```sh
# 1. Backend primitives (unit-level)
bash tests/fm-subagent-spawn.test.sh
# Expect: pane_split parses + fails closed, agent_start forwards + fails closed,
#         pane_close best-effort, snapshot surfaces parent_task + agent_status

# 2. --sub-agent is herdr-only
fm-spawn.sh <id> --sub-agent <parent> --backend tmux ... ; echo "rc=$?"
# Expect: rc!=0, "only supported on the herdr backend"

# 3. Snapshot passthrough (fixture)
fm-fleet-snapshot.sh --json | jq '.tasks[] | {id, parent_task, agent_status, children}'
# Expect: parent_task null for regular tasks, set for sub-agents; agent_status non-null
```

### Live harness proof (needs herdr + a parent pi crewmate)
Spawn a test sub-agent → `herdr agent list` shows `fm-<id>` kind=pi in a sibling pane; confirm focus unchanged. `cat state/<id>.meta` → `parent_task`/`parent_pane` present. Teardown: close only the sub-pane; confirm parent tab intact. **Test the teardown-order matrix (parent-first vs child-first) + restart-husk behavior explicitly** — first time firstmate creates panes inside tabs it doesn't wholly own.

---

## PR 5 — Phase 5: --peek musings + tier-2 children + branch read tool (`fm/phase5-peek-musings`, base PR 4)

### Goal
Opt-in `--peek` musing read (Call 2: never default, never in heartbeats), tier-2 headless children rows, the branch `fm_fleet_poll` read tool, escalate only on tiers-1-2 delta.

### Acceptance criteria
- `fm-fleet-poll.sh --peek --json` emits tier-6 `undeclared` rows ONLY when `--peek` armed; without `--peek`, zero tier-6 rows (privacy proof).
- `--peek` never invoked by the heartbeat/branch path (grep proof: no `--peek` literal in `fm-watch.sh` or `fm-branch-supervision.ts`).
- A headless child appends to `state/<parent>.children.jsonl`; snapshot shows it under `tasks[].children[]`.
- The branch `fm_fleet_poll` read tool returns the ranked list; escalation fires only on a tiers-1-2 delta.

### Verification
```sh
# 1. Privacy proof
fm-fleet-poll.sh --json | jq '{peek_armed, tier6: [.ranked[]|select(.tier==6)]|length}'
# Expect: peek_armed=false, tier6=0
fm-fleet-poll.sh --peek --json | jq '{peek_armed, peek_reads, tier6: [.ranked[]|select(.tier==6)]|length}'
# Expect: peek_armed=true, tier6=0 (no running sub-agents) or >0 (with running sub-agents)

# 2. Heartbeat path excludes --peek (grep proof)
grep -rn -- '--peek' bin/fm-watch.sh .pi/extensions/fm-branch-supervision.ts
# Expect: no matches

# 3. Children sidecar surfaced by the snapshot
bash tests/fm-peek-musings.test.sh
# Expect: snapshot surfaces children[] from the sidecar; empty-children fallback; --peek absent from heartbeat

# 4. Branch read tool registered
grep -n 'fm_fleet_poll' .pi/extensions/fm-branch-supervision.ts
```

---

## PR 6 — Phase 6: crewmate wake delegation (`fm/phase6-wake-delegation`, base PR 5)

### Goal
Route crewmate-originated wakes to a spawned sub-agent so the captain-facing main pane stays free for captain input. Escalate ONLY captain-relevant outcomes back.

### Acceptance criteria
- At every actionable wake whose source is a crewmate/scout direct report, firstmate spawns a sub-agent (option-A, Phase 4 primitive) to resolve it, instead of handling it inline.
- The sub-agent steers the crewmate (Phase 2), reconciles state, decides within firstmate's own authority, and self-terminates (Phase 3).
- Escalation back to the main conversation fires ONLY for: PR ready, real blocker, ask-user finding, destructive/irreversible/security-sensitive.
- Fleet-wide, infrastructure, and captain-originated wakes remain inline.
- Away mode unchanged; no recursive delegation in v1.

### Verification
This is an instruction-level change (no new bin/ scripts). Verification is behavioral against the skill + the AGENTS.md trigger:
```sh
# 1. The skill exists and is internal
test -f .agents/skills/crewmate-wake-delegation/SKILL.md && grep -q 'internal: true' .agents/skills/crewmate-wake-delegation/SKILL.md && echo "skill OK"

# 2. AGENTS.md section 8 carries the trigger
grep -q 'crewmate-wake-delegation' AGENTS.md && echo "trigger pointer OK"

# 3. AGENTS.md section 13 registers the skill
grep -A1 '## 13' AGENTS.md | grep -q 'crewmate-wake-delegation' && echo "registered OK"
```

### Live proof (post-merge, needs a running firstmate session with a live crewmate)
Have a crewmate append a `needs-decision` status line. Observe firstmate spawn a sub-agent to resolve it (sibling pane) rather than handling it in the captain's pane. The captain's pane stays free; only the sub-agent's outcome (routine or escalated) surfaces.

---

## Morning merge order

Merge bottom-up: PR 1 → 2 → 3 → 4 → 5 → 6. After each merge, the next PR retargets its base to `main` (or re-reviews if the stack rebased). The stale "PR must be raised via no-mistakes" compliance check on PR #9 is cosmetic (the fresh check passes); it clears on re-push after merge.
