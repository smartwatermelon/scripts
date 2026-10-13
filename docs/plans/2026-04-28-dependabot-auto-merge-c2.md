# Dependabot Auto-Merge C2 Rollout

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Clear 29 stuck Dependabot PRs across 16 smartwatermelon repos and harden the auto-merge workflow to handle trusted-author major bumps.

**Architecture:**

- Phase 1 enables the GitHub repo setting that allows the workflow's `gh pr review --approve` to succeed (the bot-self-merge restriction).
- Phase 2 re-triggers the 13 patch PRs that previously failed at the approve step; they auto-merge.
- Phase 3 updates the workflow YAML (in dev-env first) to allow major bumps from a trusted-author allowlist (`dependabot/*`, `actions/*`, `smartwatermelon/*`), then validates end-to-end on dev-env's open `fetch-metadata` PR.
- Phase 4 propagates the validated workflow to the other 15 consumer repos via Dependabot-style chore PRs (one per repo) and clears the remaining 16 major-bump PRs.

**Tech Stack:** gh CLI, GitHub Actions YAML, Dependabot fetch-metadata action, GitHub repo Actions permissions API.

**Background context:**

- The auto-merge workflow lives as a per-repo copy at `.github/workflows/dependabot-auto-merge.yml` (provisioned by the v2.0.1 Phase 5 rollout). All 16 owned repos already have it.
- Failure mode confirmed in `smartwatermelon/dev-env` PR #15 run 24925280943: `failed to create review: GraphQL: GitHub Actions is not permitted to approve pull requests`.
- Repo permission state: 13 repos have `can_approve_pull_request_reviews: false`; 3 (projectinsomnia, ralph-burndown, scripts) already have `true` — and those 3 only have a major-bump PR open, confirming the patch path works once the setting is flipped.
- Per Andrew's CLAUDE.md: every `gh pr merge` requires prior `merge-lock auth <PR#> "ok"`.

**Repos in scope (16):**

| Repo | can_approve | Open Dependabot PRs |
|---|---|---|
| archive-resolver | false | #11 (patch), #12 (major) |
| claude-config | false | #141 (patch), #142 (major) |
| claude-wrapper | false | #44 (major), #45 (patch) |
| crazy-larry | false | #5 (major), #6 (patch) |
| dev-env | false | #15 (patch), #16 (major) |
| dotfiles | false | #78 (major), #79 (patch) |
| homebrew-tap | false | #5 (patch), #6 (major) |
| lock-sync | false | #15 (patch), #16 (major) |
| mac-dev-server-setup | false | #46 (major), #47 (patch) |
| projectinsomnia | true | #62 (major) |
| ralph-burndown | true | #111 (major) |
| scripts | true | #69 (major) |
| slack-mcp | false | #15 (patch), #16 (major) |
| smartwatermelon-marketplace | false | #13 (major), #14 (patch) |
| spokane-snow | false | #4 (major), #5 (patch) |
| swift-progress-indicator | false | #7 (patch), #8 (major) |

"patch" = `claude-blocking-review.yml 2.0.1 → 2.0.2`. "major" = `dependabot/fetch-metadata 2 → 3`.

---

## Phase 1: Flip `can_approve_pull_request_reviews` on 13 repos

### Task 1.1: Verify token has `repo` admin scope

**Step 1:** Confirm the active gh token can write actions permissions.

```bash
gh api -X PATCH repos/smartwatermelon/dev-env/actions/permissions/workflow \
  -F default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true \
  --silent && echo OK
```

Expected: `OK`. If 403, stop and ask Andrew which token to use.

**Step 2:** Verify the change.

```bash
gh api repos/smartwatermelon/dev-env/actions/permissions/workflow | jq .
```

Expected: `"can_approve_pull_request_reviews": true`.

### Task 1.2: Apply to remaining 12 repos

**Step 1:** Loop over the rest.

