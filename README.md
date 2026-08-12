# harden-github-repo

Apply GitHub repository hardening: rulesets, repo security settings,
CODEOWNERS, and Dependabot config, across one or many repos, driven
entirely by config files. No code changes needed to add or adapt rules.

Based in part on the [How to Harden GitHub guide](https://howtoharden.com/guides/github/),
filtered down to what actually works on a **free personal GitHub account**
(no org, no paid plan). See "What's not included" below for what's skipped
and why.

## Structure

- Runner
  - harden-github-repo.sh
- Branch/tag protection (GitHub Rulesets API)
  - gh-rulesets/
- PR required, no force-push, linear history
  - protect-default-branch-ruleset.json
- Tags can't be deleted or overwritten  
  - protect-tags-ruleset.json             
- Simple repo-level API toggles
  - gh-repo-settings/
- GITHUB_TOKEN defaults to read-only
  - workflow-permissions-read-only.json
- Dependabot vulnerability alerts
  - dependabot-alerts.json
- Dependabot automated security PRs                 
  - dependabot-security-updates.json
- Lets researchers report privately        
  - private-vulnerability-reporting.json
- Only allow "selected" Actions  
  - restrict-actions-to-verified.json
- Specifically GitHub + verified creators       
  - allow-github-and-verified-actions.json
- Free on public repos
  - secret-scanning-push-protection.json
- Pushed to .github/CODEOWNERS via a PR
  - CODEOWNERS.template              
- Pushed to .github/dependabot.yml via a PR
  - dependabot.template.yml          


## Requirements

- [GitHub CLI](https://cli.github.com/), authenticated with admin access on
  target repos: `gh auth login`
- [`jq`](https://jqlang.org/)

## Usage

```bash
# One or more repos directly
./harden-github-repo.sh -r yourname/repo-one -r yourname/repo-two

# Or space-separated after a single -r (must come before other flags)
./harden-github-repo.sh -r yourname/repo-one yourname/repo-two

# Or from a file, one "owner/repo" per line (# comments allowed)
./harden-github-repo.sh -f repos.txt

# Point at custom directories/templates
./harden-github-repo.sh -f repos.txt -d ./gh-rulesets-org -s ./gh-repo-settings-org
```

Rulesets and repo settings are safe to rerun, rulesets are matched by
`"name"` and updated in place; repo settings just re-apply the same value.
CODEOWNERS and dependabot.yml are pushed via a **branch + pull request**,
not a direct commit, direct commits get blocked by the branch ruleset once
it's active, so this respects that instead of fighting it. Review and merge
those PRs yourself. Rerunning after merge detects the content already
matches and does nothing.

## Adding your own rules

**Rulesets** (`gh-rulesets/*.json`): standard [GitHub Ruleset API](https://docs.github.com/en/rest/repos/rules)
payloads. You can also export one from the GitHub UI
(`Settings → Rules → Rulesets → <ruleset> → Export`) and drop it in, export-only
fields (`id`, `source`, timestamps) are stripped automatically.

**Repo settings** (`gh-repo-settings/*.json`): simple API calls in the form:

```json
{
  "name": "Human-readable label shown while running",
  "method": "PUT",
  "endpoint": "/repos/{repo}/some/api/path",
  "body": { }
}
```

`{repo}` is substituted with the target `owner/repo`. A failed call (e.g. a
GHAS-only feature on a private repo) is reported and skipped, it doesn't
stop the run, since some settings are expected to fail depending on the
repo's visibility or plan.

### `target` matters for rulesets

A ruleset can only target **one** of `branch`, `tag`, or `push`, you can't
mix them in a single file. `push`-target rulesets (file path/size/extension
restrictions) **require GitHub Team or Enterprise Cloud, and only work on
org-owned repos**, not personal/public repos on Free. That's why file-path
restrictions aren't included by default; see "What's not included" below.

## What's not included (and why)

Free personal accounts (no org, no paid plan) can't use:

- **MFA enforcement, SAML SSO, IP allow lists**, enterprise/org-only settings.
- **Org-wide PAT policies**, configured at the org level, not per-repo.
- **Push rulesets** (file path/size/extension restrictions), Team/Enterprise + org-owned repos only.
- **CodeQL code scanning**, works per-repo on Free for public repos, but is
  language-specific enough that blind automation risks erroring on repos
  where it doesn't apply. Enable manually per repo if relevant:
  `Settings → Code security → Code scanning`.
- **Immutable releases**, an org-level setting in GitHub's docs; not exposed for personal accounts.
- **"Require approval for fork PR workflows"**, free, but has **no REST API**
  for personal-account repos (org-level API only). Enable manually per repo:
  `Settings → Actions → General → Fork pull request workflows`.
- **Signed commits**, enforceable via `required_signatures` in a branch
  ruleset, but requires every contributor (including you) to set up GPG/SSH
  commit signing locally first. Not included by default since it locks out
  unsigned pushes immediately; add it to `gh-rulesets/` once signing is set up.

