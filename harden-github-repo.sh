#!/usr/bin/env bash
#
# harden-github-repo.sh
#
# Applies every ruleset JSON file found in a rulesets directory (default:
# ./gh-rulesets) to one or more GitHub repos, via the GitHub CLI.
#
# Ruleset files are plain GitHub Ruleset API payloads (the same shape you'd
# POST to /repos/{owner}/{repo}/rulesets). To add your own, just drop a new
# .json file into the rulesets directory, no script changes needed.
#
# Matching by "name" is idempotent: if a ruleset with the same "name" already
# exists on a repo, it's updated (PUT) instead of duplicated (POST).
#
# Requirements:
#   - gh CLI, authenticated with admin access on target repos (gh auth login)
#   - jq
#
# Usage:
#   ./harden-github-repo.sh -r owner/repo [-r owner/repo ...]
#   ./harden-github-repo.sh -r owner/repo1 owner/repo2 owner/repo3
#   ./harden-github-repo.sh -f repos.txt
#   ./harden-github-repo.sh -f repos.txt -d /path/to/custom-rulesets
#   ./harden-github-repo.sh -f repos.txt -c /path/to/CODEOWNERS.template
#   ./harden-github-repo.sh -f repos.txt -s /path/to/custom-repo-settings
#
# Note: you can list several repos space-separated after -r instead of
# repeating the flag, but ALL other flags (-d, -c, -s, -b, -f) must come
# BEFORE the repo list, bash stops parsing flags once it hits the first
# bare repo.
#   OK:    -c template.txt -r repo1 repo2 repo3
#   WRONG: -r repo1 repo2 repo3 -c template.txt   (the -c gets swallowed as a repo)
#
# Options:
#   -r  Repo in "owner/repo" form. Repeatable, or space-separated (see above).
#   -f  File with one "owner/repo" per line (# comments and blank lines ok).
#   -d  Directory of ruleset JSON files (default: ./gh-rulesets next to this script).
#   -c  CODEOWNERS template file to push to each repo's .github/CODEOWNERS
#       (default: ./CODEOWNERS.template next to this script). If the file
#       doesn't exist, the CODEOWNERS step is skipped.
#   -s  Directory of repo-settings JSON files, simple repo-level API calls
#       (default: ./gh-repo-settings next to this script). Each file describes
#       one PUT/PATCH/POST call; drop in your own to add more, no script
#       changes needed. Individual settings that fail (e.g. GHAS-only features
#       on a private repo) are reported but don't stop the run.
#   -b  Dependabot config template to push to each repo's .github/dependabot.yml
#       (default: ./dependabot.template.yml next to this script). If the file
#       doesn't exist, this step is skipped.
#   -h  Show help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULESETS_DIR="$SCRIPT_DIR/gh-rulesets"
CODEOWNERS_TEMPLATE="$SCRIPT_DIR/CODEOWNERS.template"
REPO_SETTINGS_DIR="$SCRIPT_DIR/gh-repo-settings"
DEPENDABOT_TEMPLATE="$SCRIPT_DIR/dependabot.template.yml"

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

REPOS=()
REPO_FILE=""

while getopts "r:f:d:c:s:b:h" opt; do
  case "$opt" in
    r) REPOS+=("$OPTARG") ;;
    f) REPO_FILE="$OPTARG" ;;
    d) RULESETS_DIR="$OPTARG" ;;
    c) CODEOWNERS_TEMPLATE="$OPTARG" ;;
    s) REPO_SETTINGS_DIR="$OPTARG" ;;
    b) DEPENDABOT_TEMPLATE="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

# Any remaining bare arguments (e.g. `-r repo1 repo2 repo3`) are also treated
# as repos, so space-separated lists work without repeating -r each time.
for arg in "$@"; do
  REPOS+=("$arg")
done