```bash
for r in archive-resolver claude-config claude-wrapper crazy-larry dotfiles \
         homebrew-tap lock-sync mac-dev-server-setup slack-mcp \
         smartwatermelon-marketplace spokane-snow swift-progress-indicator; do
  gh api -X PATCH "repos/smartwatermelon/$r/actions/permissions/workflow" \
    -F default_workflow_permissions=read \
    -F can_approve_pull_request_reviews=true \
    --silent && echo "$r OK" || echo "$r FAIL"
done
```

Expected: 12 lines of `<repo> OK`.

**Step 2:** Verify all 16 repos now read `true`.

```bash
for r in archive-resolver claude-config claude-wrapper crazy-larry dev-env \
         dotfiles homebrew-tap lock-sync mac-dev-server-setup projectinsomnia \
         ralph-burndown scripts slack-mcp smartwatermelon-marketplace \
         spokane-snow swift-progress-indicator; do
  v=$(gh api "repos/smartwatermelon/$r/actions/permissions/workflow" \
        | jq -r .can_approve_pull_request_reviews)
  echo "$r=$v"
done
```

Expected: all `=true`. **Checkpoint — report to Andrew.**

---

## Phase 2: Re-trigger 13 stuck patch PRs

### Task 2.1: Comment `@dependabot recreate` on each PR

**Original logic (rejected):** `gh pr close` + `gh pr reopen` fires `pull_request_target` reopened, but the actor on that event is the user invoking the CLI, not `dependabot[bot]`. Workflow's `if: github.actor == 'dependabot[bot]'` then skips the job.

**Correct approach:** Comment `@dependabot recreate` on each PR. Dependabot then closes the old PR and creates a replacement; the new PR's events have `github.actor == 'dependabot[bot]'` and the workflow runs.

**Caveat encountered (2026-04-28):** `@dependabot recreate` updates the PR target to the latest available version, not just refreshing the existing target. In our case, between the original PRs and the recreate, `smartwatermelon/github-workflows` had published `v3.0.0` (a breaking-change tag for `claude-blocking-review.yml`). The recreated PRs targeted `2.0.1 → 3.0.0`.

**Bigger gotcha:** Dependabot's `fetch-metadata@v2` mislabeled this `2.0.1 → 3.0.0` reusable-workflow bump as `version-update:semver-patch` (verified in run logs). So the existing patch-only `if:` admitted it, and 11 repos auto-merged the major bump before this was caught. User accepted the v3 rollout. Phase 3 must defend against this mislabel by computing the major delta itself.

**Step 1:** Define the list.

```
archive-resolver:11
claude-config:141
claude-wrapper:45
crazy-larry:6
dev-env:15
dotfiles:79
homebrew-tap:5
lock-sync:15
mac-dev-server-setup:47
slack-mcp:15
smartwatermelon-marketplace:14
spokane-snow:5
swift-progress-indicator:7
```

**Step 2:** Comment `@dependabot recreate` on each.

```bash
while IFS=: read -r repo num; do
  gh pr comment "$num" --repo "smartwatermelon/$repo" --body "@dependabot recreate"
done <<'EOF'
archive-resolver:11
claude-config:141
claude-wrapper:45
crazy-larry:6
dev-env:15
dotfiles:79
homebrew-tap:5
lock-sync:15
mac-dev-server-usage:47
slack-mcp:15
smartwatermelon-marketplace:14
spokane-snow:5
swift-progress-indicator:7
EOF
```

### Task 2.2: Wait and verify auto-merge

**Step 1:** Wait ~3 minutes for CI + auto-merge to fire.

**Step 2:** Re-query PR state.

```bash
while IFS=: read -r repo num; do
  state=$(gh pr view "$num" --repo "smartwatermelon/$repo" --json state -q .state 2>/dev/null)
  echo "$repo#$num=$state"
done <<'EOF'
archive-resolver:11
claude-config:141
claude-wrapper:45
crazy-larry:6
dev-env:15
dotfiles:79
homebrew-tap:5
lock-sync:15
mac-dev-server-setup:47
slack-mcp:15
smartwatermelon-marketplace:14
spokane-snow:5
swift-progress-indicator:7
EOF
```

Expected: all `=MERGED`.

