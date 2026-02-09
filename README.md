# MCP Server Deployment

Deploy MCP server applications to Cloud Foundry with a nonprod/prod pipeline and manual approval gate for production. Works with both **github.com** and **GitHub Enterprise Server**.

This repo contains two deployment workflows, each deploying a pair of applications from their upstream release repos.

## Workflows

### 1. Deploy MCP App Group 1 (`multi-app-deploy.yml`)

Deploys two applications from a **single shared upstream repo**.

| Input | Description | Default |
|-------|-------------|---------|
| `release_tag` | Release tag to deploy (e.g., `v2.7.0`) | *required* |
| `deploy_app1` | Deploy Application 1 | `true` |
| `deploy_app2` | Deploy Application 2 | `true` |
| `skip_nonprod` | Skip nonprod, deploy directly to prod | `false` |

### 2. Deploy Fetch and Web Search MCP Servers (`fetch-websearch-deploy.yml`)

Deploys [spring-fetch-mcp](https://github.com/nkuhn-vmw/spring-fetch-mcp) and [web-search-mcp](https://github.com/nkuhn-vmw/web-search-mcp) from their **separate upstream repos** with independent release tags.

| Input | Description | Default |
|-------|-------------|---------|
| `fetch_release_tag` | Fetch MCP release tag (e.g., `v1.2.0`) | *required if deploying* |
| `websearch_release_tag` | Web Search MCP release tag (e.g., `v1.0.0`) | *required if deploying* |
| `deploy_fetch` | Deploy Fetch MCP Server | `true` |
| `deploy_websearch` | Deploy Web Search MCP Server | `true` |
| `skip_nonprod` | Skip nonprod, deploy directly to prod | `false` |

### Pipeline Structure (both workflows)

1. **Validate & Prepare** - Authenticates to GitHub (or GHE), validates release tags exist, downloads release artifacts, and copies CF manifests from this repo.
2. **Deploy to Nonprod** - Pushes apps to the nonprod CF foundation. Can be skipped.
3. **Notify Approval Required** - Creates a deployment notification. GitHub emails the configured environment reviewers.
4. **Deploy to Prod** - Gated by the `production` environment's required reviewers. Once approved, pushes apps to prod and records the deployed versions.

## Quick Start

### 1. Configure Secrets

Each workflow has its own interactive setup script:

```bash
./setup-secrets.sh                      # App Group 1
./setup-secrets-fetch-websearch.sh      # Fetch & Web Search MCP Servers
```

Both scripts ask whether you're using **github.com** or **GitHub Enterprise Server**. The Fetch & Web Search script also lets you skip shared secrets (GitHub auth, CF credentials, approval reviewers) if you've already configured them via the other script.

### 2. Add CF Manifests

Create manifest files for each application:

```
manifests/
  app1/
    manifest.yml
  app2/
    manifest.yml
  fetch-mcp/
    manifest.yml
  websearch-mcp/
    manifest.yml
```

Paths are configurable via their respective manifest path secrets.

### 3. Configure the Production Approval Gate

1. Go to **Settings > Environments > New environment** and create an environment named `production`
2. Enable **Required reviewers** and add the users/teams who should approve production deployments
3. GitHub will email those reviewers when any workflow reaches the prod deployment step

### 4. Trigger a Deployment

Go to **Actions**, select the workflow, click **Run workflow**, fill in the release tag(s), and select which apps to deploy.

## Secrets Reference

### Shared Secrets (used by both workflows)

#### GitHub Authentication

| Secret | Required | Description |
|--------|----------|-------------|
| `GHE_HOST` | GHE only | GitHub Enterprise hostname (e.g., `github.mycompany.com`). Omit for github.com. |
| `GHE_TOKEN` | Yes | Personal Access Token with `repo`, `read:org`, `workflow` scopes |

#### Cloud Foundry - Nonprod

| Secret | Description |
|--------|-------------|
| `CF_NONPROD_API` | API endpoint (e.g., `https://api.sys.nonprod.example.com`) |
| `CF_NONPROD_USERNAME` | Service account username |
| `CF_NONPROD_PASSWORD` | Service account password |
| `CF_NONPROD_ORG` | Organization name |
| `CF_NONPROD_SPACE` | Space name |

#### Cloud Foundry - Prod

| Secret | Description |
|--------|-------------|
| `CF_PROD_API` | API endpoint (e.g., `https://api.sys.prod.example.com`) |
| `CF_PROD_USERNAME` | Service account username |
| `CF_PROD_PASSWORD` | Service account password |
| `CF_PROD_ORG` | Organization name |
| `CF_PROD_SPACE` | Space name |

#### Notifications

| Secret | Description |
|--------|-------------|
| `APPROVAL_REVIEWERS` | Comma-separated GitHub usernames for deployment notifications |

### App Group 1 Secrets (`multi-app-deploy.yml`)

| Secret | Description |
|--------|-------------|
| `APP_UPSTREAM_REPO` | Upstream repo containing releases (`owner/repo`) |
| `APP1_NAME` | Application 1 base name used in CF push |
| `APP1_MANIFEST_PATH` | Path to app1 manifest (default: `manifests/app1/manifest.yml`) |
| `APP1_ARTIFACT_PATTERN` | Release asset glob, e.g. `my-api-{version}.jar` |
| `APP2_NAME` | Application 2 base name used in CF push |
| `APP2_MANIFEST_PATH` | Path to app2 manifest (default: `manifests/app2/manifest.yml`) |
| `APP2_ARTIFACT_PATTERN` | Release asset glob, e.g. `my-worker-{version}.jar` |

### Fetch & Web Search MCP Servers (`fetch-websearch-deploy.yml`)

| Secret | Description |
|--------|-------------|
| `FETCH_MCP_UPSTREAM_REPO` | Fetch MCP source repo (e.g., `nkuhn-vmw/spring-fetch-mcp`) |
| `FETCH_MCP_NAME` | Fetch MCP base name used in CF push |
| `FETCH_MCP_MANIFEST_PATH` | Path to manifest (default: `manifests/fetch-mcp/manifest.yml`) |
| `FETCH_MCP_ARTIFACT_PATTERN` | Release asset glob, e.g. `fetch-mcp-*.jar` |
| `WEBSEARCH_MCP_UPSTREAM_REPO` | Web Search MCP source repo (e.g., `nkuhn-vmw/web-search-mcp`) |
| `WEBSEARCH_MCP_NAME` | Web Search MCP base name used in CF push |
| `WEBSEARCH_MCP_MANIFEST_PATH` | Path to manifest (default: `manifests/websearch-mcp/manifest.yml`) |
| `WEBSEARCH_MCP_ARTIFACT_PATTERN` | Release asset glob, e.g. `web-search-mcp-*.jar` |
