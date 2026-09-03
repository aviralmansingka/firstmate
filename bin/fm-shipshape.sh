#!/usr/bin/env bash
# Shipshape: fast-forward the captain's live repos to latest main, re-stow
# dotfiles symlinks to point at that latest main, then update firstmate +
# secondmates. Mechanical half of the /shipshape skill.
#
# Leg 1 - live repos: guarded fast-forward of the captain's live working repos
# (dotfiles, vault by default) to origin/main. FAST-FORWARD ONLY: never force,
# never create a merge commit, never stash; a repo that is dirty, diverged,
# off-main, or offline is skipped and reported, never disrupted. Nothing with
# unlanded work is ever discarded (prime directive #3).
#
# Leg 2 - dotfiles symlinks: only when dotfiles landed on main (HEAD == origin/main
# on the main branch), report broken symlinks pointing into the dotfiles repo, then
# re-stow each canonical stow package with `stow -R` so every symlink re-points at
# the latest main. The canonical package list is cross-referenced to install.sh
# (the single owner); restowing a non-stow package would wrongly deploy it into
# $HOME, so only packages on that list are restowed. Skipped when dotfiles did not
# reach main (dirty/diverged/off-main/fetch-failed) so symlinks never track a
# non-main state.
#
# Leg 3 - firstmate + secondmates: exactly bin/fm-update.sh (the /updatefirstmate
# mechanic), whose reread-firstmate / nudge-secondmates summary lines flow through.
#
# Repo targets default to $HOME/dotfiles and $HOME/vault; override with
# FM_SHIPSHAPE_REPOS="dir1:dir2" or pass dirs as positional args.
# Usage: fm-shipshape.sh [repo-dir...]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"

# Canonical stow package set. install.sh (in the dotfiles repo) is the single
# owner of this set; keep this line in sync with install.sh's `stow` commands.
STOW_PACKAGES="zsh tmux nvim starship ghostty aerospace agents pi herdr git"
if [ "$(uname -s)" = "Darwin" ]; then
  STOW_PACKAGES="$STOW_PACKAGES launchd"
fi
if command -v systemctl >/dev/null 2>&1; then
  STOW_PACKAGES="$STOW_PACKAGES systemd"
fi

if [ $# -gt 0 ]; then
  targets=("$@")
elif [ -n "${FM_SHIPSHAPE_REPOS:-}" ]; then
  IFS=':' read -r -a targets <<<"$FM_SHIPSHAPE_REPOS"
else
  targets=("$HOME/dotfiles" "$HOME/vault")
fi

ff_repo() {
  local dir="$1" branch before after
  if [ ! -d "$dir" ]; then
    printf 'skipped: %s (not found)\n' "$dir"
    return 0
  fi
  if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
    printf 'skipped: %s (not a git repo)\n' "$dir"
    return 0
  fi
  branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ "$branch" != "main" ]; then
    printf 'skipped: %s (not on main, on %s)\n' "$dir" "${branch:-detached HEAD}"
    return 0
  fi
  if ! git -C "$dir" fetch origin main >/dev/null 2>&1; then
    printf 'skipped: %s (fetch failed)\n' "$dir"
    return 0
  fi
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null | head -1)" ]; then
    printf 'skipped: %s (dirty working tree)\n' "$dir"
    return 0
  fi
  before=$(git -C "$dir" rev-parse --short HEAD)
  if git -C "$dir" merge --ff-only origin/main >/dev/null 2>&1; then
    after=$(git -C "$dir" rev-parse --short HEAD)
    if [ "$before" = "$after" ]; then
      printf 'already current: %s (%s)\n' "$dir" "$after"
    else
      printf 'updated: %s %s..%s\n' "$dir" "$before" "$after"
    fi
  else
    printf 'skipped: %s (diverged - not a clean fast-forward)\n' "$dir"
  fi
}

# Heavy $HOME subtrees to skip: stow only places symlinks in a few known config dirs,
# so the health scan targets those explicitly instead of walking all of $HOME.
STOW_TARGET_DIRS=("$HOME/.config" "$HOME/.pi" "$HOME/.agents" "$HOME/.herdr" "$HOME/.tmux" "$HOME/.claude" "$HOME/.gnupg")

restow_dotfiles() {
  local dir="$1" pkg broken=0 sample="" t link
  command -v stow >/dev/null 2>&1 || {
    printf 'symlinks: stow not installed - skipped restow\n'
    return 0
  }
  # Health check: broken symlinks in known stow-target dirs whose target points into dotfiles.
  for tdir in "$HOME" "${STOW_TARGET_DIRS[@]}"; do
    [ -d "$tdir" ] || continue
    local depth=1
    [ "$tdir" = "$HOME" ] || depth=4
    while IFS= read -r link; do
      t=$(readlink "$link" 2>/dev/null || true)
      case "$t" in
        *dotfiles/*) broken=$((broken + 1)); [ -z "$sample" ] && sample="$link" ;;
      esac
    done < <(find "$tdir" -maxdepth "$depth" -type l ! -exec test -e {} \; -print 2>/dev/null)
  done
  if [ "$broken" -gt 0 ]; then
    printf 'symlinks: %d broken into dotfiles (e.g. %s) - restowing to fix\n' "$broken" "$sample"
  else
    printf 'symlinks: no broken dotfiles symlinks detected\n'
  fi
  printf 'symlinks: re-stowing canonical packages to latest main\n'
  pushd "$dir" >/dev/null
  for pkg in $STOW_PACKAGES; do
    [ -d "$pkg" ] || continue
    if stow -R -t "$HOME" "$pkg" >/tmp/fm-shipshape-stow.out 2>&1; then
      printf '  restowed: %s\n' "$pkg"
    else
      printf '  FAILED: %s - %s\n' "$pkg" "$(tr '\n' ' ' </tmp/fm-shipshape-stow.out)"
    fi
  done
  popd >/dev/null
}

printf '== shipshape: live repos ==\n'
for d in "${targets[@]}"; do
  ff_repo "$d"
done

# Leg 2: re-stow dotfiles symlinks only when dotfiles reached main.
dotfiles_dir=""
for d in "${targets[@]}"; do
  if [ -d "$d" ] && [ "$(basename "$d")" = "dotfiles" ]; then
    dotfiles_dir="$d"
  fi
done
printf '\n== shipshape: dotfiles symlinks ==\n'
if [ -n "$dotfiles_dir" ] && { [ -d "$dotfiles_dir/.git" ] || [ -f "$dotfiles_dir/.git" ]; }; then
  branch=$(git -C "$dotfiles_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  head=$(git -C "$dotfiles_dir" rev-parse HEAD 2>/dev/null || true)
  origin=$(git -C "$dotfiles_dir" rev-parse origin/main 2>/dev/null || true)
  if [ "$branch" = "main" ] && [ -n "$head" ] && [ "$head" = "$origin" ]; then
    restow_dotfiles "$dotfiles_dir"
  else
    printf 'symlinks: skipped (dotfiles not on main at origin/main - symlinks left as-is)\n'
  fi
else
  printf 'symlinks: skipped (no dotfiles repo in targets)\n'
fi

printf '\n== shipshape: firstmate + secondmates ==\n'
bash "$FM_ROOT/bin/fm-update.sh"
