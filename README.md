# MCP Server Deployment

Deploy MCP server applications to Cloud Foundry with a nonprod/prod pipeline and manual approval gate for production. Works with both **github.com** and **GitHub Enterprise Server** (3.14+).

## How It Works

This repo uses a **generator-based** approach. The setup script programmatically generates deployment workflow YAML for any number of applications (1, 2, 3, or more). You run the setup script once per app group to:

1. Generate an app-specific workflow YAML (e.g., `deploy-fetch-t1-web-t1.yml`)
2. Configure all required GitHub secrets with app-specific prefixes
3. Save a debug file with all configured values for troubleshooting

You can run the setup script multiple times to create workflows for many different app groups, all sharing the same CF credentials and approval gate.

## Quick Start

### 1. Generate a Workflow and Configure Secrets

```bash
./multi-app-setup-secrets.sh
```

The interactive script will prompt for:
- **Platform** - github.com or GitHub Enterprise Server
- **Shared secrets** (first run) - GitHub PAT, CF credentials (nonprod + prod), approval reviewers
- **Number of apps** - How many applications in this deployment group (1-10)
- **Per-app details** - Name, upstream repo, manifest path, artifact pattern, optional env vars

The script generates a workflow at `.github/workflows/deploy-{app1}-{app2}-...yml` and a debug file at `.multi-app-secrets-debug-{slug}.txt`.

### 2. Add CF Manifests

Create manifest files for each application. Paths are configurable via the setup script:

```
manifests/
  fetch-mcp/
    manifest.yml
  websearch-mcp/
    manifest.yml
```

### 3. Configure the Production Approval Gate

1. Go to **Settings > Environments > New environment** and create an environment named `production`
2. Enable **Required reviewers** and add the users/teams who should approve production deployments
3. GitHub will email those reviewers when any workflow reaches the prod deployment step

### 4. Commit and Push

```bash
git add .github/workflows/deploy-{app1}-{app2}.yml manifests/
git commit -m "Add deployment workflow for {app1} & {app2}"
git push
```

### 5. Trigger a Deployment

Go to **Actions**, select your generated workflow, click **Run workflow**, fill in the release tag(s), and select which apps to deploy.

## Pipeline Structure

Each generated workflow has 4 jobs:

1. **Validate & Prepare** - Authenticates to GitHub (or GHE), validates release tags exist in upstream repos, downloads release artifacts, copies CF manifests from this repo
2. **Deploy to Nonprod** - Pushes apps to the nonprod CF foundation, records deployed versions
3. **Notify Approval Required** - Creates a deployment notification via GitHub API. GitHub emails the configured environment reviewers
4. **Deploy to Prod** - Gated by the `production` environment's required reviewers. Once approved, pushes apps to prod and records deployed versions

### Workflow Inputs

Each app in the group gets two inputs:

| Input | Description | Default |
|-------|-------------|---------|
| `{app}_release_tag` | Release tag for the app (e.g., `v2.7.0`) | *required if deploying* |
| `deploy_{app}` | Whether to deploy this app | `true` |

Each app has its own release tag and can be deployed independently.

## Environment Variables Injection

To inject environment variables into a CF app before it starts (e.g., API keys), provide a JSON object when prompted for `CF_ENV_JSON` during setup:

```json
{"WEBSEARCH_API_KEY":"your-key-here","ANOTHER_VAR":"value"}
```

The workflow uses `cf push --no-start` + `cf set-env` + `cf start` to inject these before the app boots.

## Secrets Reference

All secrets are configured automatically by the setup script. Secret names use app-specific prefixes derived from the app name (e.g., app name `fetch-t1` gets prefix `FETCH_T1_*`).

### Shared Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `GHE_HOST` | GHE only | GitHub Enterprise hostname (e.g., `github.mycompany.com`). Omit for github.com |
| `GHE_TOKEN` | Yes | Personal Access Token with `repo`, `read:org`, `workflow` scopes |
| `CF_NONPROD_API` | Yes | Nonprod CF API endpoint |
| `CF_NONPROD_USERNAME` | Yes | Nonprod CF service account username |
| `CF_NONPROD_PASSWORD` | Yes | Nonprod CF service account password |
| `CF_NONPROD_ORG` | Yes | Nonprod CF organization |
| `CF_NONPROD_SPACE` | Yes | Nonprod CF space |
| `CF_PROD_API` | Yes | Prod CF API endpoint |
| `CF_PROD_USERNAME` | Yes | Prod CF service account username |
| `CF_PROD_PASSWORD` | Yes | Prod CF service account password |
| `CF_PROD_ORG` | Yes | Prod CF organization |
| `CF_PROD_SPACE` | Yes | Prod CF space |
| `APPROVAL_REVIEWERS` | Yes | Comma-separated GitHub usernames for deployment notifications |

### Per-App Secrets (prefix = app name in UPPER_SNAKE_CASE)

| Secret | Description |
|--------|-------------|
| `{PREFIX}_UPSTREAM_REPO` | Upstream repo containing releases (`owner/repo`) |
| `{PREFIX}_NAME` | Application base name used in CF push |
| `{PREFIX}_MANIFEST_PATH` | Path to CF manifest in this repo |
| `{PREFIX}_ARTIFACT_PATTERN` | Release asset glob (e.g., `fetch-mcp-*.jar`) |
| `{PREFIX}_CF_ENV_JSON` | *(Optional)* JSON object of env vars to inject before app start |

## Files

| File | Purpose |
|------|---------|
| `multi-app-setup-secrets.sh` | Interactive setup script - generates workflows and configures secrets |
| `.github/workflows/deploy-*.yml` | Generated workflows (created by setup script) |
| `.multi-app-secrets-debug-*.txt` | Debug files with all secret values (gitignored) |
| `manifests/` | CF manifest files for each application |

## GHES Compatibility

Tested with GitHub Enterprise Server 3.14+. The workflows download release assets directly via `gh release download` (no artifact actions required).

Self-hosted runners must have `gh` CLI >= 2.0 and `jq` installed.
