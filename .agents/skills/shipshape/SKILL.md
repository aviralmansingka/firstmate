---
name: shipshape
description: >-
  Update the captain's live repos (dotfiles, vault) to latest main, re-stow the
  dotfiles symlinks so they point at that latest main, and update firstmate +
  secondmates - all in one guarded pass. Use when the captain invokes /shipshape
  (e.g. "/shipshape", "shipshape", "pull latest on everything", "update everything
  to main"). Fast-forward only and re-stow only - never force, never stash, skip and
  report anything dirty, diverged, off-main, or offline. Composes bin/fm-shipshape.sh
  (live repos + dotfiles symlink restow) with bin/fm-update.sh (firstmate and every
  secondmate, the /updatefirstmate mechanic).
user-invocable: true
metadata:
  internal: true
---

# shipshape

Pull the latest `main` on everything the captain runs, and re-point the dotfiles
symlinks at it, in one pass: the live dotfiles, the live Obsidian vault, a health
check + re-stow of the dotfiles symlinks, and firstmate plus every secondmate.
It is the broadest "get to latest" command - `/updatefirstmate` is the
firstmate-only subset, and `/shipshape` calls it for that leg.

The update is **fast-forward only** and the re-stow is **`stow -R` only** - the
same sanctioned self-write as `fm-fleet-sync.sh` and `fm-update.sh`. It never
forces, never creates a merge commit, never stashes, and advances a target only
on a clean fast-forward. Anything dirty, diverged, off-main, or offline is skipped
and reported, never disrupted. Nothing with unlanded work is ever discarded
(prime directive #3).

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-shipshape.sh
   ```
   It runs three legs and prints a labeled section per leg:
   - **live repos**: fast-forwards each live repo (default `$HOME/dotfiles` and
     `$HOME/vault`; override with `FM_SHIPSHAPE_REPOS="dir1:dir2"` or pass dirs as
     args) to `origin/main`. One status line per repo (`updated <old>..<new>` /
     `already current` / `skipped: <reason>`).
   - **dotfiles symlinks**: only when dotfiles landed on main (`HEAD == origin/main`
     on the `main` branch), reports broken symlinks pointing into the dotfiles
     repo (scanning the known stow-target dirs: `$HOME` top-level, `.config`,
     `.pi`, `.agents`, `.herdr`, `.tmux`, `.claude`, `.gnupg`), then re-stows each
     canonical stow package with `stow -R -t $HOME <pkg>` so every symlink
     re-points at the latest main. Skipped when dotfiles did not reach main, so
     symlinks never track a non-main state.
   - **firstmate + secondmates**: exactly `bin/fm-update.sh` (the `/updatefirstmate`
     mechanic), whose `reread-firstmate: yes|no` and `nudge-secondmates: fm-<id>...|none`
     summary lines flow through unchanged.

2. **Re-read AGENTS.md if firstmate's instructions changed.**
   When the summary printed `reread-firstmate: yes`, the tracked instruction
   surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a real `@AGENTS.md` pointer to it) to
   refresh your operating instructions before doing anything else. When it
   printed `reread-firstmate: no`, skip the re-read.

3. **Nudge each updated live secondmate.**
   For every target on the `nudge-secondmates:` line (do nothing when `none`),
   send a one-line re-read nudge so that secondmate picks up its new instructions:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   This is a gentle steer, not an interruption: the secondmate already got a safe
   tracked-files fast-forward, and the nudge never forces, tears down, or discards.

4. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal
   vocabulary: which repos are now on latest main, whether the dotfiles symlinks
   were healthy and re-stowed (and any broken ones fixed), and which fleet members
   are now on the latest. Surface any skipped target whose reason needs the
   captain's attention - for instance a live repo with un-landed local edits
   (dirty) or a diverged default branch, a stow package that failed to restow, or
   a secondmate that was skipped - all left untouched on purpose.

## Safety

- **Fast-forward only.**
  A repo that has diverged, is dirty, is off-main, is offline, or has no origin
  is skipped and reported, never forced or stashed. Nothing with unlanded work is
  ever discarded - prime directive #3.
- **Re-stow only when dotfiles reached main.**
  The symlink leg runs only when dotfiles is on `main` and `HEAD == origin/main`,
  so symlinks always track the latest main and never a feature branch or dirty
  state. It re-stows only the canonical stow package set (cross-referenced to
  `install.sh`, the single owner) so a non-stow package is never deployed into
  `$HOME` by accident.
- **Live repos only touch their own working tree.**
  `fm-shipshape.sh` fast-forwards `$HOME/dotfiles` and `$HOME/vault` (or the
  override set); it never touches anything under `projects/`, whose disposable
  clones are owned by `fm-fleet-sync.sh`.
- **Secondmates are never disrupted.**
  The firstmate leg is exactly `/updatefirstmate`: a tracked-files fast-forward
  only when a secondmate's own checkout is safe to advance, plus a gentle re-read
  nudge when it changed. It is never torn down, interrupted, or forced.
