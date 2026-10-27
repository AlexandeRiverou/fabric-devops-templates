# Repository Instructions

## Pull Request Ownership

The GitHub Project Orchestrator is the sole agent responsible for coordinating and
creating or updating Pull Requests for repository tasks. After integrating and
validating requested work, it must automatically create or update a PR without
waiting for the user to request or confirm it. This is standing authorization,
subject to repository policy and actual permissions.

Delegated and specialist agents are responsible for their assigned implementation,
review, or documentation work. They must return their changes, validation results,
and any blockers to the orchestrator; they are not required to create or update a PR.
Do not treat a specialist task as incomplete merely because it did not create a PR.
Specialist agents must not independently create or update a PR unless the user
explicitly instructs that agent to do so. For work coordinated by the orchestrator,
the orchestrator retains PR ownership.

The orchestrator owns the PR handoff, including preparing a review-ready description
from the repository template and reporting the PR URL. If a concrete blocker,
repository policy, or permission prevents PR creation, the orchestrator explains
the blocker and reports the branch and next required step; it must not wait for
confirmation as a substitute for attempting PR creation.

---

## Repository Workflow Authorization

The orchestrator coordinates normal Git workflow operations required to complete a
task. Branch, commit, and push operations must follow the user's authorization and
applicable repository policy. Creating or updating a PR after completed work is
standing authorization for the orchestrator. Delegated agents focus on their
assigned work and report completion to the orchestrator.

The following actions are pre-approved and do not require additional confirmation:

- Creating task-specific branches
- Switching branches
- Staging changes
- Creating commits
- Creating multiple commits when appropriate
- Pushing commits to task-specific branches
- Updating task-specific branches
- Creating or updating Pull Requests (orchestrator only, automatically after work is ready)

Branch creation, commits, and pushes apply only to task-specific non-protected
branches. Pull Requests may target a protected base branch for review, subject to
that branch's repository protections and restrictions.

---

## Risk Classification

The following are routine Git operations, subject to applicable repository policy.
Orchestrator PR creation and updates are automatic after work is ready. Specialists
may create or update a PR only when the user explicitly instructs them:

- `git checkout -b <branch>`
- `git switch -c <branch>`
- `git add`
- `git commit`
- `git push`
- `git push --set-upstream origin <branch>`
- `gh pr create` (orchestrator only)
- `gh pr edit` (orchestrator only)

Do not treat the orchestrator's automatic PR creation as requiring a separate user
confirmation. The explicit-user-instruction requirement applies only to specialists
creating or updating a PR. Do not classify these authorized operations as inherently:

- Unrequested repository changes
- Risky repository modifications
- Potentially destructive actions

Branch, commit, and push actions remain subject to the applicable user and
repository authorization. Orchestrator PR actions follow the standing authorization
above; specialist PR actions require explicit user instruction.

Agents should not mischaracterize an authorized, routine operation as inherently
dangerous, but must still honor authorization requirements. Do not generate warnings
such as:

- "Branch creation is an unrequested repository change."
- "Commit and push lack specific authorization."
- "Pushing publishes changes to origin and requires approval."

The orchestrator owns coordinating branch, commit, push, and PR steps. Delegated
agents do not need to perform these steps to complete their assigned tasks.

---

## Agent Assumptions

Unless explicitly instructed otherwise, assume that:

- Creating branches is authorized.
- Switching branches is authorized.
- Committing changes is authorized.
- Pushing task-specific branches is authorized.
- Creating or updating Pull Requests is the orchestrator's responsibility and must
  happen automatically after the work is ready.

Do not require delegated agents to create a PR or report a PR URL as a condition of
completing their assigned task.

---

# Git and Pull Requests

## Protected Branches

- Never make changes directly on `main`, `master`, `trunk`, or any protected branch.
- Never commit to a protected branch.
- Never push to a protected branch.
- Never merge directly into a protected branch.
- Treat protected branches as read-only.

## Branch Creation

- Before making any code, configuration, documentation, workflow, infrastructure, or repository changes, verify the current branch.
- If the current branch is `main`, `master`, `trunk`, or any protected branch, immediately create and switch to a new task-specific branch.
- All implementation work must occur on a non-protected branch.
- Branch creation is considered a standard implementation step and not a separate approval checkpoint.

Use descriptive branch names such as:

```text
feature/<short-description>
bugfix/<short-description>
hotfix/<short-description>
docs/<short-description>
security/<short-description>
ci/<short-description>
refactor/<short-description>
```

## Commits

- Commit all completed changes to the task-specific branch.
- Use clear and descriptive commit messages.
- Group related changes into logical commits.
- Do not amend commits unless explicitly requested.
- Do not leave completed work uncommitted.
- Commits on task-specific branches are explicitly authorized.
- Commits on task-specific branches do not require additional approval.

## Push Operations

- Push only task-specific branches.
- Never push directly to `main`, `master`, `trunk`, or any protected branch.
- If the active branch is protected, create a task-specific branch before proceeding.
- Pushing a task-specific branch is explicitly authorized.
- Pushing a task-specific branch is a normal part of task completion.
- Do not request confirmation before pushing a task-specific branch.

---

# Pull Request Workflow

