#!/bin/sh
set -eu

die() { echo "pr-context: $*" >&2; exit 1; }

mode=published
[ "${1:-}" = --local ] && { mode=local; shift; }
[ $# -le 1 ] || die "usage: pr-context.sh [--local] [pr|branch]"
arg=${1:-}
tab=$(printf '\t')

branch=$(git symbolic-ref --short -q HEAD) || die "detached HEAD"
[ -z "$(git status --porcelain)" ] || die "working tree not clean"
sha=$(git rev-parse HEAD)
tree=$(git rev-parse 'HEAD^{tree}')
repo=$(gh repo view --json url,nameWithOwner,defaultBranchRef \
  --jq '[.url, .nameWithOwner, .defaultBranchRef.name] | @tsv') || die "cannot resolve the GitHub repository"
IFS=$tab read -r repo_url nwo default <<EOF
$repo
EOF

explicit=
case $arg in
  '') ;;
  *://*) explicit=1 ;;
  *[!0-9]*) [ "$arg" = "$branch" ] || die "branch '$arg' is not the checked-out branch '$branch'"; arg= ;;
  *) explicit=1 ;;
esac

json=url,number,state,headRefName,headRefOid,baseRefName
fields='[.url, .number, .state, .headRefName, .headRefOid, .baseRefName] | @tsv'
if [ -n "$explicit" ]; then
  pr=$(gh pr view "$arg" --json "$json" --jq "$fields") || die "cannot read PR $arg"
else
  pr=$(gh pr list --head "$branch" --state open --limit 1 --json "$json" --jq ".[0] // empty | $fields") \
    || die "cannot list PRs for branch $branch"
fi
number='' base=''
if [ -n "$pr" ]; then
  IFS=$tab read -r pr_url number state head head_oid base <<EOF
$pr
EOF
  [ "$state" = OPEN ] || die "PR #$number is $state, not open"
  [ "${pr_url%/pull/*}" = "$repo_url" ] || die "PR $pr_url is not in $repo_url"
  [ "$head" = "$branch" ] || die "PR head branch '$head' is not the checked-out branch '$branch'"
  [ "$mode" = local ] || [ "$head_oid" = "$sha" ] || die "PR head $head_oid is not local HEAD $sha (push or pull first)"
elif [ "$mode" = published ]; then
  die "no open PR found for branch $branch"
fi

[ "$mode" = published ] || [ "$branch" != "$default" ] || die "on the default branch '$default'"
base=${base:-$default}
case $base$branch in *[!A-Za-z0-9._/-]*) die "unsafe characters in branch '$branch' or base '$base'" ;; esac

printf 'owner=%s\nrepo=%s\nnumber=%s\nbase=%s\nbranch=%s\ntarget_sha=%s\ntarget_tree=%s\n' \
  "${nwo%%/*}" "${nwo#*/}" "$number" "$base" "$branch" "$sha" "$tree"
