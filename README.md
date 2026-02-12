# MCP Server Deployment

Deploy MCP server applications to Cloud Foundry with a nonprod/prod pipeline and manual approval gate for production. Works with both **github.com** and **GitHub Enterprise Server** (3.14+).

## How It Works

The setup script (`multi-app-setup-secrets.sh`) programmatically generates a GitHub Actions deployment workflow for any number of applications (1, 2, 3, or more). Each run of the script:

1. Prompts for application details (name, upstream repo, artifact pattern, etc.)
2. Generates a workflow YAML file under `.github/workflows/`
3. Configures all required GitHub secrets with app-specific prefixes
4. Saves an unmasked debug file for troubleshooting

You can run the script multiple times to create separate workflows for different app groups. All workflows share the same CF credentials and production approval gate.

## Quick Start

### 1. Run the Setup Script

```bash
./multi-app-setup-secrets.sh
```

The interactive script will prompt for:

1. **Platform** — github.com or GitHub Enterprise Server
2. **Shared vs app-only secrets** — first run configures everything; subsequent runs can skip shared secrets
3. **Number of apps** — how many applications in this deployment group (1–10)
4. **Per-app details** — for each app:
   - **Name** — CF app base name (e.g., `fetch-t1`)
   - **Upstream repo** — GitHub repo containing releases (e.g., `org/my-api`)
   - **Manifest path** — path to the CF manifest in this repo (e.g., `manifests/fetch-mcp/manifest.yml`)
   - **Artifact pattern** — release asset glob (e.g., `fetch-mcp-*.jar`)
   - **CF env vars** *(optional)* — JSON object of environment variables to inject before app start
5. **CF credentials** — nonprod and prod API endpoints, usernames, passwords, orgs, spaces
6. **Approval reviewers** — comma-separated GitHub usernames for deployment notifications

The script generates:
- A workflow at `.github/workflows/deploy-{app1}-{app2}-...{appN}.yml`
- A debug file at `.multi-app-secrets-debug-{app1}-{app2}-...{appN}.txt` (gitignored)

### 2. Add CF Manifests

Create manifest files for each application. Paths are configurable during setup:

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
3. GitHub will automatically email those reviewers when any workflow reaches the prod deployment step

### 4. Commit and Push

```bash
git add .github/workflows/deploy-*.yml manifests/
git commit -m "Add deployment workflow"
git push
```

### 5. Trigger a Deployment

Go to **Actions**, select your generated workflow, click **Run workflow**, fill in the release tag(s), and select which apps to deploy.

## Pipeline Structure

Each generated workflow has 4 jobs:

1. **Validate & Prepare** — Authenticates to GitHub (or GHE), validates that the specified release tags exist in the upstream repos
2. **Deploy to Nonprod** — Downloads release artifacts, pushes apps to the nonprod CF foundation, records deployed versions in git
3. **Notify Approval Required** — Creates a deployment notification via the GitHub API for broader visibility
4. **Deploy to Prod** — Gated by the `production` environment's required reviewers. Once approved, downloads release artifacts, pushes apps to prod, and records deployed versions

### Workflow Inputs

Each app in the group gets two inputs:

| Input | Description | Default |
|-------|-------------|---------|
| `{app}_release_tag` | Release tag (e.g., `v2.7.0`) | *required if deploying* |
| `deploy_{app}` | Whether to deploy this app | `true` |

Apps can be deployed independently — set `deploy_{app}` to `false` to skip an app.

### Version Tracking

After each deployment, the workflow commits a `.last-deployed-{app}-{env}` file recording the deployed release tag. This provides an audit trail directly in the repo.

## Environment Variables Injection

To inject environment variables into a CF app before it starts (e.g., API keys), provide a JSON object when prompted for `CF_ENV_JSON` during setup:

```json
{"WEBSEARCH_API_KEY":"your-key-here","ANOTHER_VAR":"value"}
```

The workflow uses `cf push --no-start` + `cf set-env` + `cf start` to inject these before the app boots. If no env vars are needed, leave the prompt empty and the workflow will use a simple `cf push`.

## Secrets Reference

All secrets are configured automatically by the setup script. Secret names use app-specific prefixes derived from the app name (e.g., app name `fetch-t1` → prefix `FETCH_T1_*`).

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
| `multi-app-setup-secrets.sh` | Interactive setup script — generates workflows and configures secrets |
| `.github/workflows/deploy-*.yml` | Generated deployment workflows (created by setup script) |
| `.github/workflows/fetch-websearch-deploy.yml` | Legacy standalone workflow for fetch + websearch MCP servers |
| `setup-secrets-fetch-websearch.sh` | Legacy setup script for the standalone workflow |
| `.multi-app-secrets-debug-*.txt` | Debug files with unmasked secret values (gitignored) |
| `manifests/` | CF manifest files for each application |
| `.gitignore` | Excludes debug files from version control |

## GHES Compatibility

Tested with GitHub Enterprise Server 3.14+. The workflows download release assets directly via `gh release download` — no artifact actions required, avoiding the v3/v4 compatibility issues on GHES.

The `GH_HOST` environment variable is only set when `GHE_HOST` is non-empty, which avoids the `gh` CLI bug where an empty `GH_HOST=""` causes authentication failures.

Self-hosted runners must have `gh` CLI >= 2.0 and `jq` installed.
