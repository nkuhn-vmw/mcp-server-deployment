# MCP Server Deployment

Deploy MCP server applications to Cloud Foundry with automated nonprod/prod pipelines and a manual approval gate for production. Works with both **github.com** and **GitHub Enterprise Server** (3.14+).

## Two Setup Scripts

| Script | Use Case | Prod Targets |
|--------|----------|-------------|
| `multi-app-setup-secrets.sh` | Single nonprod + single prod | 1 prod environment |
| `multi-target-setup.sh` | Single nonprod + multiple prod BUs/LOBs | 1–10 prod environments, deployed in parallel |

Both scripts generate GitHub Actions workflows, configure secrets, and optionally create starter CF manifests. Choose the one that fits your topology.

## Prerequisites

Your workstation needs:

- **`gh` CLI** (>= 2.0) — [install](https://cli.github.com/), then run `gh auth login`
- **`bash`** (>= 4.0) — macOS ships v3; install v5 via `brew install bash` if needed
- **Git** — with push access to the target repository
- **`jq`** — required on self-hosted runners at deploy time

The `gh` CLI must be authenticated with a token that has `repo`, `read:org`, and `workflow` scopes.

## Quick Start

### 1. Generate a config template

```bash
# For single-prod deployments:
./multi-app-setup-secrets.sh --generate-template > my-config.env

# For multi-target (multi-BU/LOB) deployments:
./multi-target-setup.sh --generate-template > my-config.env
```

See [example-multi-app.env](example-multi-app.env) and [example-multi-target.env](example-multi-target.env) for complete examples.

### 2. Edit the config file

Fill in your values — platform, apps, CF credentials, routes, and env vars. The template is fully commented.

Key sections to configure:

- **Platform** — `github.com` or `ghe` (with `GHE_HOST`)
- **Applications** — name, upstream repo, artifact pattern, deploy type, manifest mode
- **CF credentials** — API endpoints, usernames, passwords, orgs, spaces per environment
- **Routes** — nonprod and prod routes for each app
- **Env vars** *(optional)* — JSON objects injected via `cf set-env` before app start

### 3. Run the setup

```bash
./multi-app-setup-secrets.sh --config my-config.env
# or
./multi-target-setup.sh --config my-config.env
```

The script will:
1. Generate workflow YAML under `.github/workflows/`
2. Create starter CF manifests (if using "generate" mode)
3. Configure all required GitHub secrets
4. Save an unmasked debug file (gitignored) for troubleshooting

### 4. Configure the production approval gate

1. Go to **Settings > Environments > New environment** and create `production`
2. Enable **Required reviewers** and add the approvers
3. GitHub emails reviewers automatically when a deployment reaches the prod gate

### 5. Commit and push

```bash
git add .github/workflows/ manifests/
git commit -m "Add deployment workflow and manifests"
git push
```

### 6. Trigger a deployment

Go to **Actions**, select your workflow, click **Run workflow**, enter release tag(s), and choose which apps to deploy.

> **Tip:** Both scripts also support fully interactive mode — just run without arguments.

---

## Advanced Details

### Pipeline Structure

**`multi-app-setup-secrets.sh`** generates a single workflow with 4 jobs:

1. **Validate & Prepare** — authenticates to GitHub, validates release tags exist
2. **Deploy to Nonprod** — downloads artifacts, pushes to nonprod CF, records versions
3. **Notify Approval Required** — creates a GitHub deployment notification
4. **Deploy to Prod** — gated by the `production` environment; deploys after approval

**`multi-target-setup.sh`** generates two workflow files:

- **Reusable deploy workflow** (`{group}-deploy.yml`) — called once per environment
- **Orchestrator** (`{group}-orchestrator.yml`) — manual trigger entry point with this flow:
  1. Validate & prepare
  2. Deploy nonprod
  3. Single approval gate
  4. Deploy all prod targets **in parallel**

### Deploy Types

| Type | Behavior | Use For |
|------|----------|---------|
| `file` | Push artifact directly to CF | JARs, WARs, single-file artifacts |
| `archive` | Extract tar.gz/zip, then push directory | Pre-compiled binaries, source archives |

Supported archive formats: `.tar.gz`, `.tgz`, `.zip`.

### Release Tag Resolution

When you enter a tag (e.g., `v2.7.0`), the workflow resolves it in order:

1. Release by exact tag
2. Release by alternate format (adds/removes `v` prefix)
3. Release by name (searches all releases)
4. Plain git tag (no release required)

Download behavior depends on source and deploy type:

- **Release** — downloads matching release assets (both `file` and `archive`)
- **Git tag + `archive`** — downloads source tarball and extracts it
- **Git tag + `file`** — **fails** (file-type apps need compiled artifacts from a Release)

### Environment Variables Injection

Provide a JSON object for `CF_ENV_JSON` in your config:

```
APP_1_CF_ENV_JSON={"WEBSEARCH_API_KEY":"your-key","ANOTHER_VAR":"value"}
```

The workflow uses `cf push --no-start` + `cf set-env` + `cf start` to inject these before the app boots. Leave empty for a simple `cf push`.

### Version Tracking

After each deployment, the workflow updates a single `.last-deployed-{group}` file with one line per app/target:

```
nonprod  fetch-dev      v1.2.0  2024-03-04T15:30:00Z
nonprod  gh-mcp-dev     v0.31.0 2024-03-04T15:30:00Z
prod-alpha  fetch-alpha v1.2.0  2024-03-04T15:35:00Z
```

Lines are updated in-place on each deploy, keeping the file sorted.

### Shared Production CF Credentials (multi-target only)

When using `multi-target-setup.sh` with multiple prod targets that share the same CF API and credentials, set in your config:

```
SHARED_PROD_CF_CREDS=true
SHARED_PROD_CF_API=https://api.sys.prod.example.com
SHARED_PROD_CF_USERNAME=cf-deployer
SHARED_PROD_CF_PASSWORD=your-password
```

Each target still needs its own label, org, space, and per-app config. Per-target `PROD_N_CF_API/USERNAME/PASSWORD` can override the shared values if needed.

In interactive mode, the script asks this automatically when there are 2+ prod targets.

### CF Manifests

If you chose **generate** mode, starter manifests are created with defaults based on deploy type:

- **`file`** — `java_buildpack_offline`, 1G memory, HTTP health check
- **`archive`** — `binary_buildpack`, 256M memory, process health check

Review and customize for your apps. Existing manifests are never overwritten.

### Secrets Reference

All secrets are configured automatically by the setup scripts. Secret names use app-specific prefixes derived from the app name (e.g., `fetch-mcp` → `FETCH_MCP_*`).

> **Note:** App names producing a `GITHUB_` prefix are rejected — GitHub Actions reserves that namespace. Use an abbreviation (e.g., `gh-mcp` instead of `github-mcp`).

### Files

| File | Purpose |
|------|---------|
| `multi-app-setup-secrets.sh` | Setup for single nonprod + single prod |
| `multi-target-setup.sh` | Setup for single nonprod + multiple prod targets |
| `example-multi-app.env` | Config template for `multi-app-setup-secrets.sh` |
| `example-multi-target.env` | Config template for `multi-target-setup.sh` |
| `.github/workflows/` | Generated deployment workflows |
| `manifests/` | CF manifest files for each application |
| `.last-deployed-*` | Version tracking files (auto-updated by workflows) |

### GHES Compatibility

Tested with GitHub Enterprise Server 3.14+. Workflows use `gh release download` directly — no artifact actions required, avoiding v3/v4 compatibility issues on GHES.

Self-hosted runners must have `gh` CLI >= 2.0 and `jq` installed.
