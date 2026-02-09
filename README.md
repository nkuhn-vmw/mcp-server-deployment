# MCP Server Deployment

Deploy MCP App Group 1 (two applications) to Cloud Foundry with a nonprod/prod pipeline and manual approval gate for production.

Works with both **github.com** and **GitHub Enterprise Server**.

## Workflow Overview

The `multi-app-deploy.yml` workflow is manually triggered and runs four jobs:

1. **Validate & Prepare** - Authenticates to GitHub (or GHE), validates the release tag exists in the upstream repo, downloads release artifacts for both apps, and copies CF manifests from this repo.
2. **Deploy to Nonprod** - Pushes both apps to the nonprod CF foundation. Can be skipped via the `skip_nonprod` input.
3. **Notify Approval Required** - Creates a deployment notification for visibility. GitHub automatically emails the configured environment reviewers.
4. **Deploy to Prod** - Gated by the `production` environment's required reviewers. Once approved, pushes both apps to the prod CF foundation and records the deployed version.

### Workflow Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `release_tag` | Release tag to deploy (e.g., `v2.7.0`) | *required* |
| `deploy_app1` | Deploy Application 1 | `true` |
| `deploy_app2` | Deploy Application 2 | `true` |
| `skip_nonprod` | Skip nonprod, deploy directly to prod | `false` |

## Quick Start

### 1. Configure Secrets

Run the interactive setup script:

```bash
./setup-secrets.sh
```

The script will ask whether you're using **github.com** or **GitHub Enterprise Server**, then walk you through each required secret.

### 2. Add CF Manifests

Create manifest files for each application:

```
manifests/
  app1/
    manifest.yml
  app2/
    manifest.yml
```

The paths are configurable via the `APP1_MANIFEST_PATH` and `APP2_MANIFEST_PATH` secrets.

### 3. Configure the Production Approval Gate

1. Go to **Settings > Environments > New environment** and create an environment named `production`
2. Enable **Required reviewers** and add the users/teams who should approve production deployments
3. GitHub will email those reviewers when the workflow reaches the prod deployment step

### 4. Trigger a Deployment

Go to **Actions > Deploy MCP App Group 1 to Cloud Foundry > Run workflow**, enter the release tag, and select which apps to deploy.

## Secrets Reference

### GitHub Authentication

| Secret | Required | Description |
|--------|----------|-------------|
| `GHE_HOST` | GHE only | GitHub Enterprise hostname (e.g., `github.mycompany.com`). Omit for github.com. |
| `GHE_TOKEN` | Yes | Personal Access Token with `repo`, `read:org`, `workflow` scopes |

### Application Configuration

| Secret | Description |
|--------|-------------|
| `APP_UPSTREAM_REPO` | Upstream repo containing releases (`owner/repo`) |
| `APP1_NAME` | Application 1 base name used in CF push |
| `APP1_MANIFEST_PATH` | Path to app1 manifest in this repo (default: `manifests/app1/manifest.yml`) |
| `APP1_ARTIFACT_PATTERN` | Release asset glob for app1, e.g. `my-api-{version}.jar` |
| `APP2_NAME` | Application 2 base name used in CF push |
| `APP2_MANIFEST_PATH` | Path to app2 manifest in this repo (default: `manifests/app2/manifest.yml`) |
| `APP2_ARTIFACT_PATTERN` | Release asset glob for app2, e.g. `my-worker-{version}.jar` |

### Cloud Foundry - Nonprod

| Secret | Description |
|--------|-------------|
| `CF_NONPROD_API` | API endpoint (e.g., `https://api.sys.nonprod.example.com`) |
| `CF_NONPROD_USERNAME` | Service account username |
| `CF_NONPROD_PASSWORD` | Service account password |
| `CF_NONPROD_ORG` | Organization name |
| `CF_NONPROD_SPACE` | Space name |

### Cloud Foundry - Prod

| Secret | Description |
|--------|-------------|
| `CF_PROD_API` | API endpoint (e.g., `https://api.sys.prod.example.com`) |
| `CF_PROD_USERNAME` | Service account username |
| `CF_PROD_PASSWORD` | Service account password |
| `CF_PROD_ORG` | Organization name |
| `CF_PROD_SPACE` | Space name |

### Notifications

| Secret | Description |
|--------|-------------|
| `APPROVAL_REVIEWERS` | Comma-separated GitHub usernames for deployment notifications |
