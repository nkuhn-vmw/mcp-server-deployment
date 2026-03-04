# MCP Server Deployment

Deploy MCP server applications to Cloud Foundry with a nonprod/prod pipeline and manual approval gate for production. Works with both **github.com** and **GitHub Enterprise Server** (3.14+).

## How It Works

The setup script (`multi-app-setup-secrets.sh`) programmatically generates a GitHub Actions deployment workflow for any number of applications (1, 2, 3, or more). Each run of the script:

1. Prompts for application details (name, upstream repo, artifact pattern, etc.)
2. Generates a workflow YAML file under `.github/workflows/`
3. Optionally generates starter CF manifest files for each app
4. Configures all required GitHub secrets with app-specific prefixes
5. Saves an unmasked debug file for troubleshooting

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
4. **Runner** — GitHub Actions runner label (default: `ubuntu-latest`; use your self-hosted runner label for GHES)
5. **Workflow name** — short name for the workflow and generated files (e.g., `t5-apps`, `mcp-prod`)
6. **Manifest mode** — *Generate* (auto-create starter manifests) or *Bring your own* (provide paths to existing manifests)
7. **Per-app details** — for each app:
   - **Name** — CF app base name (e.g., `fetch-t1`)
   - **Upstream repo** — GitHub repo containing releases (e.g., `org/my-api`)
   - **Manifest path** — path to the CF manifest in this repo *(only in "bring your own" mode)*
   - **Artifact pattern** — release asset glob (e.g., `fetch-mcp-*.jar`, `*_Linux_x86_64.tar.gz`)
   - **Deploy type** — `file` (push artifact directly) or `archive` (extract tar.gz/zip first, push directory)
   - **CF env vars** *(optional)* — JSON object of environment variables to inject before app start
   - **Nonprod route** — CF route for nonprod (e.g., `app.apps-nonprod.internal`)
   - **Prod route** — CF route for prod (e.g., `app.apps-prod.internal`)
8. **CF credentials** — nonprod and prod API endpoints, usernames, passwords, orgs, spaces
9. **Approval reviewers** — comma-separated GitHub usernames for deployment notifications

The script generates:
- A workflow at `.github/workflows/deploy-{workflow-name}.yml`
- Starter manifest files at `manifests/{app-name}/manifest.yml` *(when using "Generate" mode)*
- A debug file at `.multi-app-secrets-debug-{workflow-name}.txt` (gitignored)

### 2. Review CF Manifests

If you chose **Generate** mode, the script creates starter manifest files at `manifests/{app-name}/manifest.yml` with sensible defaults based on deploy type:

- **`file` apps** — Java/Spring template with `java_buildpack_offline`, 1G memory, HTTP health check
- **`archive` apps** — Binary template with `binary_buildpack`, 256M memory, process health check

Review and customize these manifests for your applications (memory, buildpack, env vars, services, health checks, etc.). Existing manifests are never overwritten.

If you chose **Bring your own** mode, create manifest files at the paths you specified during setup.

### 3. Configure the Production Approval Gate

1. Go to **Settings > Environments > New environment** and create an environment named `production`
2. Enable **Required reviewers** and add the users/teams who should approve production deployments
3. GitHub will automatically email those reviewers when any workflow reaches the prod deployment step

### 4. Commit and Push

```bash
git add .github/workflows/deploy-*.yml manifests/
git commit -m "Add deployment workflow and manifests"
git push
```

### 5. Trigger a Deployment

Go to **Actions**, select your generated workflow, click **Run workflow**, fill in the release tag(s), and select which apps to deploy.

## Pipeline Structure

Each generated workflow has 4 jobs:

1. **Validate & Prepare** — Authenticates to GitHub (or GHE), validates that the specified release tags exist in the upstream repos. Tries exact tag, then with/without `v` prefix, then release name, then plain git tag as fallback. Outputs a `source` flag per app (`release` or `tag`) so downstream jobs know how to download
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

After each deployment, the workflow updates a single `.last-deployed-{workflow-group}` file with one line per app/target combination. Each line records the target label, app name, version, and timestamp:

```
nonprod  fetch-dev   v1.2.0  2024-03-04T15:30:00Z
nonprod  gh-mcp-dev  v0.31.0 2024-03-04T15:30:00Z
prod-alpha  fetch-alpha  v1.2.0  2024-03-04T15:35:00Z
prod-alpha  gh-mcp-alpha v0.31.0 2024-03-04T15:35:00Z
```