**If any are still OPEN:** check the auto-merge workflow run; the cause is no longer the approve restriction. Investigate per-repo. **Checkpoint — report to Andrew.**

---

## Phase 3: Update auto-merge workflow (dev-env first, validate end-to-end)

### Task 3.1: Edit `dev-env/.github/workflows/dependabot-auto-merge.yml`

**Files:**

- Modify: `/Users/andrewrich/Developer/dev-env/.github/workflows/dependabot-auto-merge.yml:38-45`

**Step 1:** Replace the conditional and the comment block above it. New content:

```yaml
      # Auto-merge policy (defense-in-depth — do NOT trust update-type alone):
      #  1. Compute the actual major-version delta from previous-version /
      #     new-version strings. Dependabot's fetch-metadata@v2 has been
      #     observed to mislabel reusable-workflow major bumps as
      #     "version-update:semver-patch" (2026-04-28: 2.0.1 -> 3.0.0 of
      #     smartwatermelon/github-workflows reported as patch). Trust math,
      #     not the label.
      #  2. If our computed delta is "patch_or_minor": always merge.
      #  3. If our computed delta is "major": only merge when EVERY entry in
      #     dependency-names belongs to a trusted namespace (dependabot/,
      #     actions/, smartwatermelon/). One untrusted dep in a grouped
      #     update blocks the whole group.
      #  4. If we cannot parse the versions (non-numeric), default to "skip".
      - name: Decide if PR is auto-mergeable
        id: policy
        env:
          PREV_VERSION: ${{ steps.metadata.outputs.previous-version }}
          NEW_VERSION: ${{ steps.metadata.outputs.new-version }}
          DEP_NAMES: ${{ steps.metadata.outputs.dependency-names }}
        run: |
          set -euo pipefail
          # Extract leading integer from each version string (handles "2", "2.0", "2.0.1", "v2.0.1").
          extract_major() {
            printf '%s' "$1" | sed -E 's@^v?([0-9]+).*@\1@' | grep -E '^[0-9]+$' || echo ""
          }
          prev_major=$(extract_major "$PREV_VERSION")
          new_major=$(extract_major "$NEW_VERSION")
          if [ -z "$prev_major" ] || [ -z "$new_major" ]; then
            echo "decision=skip" >> "$GITHUB_OUTPUT"
            echo "::notice::Cannot parse versions ($PREV_VERSION -> $NEW_VERSION); leaving for manual review"
            exit 0
          fi
          if [ "$prev_major" = "$new_major" ]; then
            echo "decision=merge" >> "$GITHUB_OUTPUT"
            echo "::notice::Patch/minor bump within major v$prev_major; auto-merging"
            exit 0
          fi
          # Major bump — require every dep to be trusted.
          remainder=$(printf '%s' "$DEP_NAMES" \
            | tr ',' '\n' \
            | sed -E 's@^[[:space:]]+|[[:space:]]+$@@g' \
            | grep -v '^$' \
            | grep -vE '^(dependabot|actions|smartwatermelon)/' \
            || true)
          if [ -z "$remainder" ]; then
            echo "decision=merge" >> "$GITHUB_OUTPUT"
            echo "::notice::Major bump v$prev_major -> v$new_major in trusted namespace; auto-merging"
          else
            echo "decision=skip" >> "$GITHUB_OUTPUT"
            echo "::notice::Major bump v$prev_major -> v$new_major; non-allowlisted deps present: $remainder"
          fi

      - name: Approve and enable auto-merge
        if: steps.policy.outputs.decision == 'merge'
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh pr review --approve "$PR_URL"
          gh pr merge --auto --squash --delete-branch "$PR_URL"
```

