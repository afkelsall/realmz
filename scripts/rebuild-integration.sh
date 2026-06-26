#!/bin/sh
# Rebuild a local-only "integration" branch that combines your in-flight
# feature branches on top of a fresh upstream main, then (by default) cross-build
# the Windows package and drop it in the shared folder for testing.
#
# This branch is DISPOSABLE and local-only. Never push it, never open a PR
# from it. It is recreated from scratch each run.
#
# Usage:
#   ./rebuild-integration.sh              # merge branches from integration.txt, then build
#   ./rebuild-integration.sh --no-build   # merge only, skip the Windows build
#
# Branches to merge come from integration.txt (one per line; blank lines and
# lines starting with # are ignored). The build step runs ./build-windows.sh
# --skip-deps, which copies the .exe/.zip into the shared folder and refreshes
# the extracted test folder's Realmz.exe (see that script's SHARE_DIR).
#
# Conflicts: each branch is merged on its own so git rerere can replay a
# previously recorded resolution. If a conflict has no recorded resolution the
# script stops with the merge in progress; resolve it, "git commit", then re-run.
# Your commit teaches rerere, so the next run resolves the same conflict
# automatically.

set -e

UPSTREAM_REMOTE=origin          # Realmz-Castle/realmz in this checkout
BASE_BRANCH=main
INTEG_BRANCH=integration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# This script lives in <repo>/scripts; integration.txt sits beside it. The git
# operations below act on the repo, so run them from the repo root regardless of
# where the script was invoked from.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
BRANCH_LIST="$SCRIPT_DIR/integration.txt"

# --no-build flag: merge only, skip the Windows build.
DO_BUILD=1
for a in "$@"; do
	case "$a" in
		--no-build) DO_BUILD=0 ;;
		*) echo "Unknown argument: $a" >&2; exit 2 ;;
	esac
done

# Read branches from integration.txt: drop comments and blank lines.
if [ ! -f "$BRANCH_LIST" ]; then
	echo "Branch list not found: $BRANCH_LIST" >&2
	echo "Create it with one branch name per line." >&2
	exit 1
fi
BRANCHES=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$BRANCH_LIST" \
	| grep -v '^[[:space:]]*$' | tr '\n' ' ')

if [ -z "$BRANCHES" ]; then
	echo "No branches listed in $BRANCH_LIST." >&2
	exit 1
fi

echo "Refreshing $BASE_BRANCH from $UPSTREAM_REMOTE ..."
git fetch "$UPSTREAM_REMOTE"
git checkout "$BASE_BRANCH"
git merge --ff-only "$UPSTREAM_REMOTE/$BASE_BRANCH"

# Auto-detect fork branches: any entry of the form "<remote>/<branch>" where
# <remote> is a configured git remote (other than the upstream) is a branch
# living on a fork. Fetch each such remote so its tracking ref is current
# before we merge it. Plain local branches (no matching remote prefix) are
# left as-is and merged from your working copy.
REMOTES=$(git remote)
FORK_REMOTES=""
for br in $BRANCHES; do
	case "$br" in
		*/*)
			r=${br%%/*}
			if printf '%s\n' "$REMOTES" | grep -qx "$r" && [ "$r" != "$UPSTREAM_REMOTE" ]; then
				case " $FORK_REMOTES " in
					*" $r "*) ;;                     # already queued
					*) FORK_REMOTES="$FORK_REMOTES $r" ;;
				esac
			fi
			;;
	esac
done
for r in $FORK_REMOTES; do
	echo "Fetching fork remote $r ..."
	git fetch "$r"
done

echo "Recreating $INTEG_BRANCH ..."
git branch -D "$INTEG_BRANCH" 2>/dev/null || true
git checkout -b "$INTEG_BRANCH"

echo "Merging: $BRANCHES"
for br in $BRANCHES; do
	echo "  merging $br ..."
	if git -c rerere.autoupdate=true merge --no-ff -m "integration: merge $br" "$br"; then
		: # clean merge
	elif [ -z "$(git ls-files -u)" ]; then
		# rerere replayed a recorded resolution for every conflict and staged
		# it; finish the merge.
		echo "  (conflicts auto-resolved by rerere)"
		git commit --no-edit
	else
		echo >&2
		echo "Unresolved conflict merging $br." >&2
		echo "Resolve it, run 'git commit', then re-run this script." >&2
		echo "(rerere records your resolution, so the next run auto-applies it.)" >&2
		exit 1
	fi
done

echo
echo "Done. $INTEG_BRANCH now contains: $BRANCHES"
echo "Build/test here. Do not push this branch."

if [ "$DO_BUILD" -eq 1 ]; then
	echo
	echo "Running Windows build (--skip-deps) ..."
	"$SCRIPT_DIR/build-windows.sh" --skip-deps
fi