Lines are updated in-place (not appended) on each deploy, keeping the file sorted.

## Environment Variables Injection

To inject environment variables into a CF app before it starts (e.g., API keys), provide a JSON object when prompted for `CF_ENV_JSON` during setup:

```json
{"WEBSEARCH_API_KEY":"your-key-here","ANOTHER_VAR":"value"}
```

The workflow uses `cf push --no-start` + `cf set-env` + `cf start` to inject these before the app boots. If no env vars are needed, leave the prompt empty and the workflow will use a simple `cf push`.

## Deploy Types

Each app can use one of two deploy types, selected during setup:

### `file` (default)

Downloads the release artifact and pushes it directly to CF. Use for JAR files, WAR files, or any single-file artifact:

```
Artifact pattern: fetch-mcp-*.jar
Deploy type: file
→ cf push -p ./artifact.jar
```

### `archive`

Downloads a tar.gz or zip archive, extracts it, then pushes the extracted directory to CF. Use for pre-compiled binaries or source archives:

```
Artifact pattern: github-mcp-server_Linux_x86_64.tar.gz
Deploy type: archive
→ extract archive → cf push -p ./extracted/
```

The manifest controls which buildpack CF uses. For example, a pre-compiled Go binary needs `binary_buildpack`:

```yaml
applications:
  - name: github-mcp
    memory: 256M
    buildpacks:
      - binary_buildpack
    command: ./github-mcp-server
```

Supported archive formats: `.tar.gz`, `.tgz`, `.zip`.

## Routes

Each app has separate routes for nonprod and prod, configured during setup. The workflow rewrites the manifest's `route:` entry at deploy time using `sed`, so manifests don't need environment-specific route entries.

## Release Tag Resolution

When you enter a release tag (e.g., `v2.7.0` or `2.7.0`), the workflow tries to find it in this order:

1. **Release by exact tag** (e.g., `v2.7.0`)
2. **Release by alternate format** — adds or removes the `v` prefix (e.g., tries `2.7.0` if `v2.7.0` fails)
3. **Release by name** — searches all releases for a matching name
4. **Git tag** — checks if the tag exists as a plain git tag (no release required)

How the download works depends on the source and deploy type:

- **Release source** — downloads release assets matching the artifact pattern (both `file` and `archive` apps)
- **Tag source + `archive` app** — downloads the source tarball from the git tag and extracts it (works for pre-compiled binaries or buildpack-compiled apps)
- **Tag source + `file` app** — **fails with a clear error**. File-type apps (JARs, WARs) require compiled artifacts that only exist in a GitHub Release. A source tarball contains source code, not compiled binaries

This means you can enter either `v2.7.0` or `2.7.0`, and it works whether the upstream repo uses GitHub Releases or plain git tags. However, `file`-type apps always require a proper GitHub Release with the compiled artifact attached.

## Secrets Reference

All secrets are configured automatically by the setup script. Secret names use app-specific prefixes derived from the app name (e.g., app name `fetch-t1` → prefix `FETCH_T1_*`).

> **Note:** App names that produce a `GITHUB_` prefix (e.g., `github-mcp`) are rejected by the script because GitHub Actions reserves the `GITHUB_` namespace for secrets. Use an abbreviation instead (e.g., `gh-mcp`).

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
| `{PREFIX}_NONPROD_ROUTE` | CF route for nonprod deployments (e.g., `app.apps-nonprod.internal`) |
| `{PREFIX}_PROD_ROUTE` | CF route for prod deployments (e.g., `app.apps-prod.internal`) |

## Files

| File | Purpose |
|------|---------|
| `multi-app-setup-secrets.sh` | Interactive setup script — generates workflows and configures secrets |
| `.github/workflows/deploy-*.yml` | Generated deployment workflows (created by setup script) |
| `.multi-app-secrets-debug-*.txt` | Debug files with unmasked secret values (gitignored) |
| `manifests/` | CF manifest files for each application |
| `.gitignore` | Excludes debug files from version control |

## GHES Compatibility

Tested with GitHub Enterprise Server 3.14+. The workflows download release assets directly via `gh release download` — no artifact actions required, avoiding the v3/v4 compatibility issues on GHES.

The `GH_HOST` environment variable is only set when `GHE_HOST` is non-empty, which avoids the `gh` CLI bug where an empty `GH_HOST=""` causes authentication failures.

Self-hosted runners must have `gh` CLI >= 2.0 and `jq` installed.