**Step 2:** Run a YAML lint to catch typos.

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('/Users/andrewrich/Developer/dev-env/.github/workflows/dependabot-auto-merge.yml'))" && echo OK
```

Expected: `OK`.

### Task 3.2: Local pre-commit verification

**Step 1:** Run any pre-commit hooks (markdownlint won't trigger; YAML may).

```bash
git -C /Users/andrewrich/Developer/dev-env add .github/workflows/dependabot-auto-merge.yml
git -C /Users/andrewrich/Developer/dev-env diff --cached
```

**Step 2:** Commit on the existing feature branch.

```bash
git -C /Users/andrewrich/Developer/dev-env commit -m "$(cat <<'EOF'
ci(deps): allow trusted-author major bumps in auto-merge

Adds a policy step that admits major-version Dependabot PRs only when
every listed dependency belongs to dependabot/, actions/, or
smartwatermelon/ namespaces. Patch and minor remain always-allowed.

Why: dependabot/fetch-metadata 2->3 (and similar own-namespace bumps)
sit in the backlog because the original workflow excludes all majors.
Constraining the allowlist to vendors we trust keeps third-party majors
manual.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3.3: Open PR, observe end-to-end on dev-env

**Step 1:** Push.

```bash
git -C /Users/andrewrich/Developer/dev-env push -u origin claude/dependabot-auto-merge-c2-rollout
```

**Step 2:** Open PR.

```bash
cd /Users/andrewrich/Developer/dev-env && gh pr create \
  --title "ci(deps): allow trusted-author major bumps in auto-merge" \
  --body "$(cat <<'EOF'
## Summary
- Adds explicit policy step before approve/merge.
- Patch + minor: unchanged (always allowed).
- Major: only auto-merged when every listed dependency starts with `dependabot/`, `actions/`, or `smartwatermelon/`.

## Plan reference
docs/plans/2026-04-28-dependabot-auto-merge-c2.md

## Test plan
- [ ] Workflow YAML parses (yaml.safe_load)
- [ ] On merge to main, re-trigger this repo's #16 (`fetch-metadata 2->3`); verify it auto-merges
- [ ] After validation, propagate to the other 15 repos (Phase 4)
EOF
)"
```

**Step 3:** Wait for CI + Andrew's merge-lock auth, then merge.

```bash
# After: merge-lock auth <PR#> "ok"
gh pr merge <PR#> --squash --delete-branch
```

### Task 3.4: Validate on dev-env PR #16 (the open major bump)

**Step 1:** Close+reopen `smartwatermelon/dev-env#16` to fire the new workflow.

```bash
gh pr close 16 --repo smartwatermelon/dev-env
sleep 2
gh pr reopen 16 --repo smartwatermelon/dev-env
```

**Step 2:** Wait ~3 minutes, check state.

```bash
gh pr view 16 --repo smartwatermelon/dev-env --json state,mergedAt
```

Expected: `state=MERGED`. **Checkpoint — report to Andrew. Do not proceed to Phase 4 if this fails.**

---

## Phase 4: Propagate workflow to the other 15 repos

**Strategy:** One PR per repo with the same workflow change. Each PR's auto-merge is itself blocked (it's a workflow-permissions PR, not a Dependabot PR), so it requires a merge-lock auth + manual `gh pr merge`.

### Task 4.1: Generate the 15 PRs in parallel

**Step 1:** Build a helper that, for one repo, creates a branch from main, drops in the new workflow file, and opens a PR.

```bash
cat > /tmp/propagate-automerge.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repo=$1
branch="claude/auto-merge-trusted-majors"
tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

cd "$tmpdir"
gh repo clone "smartwatermelon/$repo" -- --depth=1
cd "$repo"
git checkout -b "$branch"
mkdir -p .github/workflows
cp /Users/andrewrich/Developer/dev-env/.github/workflows/dependabot-auto-merge.yml \
   .github/workflows/dependabot-auto-merge.yml
git add .github/workflows/dependabot-auto-merge.yml
git diff --cached --quiet && { echo "$repo: no diff, skipping"; exit 0; }
git commit -m "ci(deps): allow trusted-author major bumps in auto-merge

Mirrors smartwatermelon/dev-env's auto-merge workflow update so this
repo's Dependabot major bumps from dependabot/, actions/, and
smartwatermelon/ namespaces are eligible for auto-merge.
"
git push -u origin "$branch"
gh pr create --title "ci(deps): allow trusted-author major bumps in auto-merge" \
  --body "Mirrors smartwatermelon/dev-env update (see docs/plans/2026-04-28-dependabot-auto-merge-c2.md). Phase 4 of the C2 rollout."
EOF
chmod +x /tmp/propagate-automerge.sh
```

