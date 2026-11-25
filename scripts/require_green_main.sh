#!/usr/bin/env bash
# Refuses a commit that is not on main or whose CI and Swift runs on main are not both green.
# Needs gh with GH_TOKEN, and GITHUB_REPOSITORY (owner/name).
set -euo pipefail

sha=${1:?usage: require_green_main.sh <sha>}
repo=${GITHUB_REPOSITORY:?}

state=$(gh api "repos/$repo/compare/main...$sha" --jq .status)
if [ "$state" != identical ] && [ "$state" != behind ]; then
  echo "$sha is not on main (compare says: $state)"
  exit 1
fi

for workflow in ci.yml swift.yml; do
  result=$(gh api "repos/$repo/actions/workflows/$workflow/runs?head_sha=$sha&branch=main&event=push&per_page=1" \
    --jq '.workflow_runs[0] | if . == null then "none" else "\(.status) \(.conclusion)" end')
  if [ "$result" != "completed success" ]; then
    echo "$workflow on main for $sha: $result"
    exit 1
  fi
done
echo "$sha is on main and both runs are green"
