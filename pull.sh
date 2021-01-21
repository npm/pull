#!/usr/bin/env bash

# Land a pull request
# Creates a PR-### branch, pulls the commits, opens up an interactive rebase to
# squash, and then annotates the commit with the changelog goobers
#
# Usage:
#   pr <url|number> [<upstream remote>=origin]

get_user_login () {
  node -e '
data = []
process.stdin.on("end", () =>
  console.log(JSON.parse(Buffer.concat(data).toString()).user.login))
process.stdin.on("data", c => data.push(c))
'
}

get_head_repo_ssh_url () {
  node -e '
data = []
process.stdin.on("end", () =>
  console.log(JSON.parse(Buffer.concat(data).toString()).head.repo.ssh_url))
process.stdin.on("data", c => data.push(c))
'
}

get_head_ref () {
  node -e '
data = []
process.stdin.on("end", () =>
  console.log(JSON.parse(Buffer.concat(data).toString()).head.ref))
process.stdin.on("data", c => data.push(c))
'
}

get_reviewers () {
  local me=$1
  node -e '
data = []
process.stdin.on("end", () => {
  const reviews = JSON.parse(Buffer.concat(data).toString())
  const approvers = [...new Set(reviews
    .filter(a => a.state === "APPROVED")
    .map(a => a.user.login)
  )]
  console.log(approvers.join(", @").trim() || process.argv[1])
})
process.stdin.on("data", c => data.push(c))
' "$me"
}