**Step 2:** Run for each repo (skipping any whose workflow already matches).

```bash
for r in archive-resolver claude-config claude-wrapper crazy-larry dotfiles \
         homebrew-tap lock-sync mac-dev-server-setup projectinsomnia \
         ralph-burndown scripts slack-mcp smartwatermelon-marketplace \
         spokane-snow swift-progress-indicator; do
  echo "=== $r ==="
  /tmp/propagate-automerge.sh "$r" || echo "$r FAILED"
done
```

### Task 4.2: Collect the 15 PR URLs and request merge-lock auth

**Step 1:** List freshly opened PRs.

```bash
gh search prs --author=@me --state=open --owner=smartwatermelon \
  --label="" --limit=30 \
  --json repository,number,url 2>&1 \
  | jq -r '.[] | "\(.repository.nameWithOwner)#\(.number) \(.url)"' \
  | grep -i 'auto-merge'
```

**Step 2:** Provide Andrew the auth list:

```
merge-lock auth <claude-config-PR> "ok"
merge-lock auth <claude-wrapper-PR> "ok"
... (15 lines)
```

**Checkpoint — wait for Andrew to authorize.**

### Task 4.3: Merge each authorized PR

```bash
for pr in <list from previous step>; do
  gh pr merge "$pr" --squash --delete-branch || echo "FAIL $pr"
done
```

### Task 4.4: Re-trigger the 15 stuck major-bump PRs

**Step 1:** For each repo, close+reopen the open `fetch-metadata 2->3` PR.

```
archive-resolver:12
claude-config:142
claude-wrapper:44
crazy-larry:5
dotfiles:78
homebrew-tap:6
lock-sync:16
mac-dev-server-setup:46
projectinsomnia:62
ralph-burndown:111
scripts:69
slack-mcp:16
smartwatermelon-marketplace:13
spokane-snow:4
swift-progress-indicator:8
```

```bash
while IFS=: read -r repo num; do
  echo "--- $repo#$num ---"
  gh pr close "$num" --repo "smartwatermelon/$repo" || true
  sleep 2
  gh pr reopen "$num" --repo "smartwatermelon/$repo" || true
done <<'EOF'
archive-resolver:12
claude-config:142
claude-wrapper:44
crazy-larry:5
dotfiles:78
homebrew-tap:6
lock-sync:16
mac-dev-server-setup:46
projectinsomnia:62
ralph-burndown:111
scripts:69
slack-mcp:16
smartwatermelon-marketplace:13
spokane-snow:4
swift-progress-indicator:8
EOF
```

**Step 2:** Wait ~3 minutes, then verify all are `MERGED`.

```bash
while IFS=: read -r repo num; do
  state=$(gh pr view "$num" --repo "smartwatermelon/$repo" --json state -q .state)
  echo "$repo#$num=$state"
done <<'EOF'
archive-resolver:12
claude-config:142
claude-wrapper:44
crazy-larry:5
dotfiles:78
homebrew-tap:6
lock-sync:16
mac-dev-server-setup:46
projectinsomnia:62
ralph-burndown:111
scripts:69
slack-mcp:16
smartwatermelon-marketplace:13
spokane-snow:4
swift-progress-indicator:8
EOF
```

Expected: all `=MERGED`. **Final checkpoint.**

---

## Post-rollout

- Final verification: `gh search prs --author=app/dependabot --state=open --owner=smartwatermelon` returns empty.
- Document the trusted-major allowlist in the v2.0.1 rollout playbook (smartwatermelon/github-workflows/docs/plans/2026-04-18-v2-rollout-playbook.md).
- Future improvement (out of scope here): convert the per-repo workflow copies into a single reusable workflow in `smartwatermelon/github-workflows`. Tracked separately.