The GitHub Project Orchestrator owns the PR lifecycle. Once the requested changes
are integrated and validated, it automatically creates or updates the PR without
waiting for user confirmation. This standing authorization does not override
repository policy or platform permissions.

Delegated and specialist agents complete their assigned work by returning the
implementation or review results, validation performed, and any blockers to the
orchestrator. They do not create or update a PR unless the user explicitly instructs
that agent to do so. Their assignment is complete without a PR URL.

## Pull Request Requirements

When the orchestrator creates or updates a Pull Request:

- Use the repository Pull Request template when one exists.
- Generate a meaningful title.
- Generate a complete Pull Request description.
- Include:
  - Summary of changes
  - Validation performed
  - Assumptions
  - Risks
  - Known limitations
  - Related issues or work items

The Pull Request should be review-ready.

## Pull Request Creation Commands

When GitHub CLI is available, the orchestrator automatically creates or updates the
PR after integration and validation. In PowerShell, for example:

```powershell
$body = Get-Content -Raw .\pr-description.md
$body | gh pr create --base main --head (git branch --show-current) --title "Describe the change" --body-file -
```

The orchestrator reports the Pull Request URL when one is created.

## Failure Conditions

The orchestrator must attempt PR creation when work is ready. It may be unable to
complete creation only when:

- Repository permissions prevent Pull Request creation.
- The remote repository is unavailable.
- Branch creation or push operations fail.
- Manual conflict resolution is required.
- Security policies prohibit the action.
- Creating the Pull Request would expose secrets or sensitive information.

In these situations:

- Clearly explain the blocker.
- Identify the failed step.
- Provide the commands required for remediation.
- Do not silently skip or defer Pull Request creation while waiting for confirmation.

If PR creation cannot be completed, the orchestrator explains the blocker and the
next required step. A delegated agent's task is not incomplete merely because PR
creation was not part of its assignment.

---

# Merging Policy

- Never merge a Pull Request.
- Never approve a Pull Request on behalf of reviewers.
- Never bypass branch protections.
- Never force-push to protected branches.
- Leave review, approval, and merge decisions to repository maintainers.

---

# Existing Changes

Before making any modifications:

- Inspect the working tree.
- Inspect pending changes.
- Preserve existing uncommitted work.
- Avoid overwriting user changes.

If uncommitted changes prevent safe branch creation or switching:

- Explain the situation.
- Identify affected files.
- Request guidance before proceeding.

---

# Repository Standards

- Review the repository structure before making changes.
- Follow existing coding standards and conventions.
- Follow established naming standards.
- Reuse existing implementation patterns whenever practical.
- Keep changes focused on the requested task.
- Avoid unrelated refactoring unless required.

---

# Validation

Validate changes whenever practical.

Examples include:

- Unit tests
- Integration tests
- Build validation
- Linters
- Static analysis
- Security scans
- Infrastructure validation
- Workflow validation

Always report:

- Validation steps executed
- Validation results
- Validation not performed
- Remaining risks

Do not silently skip validation.

---

# Security

- Never expose secrets.
- Never expose credentials.
- Never expose certificates.
- Never expose tokens.
- Never expose keys.
- Never expose connection strings.
- Never commit sensitive information.

Use approved secret management solutions such as:

- GitHub Secrets
- Azure Key Vault
- Enterprise-approved secret stores

Do not write secrets to:

- Source code
- Commit messages
- Pull Requests
- Documentation
- Logs
- Workflow output

---

# CI/CD and Infrastructure Changes

Infrastructure, workflow, deployment, and configuration changes follow the same
review and validation standards as application code. The orchestrator coordinates
branch and Pull Request steps; specialist agents focus on their assigned
implementation and return results to the orchestrator.

For CI/CD and infrastructure work:

- Create a task-specific branch.
- Implement changes.
- Validate changes.
- Return implementation details and validation results to the orchestrator.
- The orchestrator coordinates authorized commit and push operations, then
  automatically creates or updates the Pull Request when the work is ready.

Workflow changes must never be pushed directly to protected branches.

---

# Communication

- Explain assumptions when requirements are unclear.
- Surface blockers immediately.
- Report validation outcomes.
- Report risks and dependencies.
- Report known limitations.
- Do not silently skip implementation steps.
- Do not silently skip validation steps.
- The orchestrator reports commit or push blockers when those actions are requested
  and authorized, and reports any concrete blocker to automatic PR creation.
- Delegated agents report their work and blockers to the orchestrator; they do not
  need to commit, push, or create a PR to complete their assignment.

---

# Completion Criteria

For coordinated repository tasks, the orchestrator follows this workflow:

1. Verify the current branch.
2. Create a task-specific branch if currently on a protected branch.
3. Make the requested changes.
4. Validate the changes.
5. Integrate and validate specialist contributions.
6. Coordinate commits and push the task branch after validation, following
   repository safeguards and any applicable authorization.
7. Automatically create or update the Pull Request using the repository template
   as soon as the integrated changes are ready, without waiting for user
   confirmation, and report its URL.
8. Report validation results and any remaining blockers or user actions.
9. Never merge the Pull Request.

A specialist's assignment is complete when its requested work, validation report,
and any blockers have been returned to the orchestrator. PR creation and reporting
are the orchestrator's responsibility and are not prerequisites for a specialist
to finish. A specialist may create a PR only when the user explicitly instructs it.