main () {
  if [ "$1" = "finish" ]; then
    shift
    finish "$@"
    return $?
  fi

  if [ "$1" = "update" ]; then
    shift
    update
    return $?
  fi

  local url="$(prurl "$@")"
  local num=$(basename $url)

  if ! [[ $num =~ ^[0-9]+$ ]]; then
    echo "usage:" >&2
    echo "from target branch:" >&2
    echo "  $0 <url|number> [<upstream remote>=origin]" >&2
    echo "from PR branch:" >&2
    echo "  $0 finish <target branch>" >&2
    echo "from main branch:" >&2
    echo "  $0 update" >&2
    exit 1
  fi

  local prpath="${url#git@github.com:}"
  local repo=${prpath%/pull/$num}
  local prweb="https://github.com/$prpath"
  local root="$(prroot "$url")"
  local api="https://api.github.com/repos/${repo}/pulls/${num}"
  local user=$(curl -s $api | get_user_login)
  local ref="$(prref "$url" "$root")"
  local curhead="$(git show --no-patch --pretty=%H HEAD)"
  local curbranch="$(git rev-parse --abbrev-ref HEAD)"
  local cleanlines
  IFS=$'\n' cleanlines=($(git status -s -uno))
  if [ ${#cleanlines[@]} -ne 0 ]; then
    echo "working dir not clean" >&2
    IFS=$'\n' echo "${cleanlines[@]}" >&2
    echo "aborting PR merge" >&2
  fi

  # ok, ready to rock
  branch=PR-$num
  if [ "$curbranch" == "$branch" ]; then
    echo "already on $branch, you're on your own" >&2
    return 1
  fi

  me=$(git config github.user)
  if [ "$me" == "" ]; then
    echo "run 'git config --add github.user <username>'" >&2
    return 1
  fi

  exists=$(git show --no-patch --pretty=%H $branch 2>/dev/null)
  if [ "$exists" == "" ]; then
    git fetch origin pull/$num/head:$branch
    git checkout $branch
  else
    git checkout $branch
    git pull --rebase origin pull/$num/head
  fi

  git rebase -i --autosquash $curbranch # squash and test

  if [ $? -eq 0 ]; then
    finish "${curbranch}"
  else
    echo "resolve conflicts and run: $0 finish "'"'${curbranch}'"' >&2
  fi
}

# add the PR-URL to the last commit, after squashing
finish () {
  if [ $# -eq 0 ]; then
    echo "Usage: $0 finish <branch> (while on a PR-### branch)" >&2
    return 1
  fi

  local curbranch="$1"
  local githead=$(git rev-parse --git-path HEAD)
  local ref=$(cat $githead)
  local prnum
  case $ref in
    "ref: refs/heads/PR-"*)
      prnum=${ref#ref: refs/heads/PR-}
      ;;
    *)
      echo "not on the PR-## branch any more!" >&2
      return 1
      ;;
  esac

  local me=$(git config github.user || git config user.name)
  if [ "$me" == "" ]; then
    echo "run 'git config --add github.user <username>'" >&2
    return 1
  fi

  set -x

  local url="$(prurl "$prnum")"
  local num=$prnum
  local prpath="${url#git@github.com:}"
  local repo=${prpath%/pull/$num}
  local prweb="https://github.com/$prpath"
  local root="$(prroot "$url")"

  local api="https://api.github.com/repos/${repo}/pulls/${num}"
  local user=$(curl -s $api | get_user_login)

  local reviewsApi="https://api.github.com/repos/${repo}/pulls/${num}/reviews"
  local reviewers=$(curl -s $reviewsApi | get_reviewers "$me")

  local lastmsg="$(git log -1 --pretty=%B)"
  local newmsg="${lastmsg}

PR-URL: ${prweb}
Credit: @${user}
Close: #${num}
Reviewed-by: @${reviewers}
"
  git commit --amend -m "$newmsg"
  git checkout $curbranch
  git merge PR-${prnum} --ff-only

  set +x
}

update () {
  set -x
  local url=$(git show --no-patch HEAD | grep PR-URL | tail -n1 | awk '{print $2}')
  local num=$(basename "$url")

  if [ "$num" == "" ]; then
    echo "could not find PR number" >&2
    return 1
  fi

  local prpath="${url#https://github.com/}"
  local repo=${prpath%/pull/$num}
  local api_endpoint="https://api.github.com/repos/${repo}/pulls/${num}"

  # force-push commit to the user's fork to give it the purple merge
  # it's an optional thing so we ignore any errors
  set +x
  local api=$(curl -s $api_endpoint)
  local remote=$(echo $api | get_head_repo_ssh_url 2> /dev/null)
  local branch=$(echo $api | get_head_ref 2> /dev/null)
  set -x

  if [ "$remote" == "" ] || \
     [ "$branch" == "" ]; then
    echo "original remote/branch not found, PR will be marked as closed" >&2
    return 0
  fi

  local curbranch="$(git branch --show-current)"

  # do an initial push just to make sure it exists, otherwise
  # the retargetting will fail.
  if should_push "$curbranch" "$defaultbranch"; then
    git push origin HEAD^:"$curbranch"
  fi

  # retarget the original contributors PR to point to that branch
  if hash gh 2>/dev/null; then
    local gh_api_endpoint="repos/${repo}/pulls/${num}"
    gh api $gh_api_endpoint --field base="$curbranch" 1> /dev/null
  else
    echo "we need the gh cli in order to retarget PR" >&2
    echo "get it now: https://github.com/cli/cli" >&2
    echo "You may want to manually retarget this PR in the web interface." >&2
  fi
  local defaultbranch=$(git config --get init.defaultbranch)

  # pushes amended commit back to contributors PR branch
  git push "$remote" "+HEAD:$branch"

  # look up and see if we're in the potential default branch
  if ! should_push "$curbranch" "$defaultbranch"; then
    echo "looks like we're in the default branch, skipping auto push" >&2
  else
    # finishes updating our release/working remote branch
    local us="$1"
    if [ "$us" == "" ]; then
      us="origin"
    fi
    git push $us $curbranch
  fi

  set +x
}

should_push () {
  local curbranch=$1
  local defaultbranch=$2
  [ "$curbranch" != "" ] && \
    [ "$curbranch" != "$defaultbranch" ] && \
    [ "$curbranch" != "master" ] && \
    [ "$curbranch" != "main" ] && \
    [ "$curbranch" != "latest" ]
}

prurl () {
  local url="$1"
  if [ "$url" == "" ] && type pbpaste &>/dev/null; then
    url="$(pbpaste)"
  fi
  if [[ "$url" =~ ^[0-9]+$ ]]; then
    local us="$2"
    if [ "$us" == "" ]; then
      us="origin"
    fi
    local num="$url"
    local o="$(git config --get remote.${us}.url)"
    url="${o}"
    url="${url#(git:\/\/|https:\/\/)}"
    url="${url#git@}"
    url="${url#github.com[:\/]}"
    url="${url%.git}"
    url="https://github.com/${url}/pull/$num"
  fi
  url=${url%/commits}
  url=${url%/files}
  url="$(echo $url | perl -p -e 's/#issuecomment-[0-9]+$//g')"

  local p='^https:\/\/github.com\/[^\/]+\/[^\/]+\/pull\/[0-9]+$'
  if ! [[ "$url" =~ $p ]]; then
    echo "Usage:" >&2
    echo "  $0 <pull req url>" >&2
    echo "  $0 <pull req number> [<remote name>=origin]" >&2
    type pbpaste &>/dev/null &&
      echo "(will read url/id from clipboard if not specified)" >&2
    exit 1
  fi
  url="${url/https:\/\/github\.com\//git@github.com:}"
  echo "$url"
}

prroot () {
  local url="$1"
  echo "${url/\/pull\/+([0-9])/}"
}

prref () {
  local url="$1"
  local root="$2"
  echo "refs${url:${#root}}/head"
}

main "$@"
