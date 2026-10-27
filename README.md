# GitHub DevOps Agent Project

Workspace-level GitHub Copilot custom agents for coordinating repository automation, documentation, and security review.

## Agents

| Agent | Responsibility |
| --- | --- |
| GitHub Project Orchestrator | Coordinates the task, delegates to specialists, and integrates their results. |
| Senior DevOps Engineer | Creates and reviews GitHub Actions and CI/CD configuration. |
| Documentation Writer | Creates and updates project and contributor documentation. |
| Security Reviewer | Performs a read-only review and reports prioritized findings. |

The specialist agents are configured for orchestrator delegation. Start a task with **GitHub Project Orchestrator** in a GitHub Copilot-enabled editor. The orchestrator should invoke only the specialists needed for the task.

## Git and pull request policy

Agents are instructed to inspect the current branch and working tree before editing, and never to make changes on `main`, `master`, or `trunk`. They should use a task-specific branch and prepare changes for review through a pull request. They must preserve unrelated uncommitted work and avoid committing or pushing unless asked.

These instructions guide agent behavior; they do not technically prevent a person or tool from pushing directly to a protected branch. To enforce that policy, configure GitHub repository rulesets or branch protection for the default branch. Require pull requests, required reviews, and required status checks as appropriate for the repository.

Use the [pull request template](.github/PULL_REQUEST_TEMPLATE.md) when opening a PR.

## Repository layout

- `.github/copilot-instructions.md` — shared repository guidance.
- `.github/agents/` — specialist and orchestrator agent definitions.
- `.github/PULL_REQUEST_TEMPLATE.md` — pull request checklist.

## Microsoft Fabric deployment template

These are GitHub Actions workflows, so they use the GitHub Actions `shell: pwsh`
syntax; Azure DevOps `PowerShell@2` tasks are not supported here. Where a matching
script exists, workflows invoke the checked-out `.ps1` file directly instead of
duplicating its implementation inline.

This repository includes a Fabric-only reusable workflow and a caller example:

- `.github/workflows/fabric-deploy.yml` — reusable `workflow_call` orchestrator for
  dev, test, and prod. Dev is updated from Git (`fabric-sync-workspace.yml`); test and
  prod use selective deployment (`fabric-promote-to-stage.yml`), each optionally
  followed by `fabric-execute-notebook.yml`. Prod runs only after test succeeds.
- `examples/workflows/fabric/deploy.yml` — caller template showing all three
  environments; see the orchestrator inputs in the workflow file. Needs the
  `fabric-dev`, `fabric-test`, and `fabric-prod` GitHub Environments (require
  reviewers on prod) and the `scripts/fabric/` scripts copied to the caller.
- `.github/workflows/fabric-promote-to-stage.yml` — reusable `workflow_call` workflow that
  starts a Microsoft Fabric Deployment Pipeline promotion between stages.
- `examples/workflows/fabric/promote-to-stage.yml` — manual caller example for promoting
  changes, such as DEV to TEST or TEST to PROD.
- `scripts/fabric/deployment-pipelines-selective-deploy.ps1` — PowerShell script used by the
  promotion workflow to selectively deploy items between stages (with type and folder
  exclusions and `-WhatIf` preview) and poll the asynchronous Fabric operation. The
  workflow also invokes `scripts/fabric/authenticate.ps1` to acquire and mask its Fabric
  access token.
- `.github/workflows/fabric-deployment-pipelines-deploy-all.yml` — reusable
  `workflow_call` workflow that submits a deploy-all request between Fabric Deployment
  Pipeline stages and waits for the asynchronous operation.
- `examples/workflows/fabric/deployment-pipelines-deploy-all.yml` — manual caller example
  for deploying all supported content from DEV to TEST or PROD.
- `scripts/fabric/deployment-pipelines-deploy-all.ps1` — PowerShell script used by the
  deploy-all workflow; copy it and `scripts/fabric/authenticate.ps1` to the same
  `scripts/fabric/` paths in the consuming repository.
- `.github/workflows/fabric-execute-notebook.yml` — reusable `workflow_call` workflow that
  runs a Fabric notebook by name through the REST API and waits for the job result.
- `examples/workflows/fabric/execute-notebook.yml` — manual caller example.
- `scripts/fabric/execute-notebook.ps1` — PowerShell script used by the notebook workflow
  (copy it and `scripts/fabric/authenticate.ps1` to the same `scripts/fabric/` paths in the
  consuming repository).
