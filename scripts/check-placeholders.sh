#!/usr/bin/env bash
# Fails when an unfilled placeholder (REPLACE-... or SEAL-ME-...) is in apps/ or
# manifests/. main auto-syncs to production, so run this before every merge or
# push to main; scripts/seal-rmm-keys.sh and the RMM cut-over runbook replace them.
#
# Usage: scripts/check-placeholders.sh        (exit 0 = clean, 1 = placeholders found)
# Optional pre-push hook: ln -s ../../scripts/check-placeholders.sh .git/hooks/pre-push
set -euo pipefail
cd "$(dirname "$0")/.."
for d in apps manifests; do
  [ -d "$d" ] && [ -r "$d" ] || { echo "check-placeholders: $d/ is missing or unreadable; nothing was checked" >&2; exit 2; }
done
# grep: 0 = matches, 1 = none, 2 = error (unreadable file, bad pattern). Only 1 is clean.
status=0
hits="$(grep -rnE 'REPLACE-|SEAL-ME-' apps manifests --include='*.yaml' --include='*.yml' --include='*.json')" || status=$?
case "$status" in
  0)
    echo "Unfilled placeholders (must not reach main):" >&2
    echo "$hits" >&2
    exit 1 ;;
  1)
    echo "no placeholders" ;;
  *)
    echo "check-placeholders: the search failed (grep exit $status); the files were not checked" >&2
    exit 2 ;;
esac