if [ -n "$REPO_FILE" ]; then
  if [ ! -f "$REPO_FILE" ]; then
    echo "Error: repo file not found: $REPO_FILE" >&2
    exit 1
  fi
  while IFS= read -r line; do
    line="$(echo "$line" | xargs)"  # trim whitespace
    [ -z "$line" ] && continue
    [[ "$line" =~ ^# ]] && continue
    REPOS+=("$line")
  done < "$REPO_FILE"
fi

if [ ${#REPOS[@]} -eq 0 ]; then
  echo "Error: no repos specified. Use -r owner/repo or -f repos.txt" >&2
  usage
fi

# Normalizes a repo entry to "owner/repo":
#   - strips a leading URL (https://github.com/, git@github.com:, github.com/)
#   - strips a trailing .git
#   - strips a trailing slash
normalize_repo() {
  local r="$1"
  r="${r#https://github.com/}"
  r="${r#http://github.com/}"
  r="${r#git@github.com:}"
  r="${r#github.com/}"
  r="${r%.git}"
  r="${r%/}"
  echo "$r"
}

NORMALIZED=()
BAD_REPOS=()
for r in "${REPOS[@]}"; do
  n=$(normalize_repo "$r")
  # must be exactly "owner/repo" - no extra slashes, no empty segments
  if [[ "$n" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    NORMALIZED+=("$n")
  else
    BAD_REPOS+=("$r")
  fi
done

if [ ${#BAD_REPOS[@]} -gt 0 ]; then
  echo "Error: these entries don't look like a valid \"owner/repo\":" >&2
  for b in "${BAD_REPOS[@]}"; do
    echo "  - $b" >&2
  done
  echo "Expected format: owner/repo (e.g. octocat/hello-world)" >&2
  exit 1
fi

REPOS=("${NORMALIZED[@]}")

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI is required but not installed." >&2
  exit 1
fi

if [ ! -d "$RULESETS_DIR" ]; then
  echo "Error: rulesets directory not found: $RULESETS_DIR" >&2
  exit 1
fi

shopt -s nullglob
RULESET_FILES=("$RULESETS_DIR"/*.json)
shopt -u nullglob

if [ ${#RULESET_FILES[@]} -eq 0 ]; then
  echo "Error: no .json ruleset files found in $RULESETS_DIR" >&2
  exit 1
fi

echo "Rulesets to apply (from $RULESETS_DIR):"
for f in "${RULESET_FILES[@]}"; do
  echo "  - $(basename "$f")"
done
echo ""

# Strips fields GitHub adds when you export a ruleset (id, source, timestamps,
# etc.) so exported rulesets can be reused directly as templates.
clean_payload() {
  jq 'del(.id, .node_id, .source_type, .source, .created_at, .updated_at, .["_links"])' "$1"
}

apply_ruleset() {
  local repo="$1" file="$2"
  local name payload existing_id

  name=$(jq -r '.name // empty' "$file")
  if [ -z "$name" ]; then
    echo "   ! Skipping $(basename "$file"): missing top-level \"name\" field"
    return
  fi

  payload=$(clean_payload "$file")

  existing_id=$(gh api "/repos/$repo/rulesets" --jq \
    ".[] | select(.name == \"$name\") | .id" 2>/dev/null | head -n1 || true)

  if [ -n "$existing_id" ]; then
    echo "   -> Updating \"$name\" (id: $existing_id)"
    echo "$payload" | gh api --method PUT \
      -H "Accept: application/vnd.github+json" \
      "/repos/$repo/rulesets/$existing_id" --input - > /dev/null
  else
    echo "   -> Creating \"$name\""
    echo "$payload" | gh api --method POST \
      -H "Accept: application/vnd.github+json" \
      "/repos/$repo/rulesets" --input - > /dev/null
  fi
}

# Pushes CODEOWNERS_TEMPLATE to .github/CODEOWNERS via a branch + pull request
# (not a direct commit), direct commits are blocked by the pull_request rule
# in gh-rulesets once it's applied, so this respects that instead of fighting it.
# Skips entirely if the default branch's CODEOWNERS already matches the template.
apply_codeowners() {
  local repo="$1"
  local default_branch base_sha work_branch="harden-repo-codeowners"
  local existing_content new_encoded existing_sha pr_number owner

  default_branch=$(gh api "/repos/$repo" --jq .default_branch 2>/dev/null || true)
  if [ -z "$default_branch" ]; then
    echo "   ! Could not determine default branch for $repo, skipping CODEOWNERS"
    return 1
  fi

  new_encoded=$(base64 -w 0 < "$CODEOWNERS_TEMPLATE" 2>/dev/null || base64 < "$CODEOWNERS_TEMPLATE")

  existing_content=$(gh api "/repos/$repo/contents/.github/CODEOWNERS?ref=$default_branch" \
    --jq .content 2>/dev/null | tr -d '\n' || true)
  if [ -n "$existing_content" ] && [ "$existing_content" = "$new_encoded" ]; then
    echo "   -> .github/CODEOWNERS already up to date"
    return 0
  fi

  base_sha=$(gh api "/repos/$repo/git/ref/heads/$default_branch" --jq .object.sha 2>/dev/null || true)
  if [ -z "$base_sha" ]; then
    echo "   ! Could not read $default_branch ref for $repo, skipping CODEOWNERS"
    return 1
  fi

  if ! gh api "/repos/$repo/git/ref/heads/$work_branch" >/dev/null 2>&1; then
    gh api --method POST "/repos/$repo/git/refs" \
      -f ref="refs/heads/$work_branch" \
      -f sha="$base_sha" > /dev/null
  fi

  existing_sha=$(gh api "/repos/$repo/contents/.github/CODEOWNERS?ref=$work_branch" \
    --jq .sha 2>/dev/null || true)

  echo "   -> Committing CODEOWNERS to $work_branch"
  if [ -n "$existing_sha" ]; then
    gh api --method PUT "/repos/$repo/contents/.github/CODEOWNERS" \
      -f message="Update CODEOWNERS" -f content="$new_encoded" \
      -f sha="$existing_sha" -f branch="$work_branch" > /dev/null
  else
    gh api --method PUT "/repos/$repo/contents/.github/CODEOWNERS" \
      -f message="Add CODEOWNERS" -f content="$new_encoded" \
      -f branch="$work_branch" > /dev/null
  fi

  owner="${repo%%/*}"
  pr_number=$(gh api "/repos/$repo/pulls?head=$owner:$work_branch&base=$default_branch&state=open" \
    --jq '.[0].number' 2>/dev/null || true)

  if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
    echo "   -> CODEOWNERS PR already open: #$pr_number (review & merge to apply)"
  else
    pr_number=$(gh api --method POST "/repos/$repo/pulls" \
      -f title="chore: add/update CODEOWNERS" \
      -f head="$work_branch" -f base="$default_branch" \
      -f body="Automated by harden-github-repo.sh. Review and merge to apply CODEOWNERS." \
      --jq .number 2>/dev/null || true)
    if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
      echo "   -> Opened CODEOWNERS PR: #$pr_number (review & merge to apply)"
    else
      echo "   ! Could not open CODEOWNERS PR for $repo"
      return 1
    fi
  fi
}

if [ -f "$CODEOWNERS_TEMPLATE" ]; then
  echo "CODEOWNERS template: $CODEOWNERS_TEMPLATE"
  echo ""
else
  echo "No CODEOWNERS template found at $CODEOWNERS_TEMPLATE , skipping CODEOWNERS step."
  echo ""
fi

# Applies simple repo-level API settings from JSON files (free-tier, no
# ruleset/branch-protection involved). Each file describes one call:
#   { "name": "...", "method": "PUT|PATCH|POST", "endpoint": "/repos/{repo}/...", "body": {...} }
# "{repo}" in the endpoint is substituted with the target repo. Failures are
# reported but non-fatal, some settings only apply to public repos, or
# require GHAS on private repos, and that's expected, not a bug.
apply_repo_setting() {
  local repo="$1" file="$2"
  local name method endpoint body

  name=$(jq -r '.name // empty' "$file")
  method=$(jq -r '.method // "PATCH"' "$file")
  endpoint=$(jq -r '.endpoint // empty' "$file" | sed "s|{repo}|$repo|g")
  body=$(jq -c '.body // {}' "$file")

  if [ -z "$name" ] || [ -z "$endpoint" ]; then
    echo "   ! Skipping $(basename "$file"): missing \"name\" or \"endpoint\""
    return 1
  fi

  echo "   -> $name"
  if echo "$body" | gh api --method "$method" \
    -H "Accept: application/vnd.github+json" \
    "$endpoint" --input - > /dev/null 2>&1; then
    return 0
  else
    echo "      (not applied, may require a paid plan, GHAS, or doesn't apply to this repo)"
    return 1
  fi
}

if [ -d "$REPO_SETTINGS_DIR" ]; then
  shopt -s nullglob
  REPO_SETTING_FILES=("$REPO_SETTINGS_DIR"/*.json)
  shopt -u nullglob
  if [ ${#REPO_SETTING_FILES[@]} -gt 0 ]; then
    echo "Repo settings to apply (from $REPO_SETTINGS_DIR):"
    for f in "${REPO_SETTING_FILES[@]}"; do
      echo "  - $(basename "$f")"
    done
    echo ""
  fi
else
  REPO_SETTING_FILES=()
  echo "No repo-settings directory found at $REPO_SETTINGS_DIR , skipping that step."
  echo ""
fi

# Pushes DEPENDABOT_TEMPLATE to .github/dependabot.yml via a branch + pull
# request, same pattern as apply_codeowners (direct commits are blocked once
# the pull_request rule is active). Skips if content already matches.
apply_dependabot_config() {
  local repo="$1"
  local default_branch base_sha work_branch="harden-repo-dependabot"
  local existing_content new_encoded existing_sha pr_number owner

  default_branch=$(gh api "/repos/$repo" --jq .default_branch 2>/dev/null || true)
  if [ -z "$default_branch" ]; then
    echo "   ! Could not determine default branch for $repo, skipping dependabot.yml"
    return 1
  fi

  new_encoded=$(base64 -w 0 < "$DEPENDABOT_TEMPLATE" 2>/dev/null || base64 < "$DEPENDABOT_TEMPLATE")

  existing_content=$(gh api "/repos/$repo/contents/.github/dependabot.yml?ref=$default_branch" \
    --jq .content 2>/dev/null | tr -d '\n' || true)
  if [ -n "$existing_content" ] && [ "$existing_content" = "$new_encoded" ]; then
    echo "   -> .github/dependabot.yml already up to date"
    return 0
  fi

  base_sha=$(gh api "/repos/$repo/git/ref/heads/$default_branch" --jq .object.sha 2>/dev/null || true)
  if [ -z "$base_sha" ]; then
    echo "   ! Could not read $default_branch ref for $repo, skipping dependabot.yml"
    return 1
  fi

  if ! gh api "/repos/$repo/git/ref/heads/$work_branch" >/dev/null 2>&1; then
    gh api --method POST "/repos/$repo/git/refs" \
      -f ref="refs/heads/$work_branch" \
      -f sha="$base_sha" > /dev/null
  fi

  existing_sha=$(gh api "/repos/$repo/contents/.github/dependabot.yml?ref=$work_branch" \
    --jq .sha 2>/dev/null || true)

  echo "   -> Committing dependabot.yml to $work_branch"
  if [ -n "$existing_sha" ]; then
    gh api --method PUT "/repos/$repo/contents/.github/dependabot.yml" \
      -f message="Update dependabot.yml" -f content="$new_encoded" \
      -f sha="$existing_sha" -f branch="$work_branch" > /dev/null
  else
    gh api --method PUT "/repos/$repo/contents/.github/dependabot.yml" \
      -f message="Add dependabot.yml" -f content="$new_encoded" \
      -f branch="$work_branch" > /dev/null
  fi

  owner="${repo%%/*}"
  pr_number=$(gh api "/repos/$repo/pulls?head=$owner:$work_branch&base=$default_branch&state=open" \
    --jq '.[0].number' 2>/dev/null || true)

  if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
    echo "   -> dependabot.yml PR already open: #$pr_number (review & merge to apply)"
  else
    pr_number=$(gh api --method POST "/repos/$repo/pulls" \
      -f title="chore: add/update dependabot.yml" \
      -f head="$work_branch" -f base="$default_branch" \
      -f body="Automated by harden-github-repo.sh. Keeps GitHub Actions and dependencies patched. Review and merge to apply." \
      --jq .number 2>/dev/null || true)
    if [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
      echo "   -> Opened dependabot.yml PR: #$pr_number (review & merge to apply)"
    else
      echo "   ! Could not open dependabot.yml PR for $repo"
      return 1
    fi
  fi
}

if [ -f "$DEPENDABOT_TEMPLATE" ]; then
  echo "Dependabot template: $DEPENDABOT_TEMPLATE"
  echo ""
else
  echo "No dependabot template found at $DEPENDABOT_TEMPLATE , skipping that step."
  echo ""
fi

FAILED=()

for REPO in "${REPOS[@]}"; do
  echo "=== $REPO ==="
  for FILE in "${RULESET_FILES[@]}"; do
    if ! apply_ruleset "$REPO" "$FILE"; then
      echo "   ! Failed applying $(basename "$FILE") to $REPO"
      FAILED+=("$REPO:$(basename "$FILE")")
    fi
  done
  for FILE in "${REPO_SETTING_FILES[@]}"; do
    if ! apply_repo_setting "$REPO" "$FILE"; then
      FAILED+=("$REPO:$(basename "$FILE") (see note above)")
    fi
  done
  if [ -f "$CODEOWNERS_TEMPLATE" ]; then
    if ! apply_codeowners "$REPO"; then
      echo "   ! Failed applying CODEOWNERS to $REPO"
      FAILED+=("$REPO:CODEOWNERS")
    fi
  fi
  if [ -f "$DEPENDABOT_TEMPLATE" ]; then
    if ! apply_dependabot_config "$REPO"; then
      echo "   ! Failed applying dependabot.yml to $REPO"
      FAILED+=("$REPO:dependabot.yml")
    fi
  fi
  echo ""
done

echo "Applied ${#RULESET_FILES[@]} ruleset(s) across ${#REPOS[@]} repo(s)."

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "Failures:"
  for f in "${FAILED[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