- `.github/workflows/fabric-sync-workspace.yml` — reusable `workflow_call` workflow that
  authenticates, resolves a workspace, syncs it from Git (remote wins on conflicts), and
  optionally runs a notebook afterwards. Uses GitHub OIDC and runs from a protected ref.
- `examples/workflows/fabric/sync-workspace.yml` — manual caller example.
- `scripts/fabric/authenticate.ps1`, `scripts/fabric/list-workspaces.ps1`,
  `scripts/fabric/update-from-git.ps1`, and `scripts/fabric/execute-notebook.ps1` — the
  four scripts used by the sync workflow. Copy all four to the same `scripts/fabric/` paths in
  the consuming repository.
- `.github/workflows/fabric-authenticate.yml` — reusable `workflow_call` workflow that
  acquires a Power BI/Fabric token as a service or user principal (secrets `tenant_id`,
  `client_id`, `client_secret`, `username`, `password`; input `principal_type`). Secrets
  are passed to `scripts/fabric/authenticate.ps1` through environment variables. The token
  is masked and exported as `FABRIC_ACCESS_TOKEN` within that job only; GitHub does not
  allow masked secrets as job outputs, so jobs needing a token should run the script in
  their own job.
- `scripts/fabric/authenticate.ps1` — shared token acquisition script used by the
  authentication, workspace sync, promotion, deploy-all, and notebook workflows.
- The Fabric deployment workflow runs a PowerShell script from the caller's repository;
  this template does not include a deployment implementation.
- `scripts/fabric/requirements.in` and `scripts/fabric/requirements.lock` — input and
  hash-verified, fully pinned Fabric CLI dependency lock for Ubuntu and Python 3.12.

Name component-specific files with the component first, followed by the action or asset
description, for example `fabric-deploy.yml`, `fabric-execute-notebook.yml`, and
`fabric-promote-to-stage.yml`. Use the same `fabric-` prefix for related scripts and
dependency assets.

The workflow uses Microsoft's [Fabric CLI](https://github.com/microsoft/fabric-cli)
(pinned to `1.7.0`, running on Python `3.12`), which uses
[`fabric-cicd`](https://github.com/microsoft/fabric-cicd), to publish supported item
definitions from the checked-out repository to one Fabric workspace. All workflow
`run` steps and the caller-provided deployment entry point use PowerShell. It deploys
all items of the selected item types in the source directory and does not delete
orphaned workspace items. Copy the caller workflow and required supporting files from
`scripts/fabric/` to the consuming repository, then replace the example owner/repository and
immutable workflow reference with the reviewed template repository commit SHA.

### Fabric deployment setup

1. Enable Fabric Git integration or otherwise store supported Fabric item definitions
   in the consuming repository in the layout expected by `fabric-cicd`. Copy the example
   caller workflow and required supporting files from `scripts/fabric/` into the consuming
   repository. Provide a PowerShell Fabric deployment script in the caller repository
   at the default path or set the optional `deployment_script` input to its location.
2. Register an Entra ID application/service principal. In Fabric admin portal, a Fabric
   administrator must enable **Service principals can use Fabric APIs** (the REST API
   documentation also covers managed identities). Grant the application only the
   workspace access and item/API permissions its selected item types require. A
   workspace Contributor role is a common starting point; item and API requirements
   vary by item type.
3. Configure a federated identity credential on that application for the consuming
   GitHub repository and protected environment. For example, for repository
   `OWNER/REPOSITORY` and environment `fabric-dev`, use issuer
   `https://token.actions.githubusercontent.com`, subject
   `repo:OWNER/REPOSITORY:environment:fabric-dev`, and audience
   `api://AzureADTokenExchange`.
4. Create the `fabric-dev` GitHub Environment in the **consuming repository** and add
   approval/restriction rules appropriate to the target. Add repository or environment
   variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and
   `FABRIC_DEV_WORKSPACE_ID`. These are identifiers, not client secrets. The example
   does not require a long-lived Azure credential or Azure subscription.
5. Review the copied workflow, dependency lock, item types, and Fabric environment,
   then run the workflow with **Actions → Deploy to Microsoft Fabric (example) → Run
   workflow**. The reusable job receives `contents: read` and `id-token: write` only.

The caller input `item_types` is a JSON list, for example
`["Notebook","DataPipeline","Environment"]`. `fabric_environment` is the
`fabric-cicd` environment/configuration name used by the deployment script; set it and
the workspace ID for the target environment. Protect production with a separate
GitHub Environment and matching Entra federated credential. Do not expose deployment
credentials to `pull_request` workflows.

| Orchestrator input | Required | Purpose |
| --- | --- | --- |
| `azure_client_id`, `azure_tenant_id` | Yes | Entra application and tenant IDs used for OIDC; not secret. |
| `pipeline_name`, `dev_workspace_name` | Yes | Deployment Pipeline name and the dev workspace synced from Git. |
| `dev_/test_/prod_stage_name` | No | Stage names and matching caller GitHub Environment names; defaults are `Development`, `Test`, `Production`. |
| `test_workspace_id`, `prod_workspace_id` | No | Needed only to run the notebook after test/prod deployment. |
| `notebook_name` | No | Notebook run after each environment update; empty skips. |
| `excluded_resource_types`, `excluded_folder_reference` | No | Exclusions for test/prod selective deployment. |
| `timeout_minutes`, `what_if` | No | Operation timeout (default 60) and preview-only mode for test/prod. |

No GitHub secret is required by the template. OIDC requires `id-token: write` on the
caller job and matching Entra federation. The client and tenant IDs can be supplied
from GitHub Actions variables; do not put a client secret in the caller.
Create caller GitHub Environments whose names match the configured stage names
(`Development`, `Test`, and `Production` by default), and configure production
approvals and Entra federation for the matching Environment.

The lock is generated for Python 3.12 on 64-bit Linux using:

```powershell
uv pip compile --generate-hashes --python-version 3.12 --python-platform x86_64-manylinux_2_28 --output-file scripts/fabric/requirements.lock scripts/fabric/requirements.in
```

When updating dependencies, review the complete resolved dependency tree, regenerate
the lock, and test it before changing the pinned versions. The workflow installs
binary wheels only with pip's `--require-hashes` mode before authenticating to Azure.

The library performs a full publish for the selected item types on each run; scope is
not inferred from changed files. `unpublish_all_orphan_items()` is intentionally not
called, so this starter does not remove workspace content. Review support and
permissions for each item type in the upstream [fabric-cicd documentation](https://microsoft.github.io/fabric-cicd/latest/)
before adopting it.

### Fabric Deployment Pipeline promotion

Use the separate `fabric-promote-to-stage.yml` workflow after publishing to DEV to ask Fabric
to promote content from one Deployment Pipeline stage to another. The workflow calls
the Fabric REST API `POST /v1/deploymentPipelines/{deploymentPipelineId}/deploy` after
resolving the pipeline and stages by display name, listing the source stage items, and
removing items excluded by item type or by a workspace folder (including descendants).
Only the remaining items are submitted. This is distinct from publishing repository
definitions with `fabric-cicd`.

Copy `examples/workflows/fabric/promote-to-stage.yml` into the consuming repository and
copy `scripts/fabric/deployment-pipelines-selective-deploy.ps1` and
`scripts/fabric/authenticate.ps1` to the same `scripts/fabric/` paths. The reusable
workflow checks out the caller repository and invokes both scripts. Replace the example
repository reference and placeholder commit SHA. Configure a protected
`fabric-test` and `fabric-prod` GitHub Environment and matching Entra federated
identity for each target. Restrict both GitHub Environments to trusted deployment
branches or tags and require appropriate approvals, especially for `fabric-prod`.
The reusable workflow also fails before checkout or authentication unless the
caller ref is protected by a branch protection rule or repository ruleset. The
promotion and authentication scripts are checked out from the caller repository.
The authentication script obtains and masks a token through the Azure CLI session; the
workflow clears it after the deployment script runs. Both scripts run in the caller's
job, so review and protect them and the deployment ref; do not allow untrusted code to
run on a permitted deployment ref. Configure repository or environment variables
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `FABRIC_DEPLOYMENT_PIPELINE_NAME`,
`FABRIC_DEV_STAGE_NAME`, `FABRIC_TEST_STAGE_NAME`, `FABRIC_PROD_STAGE_NAME`, and
optionally `FABRIC_EXCLUDED_RESOURCE_TYPES` and `FABRIC_EXCLUDED_FOLDER_REFERENCE`.
These are names and identifiers, not secrets. The example selects the proper target stage and
protected environment from the manual `test` or `prod` choice. Do not use
`pull_request` triggers for promotions. The caller job and reusable job grant
`contents: read` to check out the scripts and `id-token: write` for Azure OIDC; no
other `GITHUB_TOKEN` permissions are granted. Azure login exchanges GitHub's OIDC
identity for an Azure CLI session, and `scripts/fabric/authenticate.ps1` obtains and
masks a Fabric API access token before the deployment script uses it.

| Promotion input | Required | Purpose |
| --- | --- | --- |
| `azure_client_id`, `azure_tenant_id` | Yes | Entra application and tenant IDs used for OIDC. |
| `github_environment` | Yes | Caller repository environment that protects and authorizes the promotion. |
| `pipeline_name` | Yes | Fabric Deployment Pipeline display name. |
| `source_stage_name`, `target_stage_name` | Yes | Stage display names identifying the promotion direction. |
| `excluded_resource_types` | No | Comma-separated item types to exclude, such as `Reflex,Warehouse`. |
| `excluded_folder_reference` | No | One source workspace folder path to exclude with its descendants. |
| `timeout_minutes` | No | Maximum minutes to poll the operation; defaults to 60. |
| `what_if` | No | When `true`, previews deployed and excluded items without deploying. |

Grant the identity the Fabric permissions needed to administer the deployment
pipeline and contribute to both source and target workspaces. Microsoft documents
service-principal support subject to the item types participating in the operation;
verify that every item in the promotion is supported for service-principal use before
relying on unattended deployment. Protect production promotions with GitHub
Environment approvals. Fabric returns an asynchronous operation ID that the
workflow polls until completion.

### Fabric Deployment Pipeline deploy-all

Use the deploy-all template to ask Fabric to deploy all supported items between two
stages in a Deployment Pipeline. Unlike the selective promotion workflow above, it
submits only the source and target stage IDs, with no item subset or exclusions;
Fabric determines the supported items to deploy. It does not publish repository
definitions with `fabric-cicd`.

Copy `examples/workflows/fabric/deployment-pipelines-deploy-all.yml` into the
consuming repository and copy
`scripts/fabric/deployment-pipelines-deploy-all.ps1` to the same
`scripts/fabric/` path, and copy `scripts/fabric/authenticate.ps1` to that directory too.
The reusable workflow checks out and runs the scripts at those fixed paths; it has no
script-path input.
Replace `OWNER/fabric-devops-templates` and `<PINNED_COMMIT_SHA>` in the caller
with the template repository and reviewed commit. The example's manual `test` or
`prod` choice selects the corresponding target stage and protected GitHub Environment.

Configure `fabric-test` and `fabric-prod` Environments in the consuming repository
with appropriate deployment branch/tag restrictions and approvals, especially for
production. Configure a matching Entra federated identity credential for each
repository/environment subject (`repo:OWNER/REPOSITORY:environment:fabric-test` or
`...:environment:fabric-prod`), issuer
`https://token.actions.githubusercontent.com`, and audience
`api://AzureADTokenExchange`. The caller grants `contents: read` and
`id-token: write`; the reusable workflow rejects unprotected refs and does not run
for pull-request events. The workflow runs the deployment and authentication scripts
from the caller's checkout after OIDC login; `authenticate.ps1` obtains and masks the
Fabric token, and the workflow clears it after deployment. Protect both scripts and the
deployment ref, require appropriate production approvals, and review changes to the
scripts before running them. Configure repository or environment variables
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `FABRIC_DEPLOYMENT_PIPELINE_NAME`,
`FABRIC_DEV_STAGE_NAME`, `FABRIC_TEST_STAGE_NAME`, and `FABRIC_PROD_STAGE_NAME`.
These are identifiers and display names, not secrets. Grant the Entra identity the
Fabric permissions required for the deployment pipeline and its source and target
workspaces.

| Deploy-all input | Required | Purpose |
| --- | --- | --- |
| `azure_client_id`, `azure_tenant_id` | Yes | Entra application and tenant IDs used for OIDC. |
| `github_environment` | Yes | Protected caller-repository Environment authorizing the deployment and matching the OIDC subject. |
| `pipeline_name` | Yes | Fabric Deployment Pipeline display name. |
| `source_stage_name`, `target_stage_name` | Yes | Display names used to resolve the distinct source and target stages. |
| `deployment_note` | No | Optional note recorded with the deployment; an empty caller value uses the script's default note. Do not include secrets. |
| `timeout_minutes` | No | Maximum time to poll the operation; defaults to 60 minutes (the script accepts 1–360). |
| `what_if` | No | When `true`, resolves the pipeline and stages but does not send the deploy request. |

The script polls Fabric's asynchronous operation until success, failure, cancellation,
or timeout. If polling times out, the Fabric operation may still be running; verify its
status in Fabric before retrying to avoid overlapping deployments. Do not use a
`pull_request` trigger for deployments.

### Fabric notebook execution

`fabric-execute-notebook.yml` starts a `RunNotebook` job through the Fabric REST API
(`POST /v1/workspaces/{id}/items/{notebookId}/jobs/instances?jobType=RunNotebook`),
looking the notebook up by unique display name, then polls until it completes, fails,
is cancelled, or times out (cancellation is requested on timeout). Optional inputs:
`parameters_json` (JSON object; booleans, integers and floats are typed, everything
else is a string), `spark_conf_json`, `timeout_minutes`, `polling_interval_seconds`
and `wait_for_completion`.

Copy `examples/workflows/fabric/execute-notebook.yml`,
`scripts/fabric/execute-notebook.ps1`, and `scripts/fabric/authenticate.ps1` into the
consuming repository, replace the repository reference and pinned SHA, and configure
`AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `FABRIC_WORKSPACE_ID` and a protected GitHub Environment with
matching Entra federated identity. The same protected-ref and no-`pull_request`
rules as promotion apply. The service principal needs workspace access and Fabric
item read/execute permission. The REST API does not return notebook outputs; have
the notebook write results to a Lakehouse or storage and use the logged root
activity ID for tracing in the Fabric Monitoring Hub.

### Fabric workspace Git sync

`fabric-sync-workspace.yml` runs four scripts in sequence: authenticate through Azure
OIDC, resolve the workspace by ID or exact display name, update the workspace from Git,
and optionally execute a notebook. Copy `authenticate.ps1`,
`list-workspaces.ps1`, `update-from-git.ps1`, and
`execute-notebook.ps1` to the same `scripts/fabric/` paths in the caller repository.
Configure the caller's protected GitHub Environment and matching Entra federated
identity. The service principal needs workspace access and permission to use the
workspace's Git connection; Git is preferred when resolving conflicts. Sync runs are
serialized per caller repository to avoid overlaps between workspace IDs and names.
`timeout_minutes` is limited to 150 so the sync and optional notebook can each finish
within the workflow's six-hour job limit.

### Deployment target layout

Keep reusable workflows specific to a target, and place caller examples and target
scripts under `examples/` so they do not run automatically in this template repository.
Future components can add their own reusable workflow and example using the
`<component>-<action-description>.yml` convention (for example, `fabric-deploy.yml` or
`fabric-promote-to-stage.yml`) without changing the existing Fabric
deployment contract.

### Verified Microsoft references

- [fabric-cicd project](https://github.com/microsoft/fabric-cicd) and its
  [authentication examples](https://github.com/microsoft/fabric-cicd/blob/main/docs/example/authentication.md)
  document `FabricWorkspace`, explicit token credentials, and `publish_all_items`.
- [Fabric REST API identity support](https://learn.microsoft.com/en-us/rest/api/fabric/articles/identity-support)
  documents service-principal support and the required tenant setting.
- [Fabric Git integration overview](https://learn.microsoft.com/en-us/fabric/cicd/git-integration/intro-to-git-integration)
  describes source-controlled workspaces and supported item types.
- [Fabric deployment pipelines](https://learn.microsoft.com/en-us/fabric/cicd/deployment-pipelines/intro-to-deployment-pipelines)
  are the in-service stage-to-stage deployment option; this template instead uses the
  official code-first library to publish repository definitions directly to a workspace.
- [Deploy stage content REST API](https://learn.microsoft.com/en-us/rest/api/fabric/core/deployment-pipelines/deploy-stage-content)
  documents the deployment request, required deployment-pipeline and workspace
  permissions, supported identities, and asynchronous operation response.
