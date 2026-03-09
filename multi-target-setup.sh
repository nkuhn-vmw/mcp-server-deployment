#!/bin/bash
#
# Multi-target deployment setup: generates a reusable deploy workflow + orchestrator
# that deploys N apps to 1 nonprod + N prod targets (BUs/LOBs) with per-target config.
#
# Uses GitHub Environments for per-target secrets (uniform names, different values).
# Single approval gate → all prod targets deploy in parallel.
#
# Works with both GitHub Enterprise Server and github.com
# Requires: gh CLI authenticated with repo access
#
# Usage:
#   ./multi-target-setup.sh                     # Interactive mode
#   ./multi-target-setup.sh --config vars.env   # Load from config file
#   ./multi-target-setup.sh --generate-template # Print a template config file
#

set -e

CONFIG_FILE=""
NON_INTERACTIVE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│${NC} ${BOLD}$1${NC}"
    echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

print_subheader() {
    echo ""
    echo -e "${CYAN}── $1 ──${NC}"
    echo ""
}

print_success() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "  ${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

print_bullet() {
    echo -e "  ${DIM}•${NC} $1"
}

# ─── Core Utilities ──────────────────────────────────────────────

check_gh_cli() {
    if ! command -v gh &> /dev/null; then
        print_error "GitHub CLI (gh) is not installed."
        echo "    Install it from: https://cli.github.com/"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        print_error "GitHub CLI is not authenticated."
        echo "    Run: gh auth login"
        exit 1
    fi

    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "unknown")
    print_success "GitHub CLI authenticated"
    print_success "Target repository: ${BOLD}$REPO${NC}"
}

prompt_value() {
    local label="$1"
    local example="$2"
    echo -e "  ${BOLD}$label${NC}"
    [ -n "$example" ] && echo -e "  ${DIM}Example: $example${NC}"
    read -p "  > " REPLY
    echo ""
}

prompt_hidden() {
    local label="$1"
    echo -e "  ${BOLD}$label${NC}"
    echo -e "  ${DIM}(input hidden)${NC}"
    read -sp "  > " REPLY
    echo ""
    echo ""
}

set_secret() {
    local name="$1"
    local value="$2"

    if [ -z "$value" ]; then
        print_warning "Skipping $name (empty value)"
        return 1
    fi

    local error_output
    if error_output=$(echo "$value" | gh secret set "$name" 2>&1); then
        print_success "$name"
    else
        print_error "Failed to set $name: $error_output"
        return 1
    fi
}

set_env_secret() {
    local env_name="$1"
    local name="$2"
    local value="$3"

    if [ -z "$value" ]; then
        return 0
    fi

    local error_output
    if error_output=$(echo "$value" | gh secret set "$name" --env "$env_name" 2>&1); then
        print_success "${env_name}/${name}"
    else
        print_error "Failed to set ${env_name}/${name}: $error_output"
        return 1
    fi
}

create_environment() {
    local env_name="$1"

    if gh api "repos/${REPO}/environments/${env_name}" --method PUT --input /dev/null >/dev/null 2>&1; then
        print_success "Environment created: ${env_name}"
    else
        print_warning "Environment may already exist: ${env_name}"
    fi
}

setup_production_reviewers() {
    local reviewers="$1"

    # Build JSON reviewers array
    local reviewer_json="["
    local first=true
    IFS=',' read -ra REVIEWER_LIST <<< "$reviewers"
    for reviewer in "${REVIEWER_LIST[@]}"; do
        reviewer=$(echo "$reviewer" | xargs)

        # Get user ID
        local user_id
        user_id=$(gh api "users/${reviewer}" --jq '.id' 2>/dev/null || echo "")
        if [ -z "$user_id" ]; then
            print_warning "Could not find user ID for ${reviewer}, skipping"
            continue
        fi

        [ "$first" = true ] && first=false || reviewer_json="${reviewer_json},"
        reviewer_json="${reviewer_json}{\"type\":\"User\",\"id\":${user_id}}"
    done
    reviewer_json="${reviewer_json}]"

    if gh api "repos/${REPO}/environments/production" --method PUT --input - <<EOF >/dev/null 2>&1
{
    "reviewers": ${reviewer_json},
    "deployment_branch_policy": null
}
EOF
    then
        print_success "Production environment configured with required reviewers"
    else
        print_warning "Could not configure production reviewers automatically"
        echo -e "  ${DIM}Manually configure at: Settings > Environments > production > Required reviewers${NC}"
    fi
}

show_value() {
    local name="$1"
    local value="$2"

    if [[ "$name" == *"PASSWORD"* ]] || [[ "$name" == *"TOKEN"* ]] || [[ "$name" == *"API_KEY"* ]] || [[ "$name" == *"ENV_JSON"* ]]; then
        echo -e "  ${BOLD}$name${NC}: ${DIM}(hidden)${NC}"
    elif [ -z "$value" ]; then
        echo -e "  ${BOLD}$name${NC}: ${YELLOW}(empty - will be skipped)${NC}"
    else
        echo -e "  ${BOLD}$name${NC}: $value"
    fi
}

choose_platform() {
    echo "Where are the upstream release repositories hosted?"
    echo ""
    echo -e "  ${BOLD}1)${NC} github.com"
    echo -e "  ${BOLD}2)${NC} GitHub Enterprise Server"
    echo ""

    read -p "Enter choice [1-2]: " platform_choice

    case $platform_choice in
        1)
            GITHUB_PLATFORM="github.com"
            GHE_HOST=""
            ;;
        2)
            GITHUB_PLATFORM="ghe"
            ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
}

# ─── Data Model ──────────────────────────────────────────────────

NUM_APPS=0
APP_NAMES=()
APP_UPPERS=()
APP_LOWERS=()
APP_UPSTREAM_REPOS=()
APP_ARTIFACT_PATTERNS=()
APP_DEPLOY_TYPES=()
APP_MANIFEST_MODES=()
APP_BASE_MANIFEST_PATHS=()

RUNNER=""
WORKFLOW_GROUP=""
WORKFLOW_SLUG=""
REUSABLE_WORKFLOW=""
ORCHESTRATOR_WORKFLOW=""
DEBUG_FILE=""
POST_DEPLOY_SCRIPT=""
APPROVAL_REVIEWERS=""
GHE_HOST=""
GHE_TOKEN=""
GITHUB_PLATFORM=""

# Target definitions (index 0 = nonprod, 1..N = prod targets)
NUM_PROD_TARGETS=0
TARGET_LABELS=()
TARGET_CF_APIS=()
TARGET_CF_USERNAMES=()
TARGET_CF_PASSWORDS=()
TARGET_CF_ORGS=()
TARGET_CF_SPACES=()

# Per-app-per-target config: indexed as [target_idx * NUM_APPS + app_idx]
APP_TARGET_NAMES=()
APP_TARGET_ROUTES=()
APP_TARGET_CF_ENV_JSONS=()

compute_prefixes() {
    for i in $(seq 0 $((NUM_APPS - 1))); do
        APP_UPPERS[$i]=$(echo "${APP_NAMES[$i]}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
        APP_LOWERS[$i]=$(echo "${APP_NAMES[$i]}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    done
}

compute_names() {
    WORKFLOW_SLUG=$(echo "$WORKFLOW_GROUP" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')
    REUSABLE_WORKFLOW=".github/workflows/${WORKFLOW_SLUG}-deploy.yml"
    ORCHESTRATOR_WORKFLOW=".github/workflows/${WORKFLOW_SLUG}-orchestrator.yml"
    DEBUG_FILE=".multi-target-debug-${WORKFLOW_SLUG}.txt"
}

target_app_idx() {
    local target="$1" app="$2"
    echo $(( target * NUM_APPS + app ))
}

sanitize_label() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# ─── YAML Generation ────────────────────────────────────────────

apply_placeholders() {
    sed -e "s|%UPPER%|${1}|g" \
        -e "s|%LOWER%|${2}|g" \
        -e "s|%NAME%|${3}|g" \
        -e "s|%ENV%|${4:-}|g" \
        -e "s|%ENV_UPPER%|${5:-}|g" \
        -e "s|%ENV_LABEL%|${6:-}|g"
}

# ─── Reusable Workflow Generation ────────────────────────────────

emit_reusable_header() {
    echo "# AUTO-GENERATED by multi-target-setup.sh"
    echo "# Generated on $(date -u '+%Y-%m-%d')"
    echo "# Reusable deploy workflow for: ${WORKFLOW_GROUP}"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        echo "# App $((i+1)): ${APP_NAMES[$i]} (${APP_DEPLOY_TYPES[$i]})"
    done
    echo "#"
    echo "name: ${WORKFLOW_GROUP} - Deploy Pack"
    echo ""
    echo "on:"
    echo "  workflow_call:"
    echo "    inputs:"
    echo "      environment_name:"
    echo "        required: true"
    echo "        type: string"
    echo "      target_label:"
    echo "        required: true"
    echo "        type: string"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
      %LOWER%_release_tag:
        required: true
        type: string
      %LOWER%_version:
        required: true
        type: string
      %LOWER%_version_dotted:
        required: true
        type: string
      %LOWER%_source:
        required: true
        type: string
      deploy_%LOWER%:
        required: true
        type: string
BLOCK
    done
}

emit_reusable_permissions() {
    cat <<'EOF'

permissions:
  contents: write
  actions: read

env:
  CF_CLI_VERSION: "v8"
EOF
}

emit_reusable_deploy_job() {
    cat <<EOF

jobs:
  deploy:
    runs-on: ${RUNNER}
EOF
    cat <<'EOF'
    environment: ${{ inputs.environment_name }}
    steps:
      - uses: actions/checkout@v4

      - name: Install CF CLI
        run: |
          curl -sL "https://packages.cloudfoundry.org/stable?release=linux64-binary&version=${{ env.CF_CLI_VERSION }}&source=github" | tar -zx
          chmod +x cf8
          sudo ln -sf "$PWD/cf8" /usr/local/bin/cf

      - name: Authenticate to CF
        env:
          CF_API: ${{ secrets.CF_API }}
          CF_USER: ${{ secrets.CF_USERNAME }}
          CF_PASS: ${{ secrets.CF_PASSWORD }}
          CF_ORG: ${{ secrets.CF_ORG }}
          CF_SPACE: ${{ secrets.CF_SPACE }}
        run: |
          ./cf8 api "$CF_API"
          ./cf8 auth "$CF_USER" "$CF_PASS"
          ./cf8 target -o "$CF_ORG" -s "$CF_SPACE"
          echo "Authenticated to CF: ${CF_API} (org: ${CF_ORG}, space: ${CF_SPACE})"

      - name: Configure GitHub Authentication
        env:
          GHE_TOKEN: ${{ secrets.GHE_TOKEN }}
          GHE_HOST: ${{ secrets.GHE_HOST }}
        run: |
          if [ -n "$GHE_HOST" ]; then
            echo "${GHE_TOKEN}" | gh auth login --hostname "${GHE_HOST}" --with-token
          else
            echo "${GHE_TOKEN}" | gh auth login --with-token
          fi
EOF

    # Per-app download and deploy steps
    for i in $(seq 0 $((NUM_APPS - 1))); do
        echo ""
        if [ "${APP_DEPLOY_TYPES[$i]}" = "archive" ]; then
            # ── Archive mode: download, extract, push directory ──
            cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
      - name: Download and extract %NAME% release assets
        if: inputs.deploy_%LOWER% == 'true'
        env:
          _GHE_HOST: ${{ secrets.GHE_HOST }}
          GH_TOKEN: ${{ secrets.GHE_TOKEN }}
          UPSTREAM_REPO: ${{ secrets.%UPPER%_UPSTREAM_REPO }}
          ARTIFACT_PATTERN: ${{ secrets.%UPPER%_ARTIFACT_PATTERN }}
          %UPPER%_MANIFEST: ${{ secrets.%UPPER%_MANIFEST_PATH }}
        run: |
          [ -n "$_GHE_HOST" ] && export GH_HOST="$_GHE_HOST"
          TAG="${{ inputs.%LOWER%_release_tag }}"
          SOURCE="${{ inputs.%LOWER%_source }}"
          VERSION_DOTTED="${{ inputs.%LOWER%_version_dotted }}"

          mkdir -p ./%LOWER%
          if [ "$SOURCE" = "tag" ]; then
            echo "Downloading %NAME% source archive for tag ${TAG}..."
            gh api "repos/${UPSTREAM_REPO}/tarball/${TAG}" > "./%LOWER%/source.tar.gz"
          else
            PATTERN=$(echo "${ARTIFACT_PATTERN}" | sed "s/{version}/${VERSION_DOTTED}/g")
            echo "Downloading %NAME% release artifact matching: ${PATTERN}"
            gh release download "${TAG}" \
              --repo "${UPSTREAM_REPO}" \
              --pattern "${PATTERN}" \
              --dir ./%LOWER%
          fi

          ARCHIVE=$(ls ./%LOWER%/ | head -1)
          echo "Extracting ${ARCHIVE}..."
          mkdir -p ./%LOWER%/extracted
          if [[ "${ARCHIVE}" == *.tar.gz ]] || [[ "${ARCHIVE}" == *.tgz ]]; then
            tar -xzf "./%LOWER%/${ARCHIVE}" -C ./%LOWER%/extracted
          elif [[ "${ARCHIVE}" == *.zip ]]; then
            unzip -o "./%LOWER%/${ARCHIVE}" -d ./%LOWER%/extracted
          else
            echo "Error: Unknown archive format: ${ARCHIVE}"
            exit 1
          fi

          MANIFEST_PATH="${%UPPER%_MANIFEST:-manifests/%LOWER%/manifest.yml}"
          if [ ! -f "$MANIFEST_PATH" ]; then
            echo "Error: %NAME% manifest not found at ${MANIFEST_PATH}"
            exit 1
          fi
          cp "$MANIFEST_PATH" ./%LOWER%/extracted/manifest.yml
          echo "%NAME% extracted contents:"
          ls -la ./%LOWER%/extracted/
BLOCK

            echo ""
            cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
      - name: Deploy %NAME% to ${{ inputs.target_label }}
        if: inputs.deploy_%LOWER% == 'true'
        env:
          %UPPER%_NAME: ${{ secrets.%UPPER%_NAME }}
          VERSION: ${{ inputs.%LOWER%_version }}
          %UPPER%_CF_ENV_JSON: ${{ secrets.%UPPER%_CF_ENV_JSON }}
          %UPPER%_ROUTE: ${{ secrets.%UPPER%_ROUTE }}
        run: |
          DEPLOY_NAME="${%UPPER%_NAME}-${{ inputs.target_label }}-${VERSION}"
          echo "Deploying ${DEPLOY_NAME} from extracted directory..."

          # Override manifest route with target-specific route
          sed -i "s|route:.*|route: ${%UPPER%_ROUTE}|" ./%LOWER%/extracted/manifest.yml
          echo "Route set to: ${%UPPER%_ROUTE}"

          if [ -n "$%UPPER%_CF_ENV_JSON" ]; then
            ./cf8 push "${DEPLOY_NAME}" \
              -f ./%LOWER%/extracted/manifest.yml \
              -p "./%LOWER%/extracted" \
              --no-start

            echo "Setting env vars..."
            echo "${%UPPER%_CF_ENV_JSON}" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r key value; do
              ./cf8 set-env "${DEPLOY_NAME}" "$key" "$value"
            done

            echo "Starting ${DEPLOY_NAME}..."
            ./cf8 start "${DEPLOY_NAME}"
          else
            ./cf8 push "${DEPLOY_NAME}" \
              -f ./%LOWER%/extracted/manifest.yml \
              -p "./%LOWER%/extracted"
          fi

          echo "%NAME% deployed: ${DEPLOY_NAME}"
BLOCK
        else
            # ── File mode: download artifact, push directly ──
            cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
      - name: Download %NAME% release assets
        if: inputs.deploy_%LOWER% == 'true'
        env:
          _GHE_HOST: ${{ secrets.GHE_HOST }}
          GH_TOKEN: ${{ secrets.GHE_TOKEN }}
          UPSTREAM_REPO: ${{ secrets.%UPPER%_UPSTREAM_REPO }}
          ARTIFACT_PATTERN: ${{ secrets.%UPPER%_ARTIFACT_PATTERN }}
          %UPPER%_MANIFEST: ${{ secrets.%UPPER%_MANIFEST_PATH }}
        run: |
          [ -n "$_GHE_HOST" ] && export GH_HOST="$_GHE_HOST"
          TAG="${{ inputs.%LOWER%_release_tag }}"
          SOURCE="${{ inputs.%LOWER%_source }}"
          VERSION_DOTTED="${{ inputs.%LOWER%_version_dotted }}"

          mkdir -p ./%LOWER%
          if [ "$SOURCE" = "tag" ]; then
            echo "Error: %NAME% ${TAG} exists only as a git tag (no release)."
            echo "File-type apps require a release with compiled artifacts attached."
            echo "Please create a release at the upstream repo with the artifact matching: ${ARTIFACT_PATTERN}"
            exit 1
          else
            PATTERN=$(echo "${ARTIFACT_PATTERN}" | sed "s/{version}/${VERSION_DOTTED}/g")
            echo "Downloading %NAME% release artifact matching: ${PATTERN}"
            gh release download "${TAG}" \
              --repo "${UPSTREAM_REPO}" \
              --pattern "${PATTERN}" \
              --dir ./%LOWER%
          fi

          MANIFEST_PATH="${%UPPER%_MANIFEST:-manifests/%LOWER%/manifest.yml}"
          if [ ! -f "$MANIFEST_PATH" ]; then
            echo "Error: %NAME% manifest not found at ${MANIFEST_PATH}"
            exit 1
          fi
          cp "$MANIFEST_PATH" ./%LOWER%/manifest.yml
          echo "%NAME% release assets and manifest ready:"
          ls -la ./%LOWER%/
BLOCK

            echo ""
            cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
      - name: Deploy %NAME% to ${{ inputs.target_label }}
        if: inputs.deploy_%LOWER% == 'true'
        env:
          %UPPER%_NAME: ${{ secrets.%UPPER%_NAME }}
          VERSION: ${{ inputs.%LOWER%_version }}
          %UPPER%_CF_ENV_JSON: ${{ secrets.%UPPER%_CF_ENV_JSON }}
          %UPPER%_ROUTE: ${{ secrets.%UPPER%_ROUTE }}
        run: |
          DEPLOY_NAME="${%UPPER%_NAME}-${{ inputs.target_label }}-${VERSION}"
          ARTIFACT=$(ls ./%LOWER%/ | grep -v manifest.yml | head -1)
          echo "Artifact found: ${ARTIFACT}"

          # Override manifest route with target-specific route
          sed -i "s|route:.*|route: ${%UPPER%_ROUTE}|" ./%LOWER%/manifest.yml
          echo "Route set to: ${%UPPER%_ROUTE}"

          if [ -n "$%UPPER%_CF_ENV_JSON" ]; then
            echo "Pushing ${DEPLOY_NAME} (--no-start, env vars to inject)..."
            ./cf8 push "${DEPLOY_NAME}" \
              -f ./%LOWER%/manifest.yml \
              -p "./%LOWER%/${ARTIFACT}" \
              --no-start

            echo "Setting env vars..."
            echo "${%UPPER%_CF_ENV_JSON}" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r key value; do
              ./cf8 set-env "${DEPLOY_NAME}" "$key" "$value"
            done

            echo "Starting ${DEPLOY_NAME}..."
            ./cf8 start "${DEPLOY_NAME}"
          else
            echo "Deploying ${DEPLOY_NAME}..."
            ./cf8 push "${DEPLOY_NAME}" \
              -f ./%LOWER%/manifest.yml \
              -p "./%LOWER%/${ARTIFACT}"
          fi

          echo "%NAME% deployed: ${DEPLOY_NAME}"
BLOCK
        fi
    done

    # Post-deploy script
    echo ""
    echo "      - name: Run post-deploy script"
    echo "        env:"
    echo "          POST_DEPLOY_SCRIPT: \${{ secrets.POST_DEPLOY_SCRIPT }}"
    echo "          TARGET_LABEL: \${{ inputs.target_label }}"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          DEPLOY_%UPPER%: ${{ inputs.deploy_%LOWER% }}
          %UPPER%_NAME: ${{ secrets.%UPPER%_NAME }}
          %UPPER%_VERSION: ${{ inputs.%LOWER%_version }}
BLOCK
    done
    echo "        run: |"
    echo "          if [ -z \"\$POST_DEPLOY_SCRIPT\" ] || [ ! -f \"\$POST_DEPLOY_SCRIPT\" ]; then"
    echo "            echo \"No post-deploy script configured, skipping\""
    echo "            exit 0"
    echo "          fi"
    echo ""
    echo "          # Build list of deployed app names for the script"
    echo "          DEPLOYED_APPS=\"\""
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          if [ "$DEPLOY_%UPPER%" = "true" ]; then
            DEPLOYED_APPS="${DEPLOYED_APPS} ${%UPPER%_NAME}-${TARGET_LABEL}-${%UPPER%_VERSION}"
          fi
BLOCK
    done
    echo ""
    cat <<'EOF'
          export DEPLOYED_APPS="${DEPLOYED_APPS# }"
          export TARGET_LABEL

          chmod +x "$POST_DEPLOY_SCRIPT"
          echo "Running post-deploy script: ${POST_DEPLOY_SCRIPT}"
          echo "  Target: ${TARGET_LABEL}"
          echo "  Deployed apps: ${DEPLOYED_APPS}"
          ./"$POST_DEPLOY_SCRIPT"
EOF

    # Version tracking
    echo ""
    cat <<'EOF'
      - name: Configure Authentication for git push
        env:
          GHE_TOKEN: ${{ secrets.GHE_TOKEN }}
          GHE_HOST: ${{ secrets.GHE_HOST }}
        run: |
          if [ -n "$GHE_HOST" ]; then
            git remote set-url origin "https://x-access-token:${GHE_TOKEN}@${GHE_HOST}/${{ github.repository }}.git"
          else
            git remote set-url origin "https://x-access-token:${GHE_TOKEN}@github.com/${{ github.repository }}.git"
          fi
EOF

    echo ""
    echo "      - name: Record \${{ inputs.target_label }} deployed versions"
    echo "        env:"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          %UPPER%_NAME: ${{ secrets.%UPPER%_NAME }}
BLOCK
    done
    echo "        run: |"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          DEPLOY_%UPPER%="${{ inputs.deploy_%LOWER% }}"
BLOCK
    done
    echo ""
    echo "          CHANGED=false"
    echo "          TRACK_FILE=\".last-deployed-${WORKFLOW_GROUP}\""
    echo ""
    echo "          git pull --rebase || true"
    echo "          touch \"\$TRACK_FILE\""
    echo ""
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          if [ "$DEPLOY_%UPPER%" = "true" ]; then
            grep -v "^${{ inputs.target_label }} ${%UPPER%_NAME} " "$TRACK_FILE" > "${TRACK_FILE}.tmp" || true
            echo "${{ inputs.target_label }} ${%UPPER%_NAME} ${{ inputs.%LOWER%_release_tag }} $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "${TRACK_FILE}.tmp"
            sort -o "$TRACK_FILE" "${TRACK_FILE}.tmp"
            rm -f "${TRACK_FILE}.tmp"
            CHANGED=true
          fi
BLOCK
        echo ""
    done
    cat <<'EOF'
          if [ "$CHANGED" = "true" ]; then
            git add "$TRACK_FILE"
            git config user.name "github-actions[bot]"
            git config user.email "github-actions[bot]@users.noreply.github.com"
EOF
    echo ""
    echo '            MSG="Record ${{ inputs.target_label }} deployment:"'
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
            if [ "$DEPLOY_%UPPER%" = "true" ]; then
              MSG="${MSG} ${%UPPER%_NAME}=${{ inputs.%LOWER%_release_tag }}"
            fi
BLOCK
    done
    echo ""
    cat <<'EOF'
            git diff --cached --quiet || git commit -m "${MSG}"

            # Retry push in case parallel prod deployments conflict
            MAX_RETRIES=3
            for attempt in $(seq 1 $MAX_RETRIES); do
              if git push; then
                echo "Version tracking pushed (attempt $attempt)"
                break
              fi
              if [ $attempt -eq $MAX_RETRIES ]; then
                echo "::warning::Could not push version tracking after $MAX_RETRIES attempts"
              else
                echo "Push failed, retrying after pull..."
                sleep $((attempt * 2))
                git pull --rebase || true
              fi
            done
          fi
EOF
}

# ─── Orchestrator Workflow Generation ────────────────────────────

emit_orchestrator_header() {
    echo "# AUTO-GENERATED by multi-target-setup.sh"
    echo "# Generated on $(date -u '+%Y-%m-%d')"
    echo "# Orchestrator for: ${WORKFLOW_GROUP}"
    echo "# Targets: nonprod, $(IFS=', '; echo "${TARGET_LABELS[*]:1}")"
    echo "#"
    echo "name: ${WORKFLOW_GROUP} - Orchestrator"
    echo ""
    echo "# On-demand only — manually triggered from the Actions tab"
    echo "on:"
    echo "  workflow_dispatch:"
    echo "    inputs:"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        echo "      ${APP_LOWERS[$i]}_release_tag:"
        echo "        description: '${APP_NAMES[$i]} release tag (e.g., v2.7.0)'"
        echo "        required: false"
        echo "        type: string"
    done
    for i in $(seq 0 $((NUM_APPS - 1))); do
        echo "      deploy_${APP_LOWERS[$i]}:"
        echo "        description: 'Deploy ${APP_NAMES[$i]}'"
        echo "        required: false"
        echo "        type: boolean"
        echo "        default: true"
    done
}

emit_orchestrator_permissions() {
    cat <<'EOF'

permissions:
  contents: write
  actions: read
  deployments: write

env:
  CF_CLI_VERSION: "v8"
EOF
}

emit_orchestrator_validate_job() {
    cat <<EOF

  # ──────────────────────────────────────────────────────────────
  # Job 1: Validate releases and prepare outputs
  # ──────────────────────────────────────────────────────────────
  validate-and-prepare:
    runs-on: ${RUNNER}
    outputs:
EOF
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
      %LOWER%_release_tag: ${{ steps.validate.outputs.%LOWER%_release_tag }}
      %LOWER%_version: ${{ steps.validate.outputs.%LOWER%_version }}
      %LOWER%_version_dotted: ${{ steps.validate.outputs.%LOWER%_version_dotted }}
      %LOWER%_source: ${{ steps.validate.outputs.%LOWER%_source }}
BLOCK
    done
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
      deploy_%LOWER%: ${{ steps.validate.outputs.deploy_%LOWER% }}
BLOCK
    done

    cat <<'EOF'
    steps:
      - uses: actions/checkout@v4

      - name: Configure GitHub Authentication
        env:
          GHE_TOKEN: ${{ secrets.GHE_TOKEN }}
          GHE_HOST: ${{ secrets.GHE_HOST }}
        run: |
          if [ -z "$GHE_TOKEN" ]; then
            echo "Error: GHE_TOKEN secret must be configured"
            exit 1
          fi

          if [ -n "$GHE_HOST" ]; then
            echo "${GHE_TOKEN}" | gh auth login --hostname "${GHE_HOST}" --with-token
            gh auth status --hostname "${GHE_HOST}"
            echo "Authenticated to GitHub Enterprise: ${GHE_HOST}"
          else
            echo "${GHE_TOKEN}" | gh auth login --with-token
            gh auth status
            echo "Authenticated to github.com"
          fi
EOF

    # Show configuration summary
    echo ""
    echo "      - name: Show configuration summary"
    echo "        env:"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          %UPPER%_UPSTREAM_REPO: ${{ secrets.%UPPER%_UPSTREAM_REPO }}
BLOCK
    done
    echo "        run: |"
    echo '          echo "=========================================="'
    echo '          echo "DEPLOYMENT CONFIGURATION"'
    echo '          echo "=========================================="'
    for i in $(seq 0 $((NUM_APPS - 1))); do
        [ $i -gt 0 ] && echo '          echo "------------------------------------------"'
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          echo "%NAME%:"
          echo "  Upstream repo:  ${%UPPER%_UPSTREAM_REPO}"
          echo "  Deploy:         ${{ inputs.deploy_%LOWER% }}"
          echo "  Release tag:    ${{ inputs.%LOWER%_release_tag }}"
BLOCK
    done
    echo '          echo "=========================================="'

    # Validate inputs
    echo ""
    echo "      - name: Validate inputs"
    echo "        run: |"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          DEPLOY_%UPPER%="${{ inputs.deploy_%LOWER% }}"
          %UPPER%_TAG="${{ inputs.%LOWER%_release_tag }}"
BLOCK
    done
    echo ""
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          if [ "$DEPLOY_%UPPER%" = "true" ] && [ -z "$%UPPER%_TAG" ]; then
            echo "Error: %LOWER%_release_tag is required when deploy_%LOWER% is enabled"
            exit 1
          fi
BLOCK
    done

    # Validate releases (4-step fallback)
    echo "      - name: Validate releases"
    echo "        id: validate"
    echo "        env:"
    cat <<'EOF'
          _GHE_HOST: ${{ secrets.GHE_HOST }}
          GH_TOKEN: ${{ secrets.GHE_TOKEN }}
EOF
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          %UPPER%_UPSTREAM_REPO: ${{ secrets.%UPPER%_UPSTREAM_REPO }}
BLOCK
    done
    echo "        run: |"
    cat <<'EOF'
          [ -n "$_GHE_HOST" ] && export GH_HOST="$_GHE_HOST"
EOF
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          DEPLOY_%UPPER%="${{ inputs.deploy_%LOWER% }}"
BLOCK
    done
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"

          # Validate %NAME% release or tag
          if [ "$DEPLOY_%UPPER%" = "true" ]; then
            %UPPER%_TAG="${{ inputs.%LOWER%_release_tag }}"
            %UPPER%_SOURCE="release"
            echo "Validating %NAME% release ${%UPPER%_TAG} in ${%UPPER%_UPSTREAM_REPO}..."

            # Try exact tag as release first
            RELEASE_INFO=$(gh api "repos/${%UPPER%_UPSTREAM_REPO}/releases/tags/${%UPPER%_TAG}" --jq '.tag_name' 2>&1) || {
              RELEASE_INFO=""
              # Try with 'v' prefix if tag doesn't start with 'v'
              if [[ "${%UPPER%_TAG}" != v* ]]; then
                ALT_TAG="v${%UPPER%_TAG}"
                echo "Release not found, trying ${ALT_TAG}..."
                RELEASE_INFO=$(gh api "repos/${%UPPER%_UPSTREAM_REPO}/releases/tags/${ALT_TAG}" --jq '.tag_name' 2>&1) || RELEASE_INFO=""
              else
                # Try without 'v' prefix
                ALT_TAG="${%UPPER%_TAG#v}"
                echo "Release not found, trying ${ALT_TAG}..."
                RELEASE_INFO=$(gh api "repos/${%UPPER%_UPSTREAM_REPO}/releases/tags/${ALT_TAG}" --jq '.tag_name' 2>&1) || RELEASE_INFO=""
              fi
              # Fall back to searching releases by name
              if [ -z "$RELEASE_INFO" ]; then
                echo "Release variants not found, searching by release name..."
                RELEASE_INFO=$(gh api "repos/${%UPPER%_UPSTREAM_REPO}/releases" --jq ".[] | select(.name == \"${%UPPER%_TAG}\") | .tag_name" 2>&1 | head -1) || RELEASE_INFO=""
              fi
              # Fall back to checking if it exists as a plain git tag
              if [ -z "$RELEASE_INFO" ]; then
                echo "No release found, checking if git tag exists..."
                TAG_CHECK=$(gh api "repos/${%UPPER%_UPSTREAM_REPO}/git/ref/tags/${%UPPER%_TAG}" --jq '.ref' 2>&1) || TAG_CHECK=""
                if [ -z "$TAG_CHECK" ] && [[ "${%UPPER%_TAG}" != v* ]]; then
                  TAG_CHECK=$(gh api "repos/${%UPPER%_UPSTREAM_REPO}/git/ref/tags/v${%UPPER%_TAG}" --jq '.ref' 2>&1) || TAG_CHECK=""
                  [ -n "$TAG_CHECK" ] && %UPPER%_TAG="v${%UPPER%_TAG}"
                elif [ -z "$TAG_CHECK" ] && [[ "${%UPPER%_TAG}" == v* ]]; then
                  TAG_CHECK=$(gh api "repos/${%UPPER%_UPSTREAM_REPO}/git/ref/tags/${%UPPER%_TAG#v}" --jq '.ref' 2>&1) || TAG_CHECK=""
                  [ -n "$TAG_CHECK" ] && %UPPER%_TAG="${%UPPER%_TAG#v}"
                fi
                if [ -n "$TAG_CHECK" ]; then
                  echo "Found as git tag (no release): ${%UPPER%_TAG}"
                  %UPPER%_SOURCE="tag"
                  RELEASE_INFO="${%UPPER%_TAG}"
                fi
              fi
              if [ -z "$RELEASE_INFO" ]; then
                echo "Error: ${%UPPER%_TAG} not found in ${%UPPER%_UPSTREAM_REPO}"
                echo "Tried: release tag, alternate format, release name, and git tag"
                exit 1
              fi
              %UPPER%_TAG="$RELEASE_INFO"
            }
            echo "%NAME% validated: ${%UPPER%_TAG} (source: ${%UPPER%_SOURCE})"

            %UPPER%_VERSION=${%UPPER%_TAG#v}
            %UPPER%_APP_VERSION=${%UPPER%_VERSION//./-}
            echo "%LOWER%_release_tag=${%UPPER%_TAG}" >> "$GITHUB_OUTPUT"
            echo "%LOWER%_version=${%UPPER%_APP_VERSION}" >> "$GITHUB_OUTPUT"
            echo "%LOWER%_version_dotted=${%UPPER%_VERSION}" >> "$GITHUB_OUTPUT"
            echo "%LOWER%_source=${%UPPER%_SOURCE}" >> "$GITHUB_OUTPUT"
          fi
BLOCK
    done
    echo ""
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          echo "deploy_%LOWER%=${DEPLOY_%UPPER%}" >> "$GITHUB_OUTPUT"
BLOCK
    done
}

emit_orchestrator_reusable_call() {
    local job_id="$1"
    local env_name="$2"
    local target_label="$3"
    local needs_clause="$4"

    echo ""
    cat <<EOF
  ${job_id}:
    needs: ${needs_clause}
    uses: ./${REUSABLE_WORKFLOW}
    with:
      environment_name: ${env_name}
      target_label: ${target_label}
EOF
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
      %LOWER%_release_tag: ${{ needs.validate-and-prepare.outputs.%LOWER%_release_tag }}
      %LOWER%_version: ${{ needs.validate-and-prepare.outputs.%LOWER%_version }}
      %LOWER%_version_dotted: ${{ needs.validate-and-prepare.outputs.%LOWER%_version_dotted }}
      %LOWER%_source: ${{ needs.validate-and-prepare.outputs.%LOWER%_source }}
      deploy_%LOWER%: ${{ needs.validate-and-prepare.outputs.deploy_%LOWER% }}
BLOCK
    done
    echo "    secrets: inherit"
}

emit_orchestrator_approve_job() {
    cat <<EOF

  # ──────────────────────────────────────────────────────────────
  # Approval gate: requires manual approval via the 'production'
  # environment. GitHub emails configured reviewers automatically.
  # ──────────────────────────────────────────────────────────────
  approve:
    needs: deploy-nonprod
    runs-on: ${RUNNER}
    environment: production
    steps:
      - name: Approval gate passed
        run: |
          echo "Production deployment approved at \$(date -u)"
          echo "Proceeding to deploy to all production targets"
EOF
}

# ─── Workflow File Generation ────────────────────────────────────

generate_workflows() {
    mkdir -p "$(dirname "$REUSABLE_WORKFLOW")"

    # Generate reusable workflow
    {
        emit_reusable_header
        emit_reusable_permissions
        emit_reusable_deploy_job
    } > "$REUSABLE_WORKFLOW"

    print_success "Reusable workflow: ${BOLD}${REUSABLE_WORKFLOW}${NC}"

    # Generate orchestrator workflow
    {
        emit_orchestrator_header
        emit_orchestrator_permissions
        echo ""
        echo "jobs:"
        emit_orchestrator_validate_job

        # Nonprod call
        emit_orchestrator_reusable_call \
            "deploy-nonprod" \
            "nonprod" \
            "nonprod" \
            "validate-and-prepare"

        # Approval gate
        emit_orchestrator_approve_job

        # Prod target calls (parallel, all depend on approve)
        for t in $(seq 1 $((${#TARGET_LABELS[@]} - 1))); do
            local label="${TARGET_LABELS[$t]}"
            local job_id="deploy-${label}"
            emit_orchestrator_reusable_call \
                "$job_id" \
                "$label" \
                "$label" \
                "[validate-and-prepare, approve]"
        done
    } > "$ORCHESTRATOR_WORKFLOW"

    print_success "Orchestrator workflow: ${BOLD}${ORCHESTRATOR_WORKFLOW}${NC}"
}

# ─── Manifest Generation ────────────────────────────────────────

emit_manifest_file() {
    local app_name="$1"
    cat <<EOF
# Cloud Foundry manifest for ${app_name}
# Generated by multi-target-setup.sh on $(date -u '+%Y-%m-%d')
# Customize this file for your application's requirements.
---
applications:
  - name: ${app_name}
    memory: 1G
    instances: 1
    buildpacks:
      - java_buildpack_offline    # Use java_buildpack for public environments
    env:
      JBP_CONFIG_OPEN_JDK_JRE: '{ jre: { version: 21.+ } }'
      SPRING_PROFILES_ACTIVE: cloud
    health-check-type: http
    health-check-http-endpoint: /actuator/health/liveness
    routes:
      - route: ${app_name}.apps.internal
    # services:
    #   - my-service-instance
EOF
}

emit_manifest_archive() {
    local app_name="$1"
    cat <<EOF
# Cloud Foundry manifest for ${app_name}
# Generated by multi-target-setup.sh on $(date -u '+%Y-%m-%d')
# Customize this file for your application's requirements.
---
applications:
  - name: ${app_name}
    memory: 256M
    instances: 1
    buildpacks:
      - binary_buildpack
    health-check-type: process
    command: "./${app_name} --port \$PORT"    # Update with your binary's actual command
    routes:
      - route: ${app_name}.apps.internal
EOF
}

generate_manifests() {
    local generated=0
    local skipped=0
    local byom=0

    for i in $(seq 0 $((NUM_APPS - 1))); do
        local manifest_path="${APP_BASE_MANIFEST_PATHS[$i]}"
        local app_name="${APP_NAMES[$i]}"
        local deploy_type="${APP_DEPLOY_TYPES[$i]}"

        if [ "${APP_MANIFEST_MODES[$i]}" = "byom" ]; then
            ((byom++))
            continue
        fi

        if [ -f "$manifest_path" ]; then
            print_warning "Skipped: ${manifest_path} (already exists)"
            ((skipped++))
            continue
        fi

        mkdir -p "$(dirname "$manifest_path")"

        if [ "$deploy_type" = "archive" ]; then
            emit_manifest_archive "$app_name" > "$manifest_path"
        else
            emit_manifest_file "$app_name" > "$manifest_path"
        fi

        print_success "Generated: ${BOLD}${manifest_path}${NC}"
        ((generated++))
    done

    if [ "$generated" -gt 0 ] && [ "$skipped" -gt 0 ]; then
        echo -e "  ${DIM}($generated generated, $skipped skipped)${NC}"
    elif [ "$generated" -eq 0 ] && [ "$skipped" -gt 0 ]; then
        echo -e "  ${DIM}(all manifests already exist, none generated)${NC}"
    fi
}

# ─── Debug File ──────────────────────────────────────────────────

save_debug_file() {
    {
        echo "# Multi-Target Deployment Debug File"
        echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Repository: ${REPO}"
        echo "# Platform: ${GITHUB_PLATFORM}"
        echo "# Workflow group: ${WORKFLOW_GROUP}"
        echo "# Reusable workflow: ${REUSABLE_WORKFLOW}"
        echo "# Orchestrator workflow: ${ORCHESTRATOR_WORKFLOW}"
        echo "# Runner: ${RUNNER}"
        echo "# Post-deploy script: ${POST_DEPLOY_SCRIPT:-(not set)}"
        echo "# Approval reviewers: ${APPROVAL_REVIEWERS}"
        echo ""
        echo "# Targets: $(IFS=', '; echo "${TARGET_LABELS[*]}")"
        echo ""

        echo "## GitHub Authentication"
        [ -n "$GHE_HOST" ] && echo "GHE_HOST=${GHE_HOST}"
        echo "GHE_TOKEN=${GHE_TOKEN}"
        echo ""

        echo "## Repo-level secrets (per-app base config)"
        for i in $(seq 0 $((NUM_APPS - 1))); do
            echo ""
            echo "### ${APP_NAMES[$i]} (${APP_UPPERS[$i]}_*)"
            echo "${APP_UPPERS[$i]}_UPSTREAM_REPO=${APP_UPSTREAM_REPOS[$i]}"
            echo "${APP_UPPERS[$i]}_ARTIFACT_PATTERN=${APP_ARTIFACT_PATTERNS[$i]}"
            echo "${APP_UPPERS[$i]}_DEPLOY_TYPE=${APP_DEPLOY_TYPES[$i]}"
            echo "${APP_UPPERS[$i]}_MANIFEST_PATH=${APP_BASE_MANIFEST_PATHS[$i]}"
        done
        echo ""

        echo "## Environment secrets (per-target)"
        for t in $(seq 0 $((${#TARGET_LABELS[@]} - 1))); do
            echo ""
            echo "### Target: ${TARGET_LABELS[$t]}"
            echo "CF_API=${TARGET_CF_APIS[$t]}"
            echo "CF_USERNAME=${TARGET_CF_USERNAMES[$t]}"
            echo "CF_PASSWORD=${TARGET_CF_PASSWORDS[$t]}"
            echo "CF_ORG=${TARGET_CF_ORGS[$t]}"
            echo "CF_SPACE=${TARGET_CF_SPACES[$t]}"
            for i in $(seq 0 $((NUM_APPS - 1))); do
                local idx=$(target_app_idx $t $i)
                echo "${APP_UPPERS[$i]}_NAME=${APP_TARGET_NAMES[$idx]}"
                echo "${APP_UPPERS[$i]}_ROUTE=${APP_TARGET_ROUTES[$idx]}"
                echo "${APP_UPPERS[$i]}_CF_ENV_JSON=${APP_TARGET_CF_ENV_JSONS[$idx]:-(not set)}"
            done
        done
    } > "$DEBUG_FILE"
    print_success "Debug file saved: ${BOLD}${DEBUG_FILE}${NC}"
}

# ─── Config File Support ─────────────────────────────────────────

generate_template() {
    cat <<'TEMPLATE'
# Multi-Target Deployment Configuration
# ──────────────────────────────────────
# Use with: ./multi-target-setup.sh --config <this-file>
#
# Lines starting with # are comments. Empty lines are ignored.
# All values are key=value pairs. Quote values with spaces.

# ── Platform ────────────────────────────────────────
# "github.com" or "ghe"
PLATFORM=github.com
# GHE_HOST=github.mycompany.com    # Only needed for GHE

# ── GitHub Authentication ───────────────────────────
GHE_TOKEN=ghp_your_token_here

# ── Workflow Settings ───────────────────────────────
WORKFLOW_GROUP=mcp-services
RUNNER=ubuntu-latest

# ── Post-Deploy Script (optional) ───────────────────
# Path to a bash script in this repo to run after each target's app deployments.
# The script runs with CF CLI already authenticated to the target foundation.
# Available env vars: TARGET_LABEL, DEPLOYED_APPS (space-separated app names),
# and per-app DEPLOY_{APP}=true/false, {APP}_NAME, {APP}_VERSION.
# POST_DEPLOY_SCRIPT=scripts/post-deploy.sh

# ── Approval Reviewers ──────────────────────────────
APPROVAL_REVIEWERS=user1,user2

# ── Applications ────────────────────────────────────
# Define 1-5 apps. Each app needs APP_N_* keys where N is 1,2,3...
NUM_APPS=3

APP_1_NAME=fetch-mcp
APP_1_UPSTREAM_REPO=org/spring-fetch-mcp
APP_1_ARTIFACT_PATTERN=fetch-mcp-*.jar
APP_1_DEPLOY_TYPE=file
APP_1_MANIFEST_MODE=byom
APP_1_MANIFEST_PATH=manifests/fetch-mcp/manifest.yml

APP_2_NAME=gh-mcp
APP_2_UPSTREAM_REPO=github/github-mcp-server
APP_2_ARTIFACT_PATTERN=github-mcp-server_Linux_x86_64.tar.gz
APP_2_DEPLOY_TYPE=archive
APP_2_MANIFEST_MODE=byom
APP_2_MANIFEST_PATH=manifests/github-mcp/manifest.yml

APP_3_NAME=web-mcp
APP_3_UPSTREAM_REPO=org/web-search-mcp
APP_3_ARTIFACT_PATTERN=web-search-mcp-*.jar
APP_3_DEPLOY_TYPE=file
APP_3_MANIFEST_MODE=byom
APP_3_MANIFEST_PATH=manifests/websearch-mcp/manifest.yml

# ── Nonprod Target ──────────────────────────────────
NONPROD_CF_API=https://api.sys.nonprod.example.com
NONPROD_CF_USERNAME=cf-deployer
NONPROD_CF_PASSWORD=your-password
NONPROD_CF_ORG=my-org
NONPROD_CF_SPACE=nonprod

# Per-app nonprod config: NONPROD_APP_N_*
NONPROD_APP_1_NAME=fetch-dev
NONPROD_APP_1_ROUTE=fetch-dev.apps.internal
# NONPROD_APP_1_CF_ENV_JSON={"KEY":"value"}

NONPROD_APP_2_NAME=gh-mcp-dev
NONPROD_APP_2_ROUTE=gh-mcp-dev.apps.internal
NONPROD_APP_2_CF_ENV_JSON={"GITHUB_PERSONAL_ACCESS_TOKEN":"ghp_xxx"}

NONPROD_APP_3_NAME=web-dev
NONPROD_APP_3_ROUTE=web-dev.apps.internal
NONPROD_APP_3_CF_ENV_JSON={"WEBSEARCH_API_KEY":"xxx"}

# ── Production Targets ──────────────────────────────
# Define 1-10 prod targets. Each target needs PROD_N_* keys.
NUM_PROD_TARGETS=2

# ── Shared Production CF Credentials (optional) ────
# Set SHARED_PROD_CF_CREDS=true to use the same CF API, username, and
# password for all production targets. Each target still needs its own
# label, org, space, and per-app config.
# Per-target PROD_N_CF_API/USERNAME/PASSWORD can still override if needed.
# SHARED_PROD_CF_CREDS=true
# SHARED_PROD_CF_API=https://api.sys.prod.example.com
# SHARED_PROD_CF_USERNAME=cf-deployer
# SHARED_PROD_CF_PASSWORD=your-password

# -- Prod Target 1 --
PROD_1_LABEL=prod-alpha
PROD_1_CF_API=https://api.sys.prod.example.com
PROD_1_CF_USERNAME=cf-deployer
PROD_1_CF_PASSWORD=your-password
PROD_1_CF_ORG=alpha-org
PROD_1_CF_SPACE=prod

PROD_1_APP_1_NAME=fetch-alpha
PROD_1_APP_1_ROUTE=fetch-alpha.apps.internal
# PROD_1_APP_1_CF_ENV_JSON=

PROD_1_APP_2_NAME=gh-mcp-alpha
PROD_1_APP_2_ROUTE=gh-mcp-alpha.apps.internal
PROD_1_APP_2_CF_ENV_JSON={"GITHUB_PERSONAL_ACCESS_TOKEN":"ghp_xxx"}

PROD_1_APP_3_NAME=web-alpha
PROD_1_APP_3_ROUTE=web-alpha.apps.internal
PROD_1_APP_3_CF_ENV_JSON={"WEBSEARCH_API_KEY":"xxx"}

# -- Prod Target 2 --
PROD_2_LABEL=prod-beta
PROD_2_CF_API=https://api.sys.prod.example.com
PROD_2_CF_USERNAME=cf-deployer
PROD_2_CF_PASSWORD=your-password
PROD_2_CF_ORG=beta-org
PROD_2_CF_SPACE=prod

PROD_2_APP_1_NAME=fetch-beta
PROD_2_APP_1_ROUTE=fetch-beta.apps.internal

PROD_2_APP_2_NAME=gh-mcp-beta
PROD_2_APP_2_ROUTE=gh-mcp-beta.apps.internal
PROD_2_APP_2_CF_ENV_JSON={"GITHUB_PERSONAL_ACCESS_TOKEN":"ghp_xxx"}

PROD_2_APP_3_NAME=web-beta
PROD_2_APP_3_ROUTE=web-beta.apps.internal
PROD_2_APP_3_CF_ENV_JSON={"WEBSEARCH_API_KEY":"xxx"}
TEMPLATE
}

load_config_file() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: ${config_file}"
        exit 1
    fi

    print_success "Loading config from: ${BOLD}${config_file}${NC}"

    # Strip comments and blank lines into a cleaned temp file
    local tmpfile
    tmpfile=$(mktemp)
    grep -v '^\s*#' "$config_file" | grep -v '^\s*$' | grep '=' > "$tmpfile" || true

    # Helper: look up a key from the cleaned config file
    # Uses cut -d'=' -f2- to handle values containing '='
    _cfg() {
        local val
        val=$(grep "^${1}=" "$tmpfile" | head -1 | cut -d'=' -f2-)
        # Strip surrounding quotes if present
        val=$(echo "$val" | sed "s/^['\"]//; s/['\"]$//")
        echo "$val"
    }

    # ── Map config values to script variables ──────────

    # Platform
    if [ "$(_cfg PLATFORM)" = "ghe" ]; then
        GITHUB_PLATFORM="ghe"
        GHE_HOST="$(_cfg GHE_HOST)"
    else
        GITHUB_PLATFORM="github.com"
        GHE_HOST=""
    fi
    GHE_TOKEN="$(_cfg GHE_TOKEN)"

    # Workflow settings
    WORKFLOW_GROUP="$(_cfg WORKFLOW_GROUP)"
    RUNNER="$(_cfg RUNNER)"
    RUNNER="${RUNNER:-ubuntu-latest}"
    POST_DEPLOY_SCRIPT="$(_cfg POST_DEPLOY_SCRIPT)"
    APPROVAL_REVIEWERS="$(_cfg APPROVAL_REVIEWERS)"

    if [ -z "$WORKFLOW_GROUP" ]; then
        print_error "WORKFLOW_GROUP is required in config file"
        rm -f "$tmpfile"
        exit 1
    fi

    # Apps
    NUM_APPS="$(_cfg NUM_APPS)"
    NUM_APPS="${NUM_APPS:-0}"
    if [ "$NUM_APPS" -lt 1 ] || [ "$NUM_APPS" -gt 5 ]; then
        print_error "NUM_APPS must be between 1 and 5 (got: ${NUM_APPS})"
        rm -f "$tmpfile"
        exit 1
    fi

    for i in $(seq 1 $NUM_APPS); do
        local idx=$((i - 1))
        APP_NAMES[$idx]="$(_cfg APP_${i}_NAME)"
        APP_UPSTREAM_REPOS[$idx]="$(_cfg APP_${i}_UPSTREAM_REPO)"
        APP_ARTIFACT_PATTERNS[$idx]="$(_cfg APP_${i}_ARTIFACT_PATTERN)"
        local dtype="$(_cfg APP_${i}_DEPLOY_TYPE)"
        APP_DEPLOY_TYPES[$idx]="${dtype:-file}"
        local mmode="$(_cfg APP_${i}_MANIFEST_MODE)"
        APP_MANIFEST_MODES[$idx]="${mmode:-generate}"
        local mpath="$(_cfg APP_${i}_MANIFEST_PATH)"
        APP_BASE_MANIFEST_PATHS[$idx]="${mpath:-manifests/${APP_NAMES[$idx]}/manifest.yml}"

        if [ -z "${APP_NAMES[$idx]}" ]; then
            print_error "APP_${i}_NAME is required"
            rm -f "$tmpfile"
            exit 1
        fi

        # GITHUB_ prefix check
        local prefix_check
        prefix_check=$(echo "${APP_NAMES[$idx]}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
        if [[ "$prefix_check" == GITHUB_* ]]; then
            print_error "App name '${APP_NAMES[$idx]}' produces prefix '${prefix_check}_*' which starts with GITHUB_"
            rm -f "$tmpfile"
            exit 1
        fi
    done

    compute_prefixes
    compute_names

    # Nonprod target
    TARGET_LABELS[0]="nonprod"
    TARGET_CF_APIS[0]="$(_cfg NONPROD_CF_API)"
    TARGET_CF_USERNAMES[0]="$(_cfg NONPROD_CF_USERNAME)"
    TARGET_CF_PASSWORDS[0]="$(_cfg NONPROD_CF_PASSWORD)"
    TARGET_CF_ORGS[0]="$(_cfg NONPROD_CF_ORG)"
    TARGET_CF_SPACES[0]="$(_cfg NONPROD_CF_SPACE)"

    for i in $(seq 1 $NUM_APPS); do
        local idx=$(target_app_idx 0 $((i - 1)))
        local tname="$(_cfg NONPROD_APP_${i}_NAME)"
        APP_TARGET_NAMES[$idx]="${tname:-${APP_NAMES[$((i-1))]}}"
        local troute="$(_cfg NONPROD_APP_${i}_ROUTE)"
        APP_TARGET_ROUTES[$idx]="${troute:-${APP_NAMES[$((i-1))]}.apps.internal}"
        APP_TARGET_CF_ENV_JSONS[$idx]="$(_cfg NONPROD_APP_${i}_CF_ENV_JSON)"
    done

    # Prod targets
    NUM_PROD_TARGETS="$(_cfg NUM_PROD_TARGETS)"
    NUM_PROD_TARGETS="${NUM_PROD_TARGETS:-0}"
    if [ "$NUM_PROD_TARGETS" -lt 1 ] || [ "$NUM_PROD_TARGETS" -gt 10 ]; then
        print_error "NUM_PROD_TARGETS must be between 1 and 10 (got: ${NUM_PROD_TARGETS})"
        rm -f "$tmpfile"
        exit 1
    fi

    # Check for shared prod CF credentials
    local SHARED_PROD_CF_CREDS="$(_cfg SHARED_PROD_CF_CREDS)"
    local SHARED_CF_API="" SHARED_CF_USERNAME="" SHARED_CF_PASSWORD=""
    if [ "$SHARED_PROD_CF_CREDS" = "true" ]; then
        SHARED_CF_API="$(_cfg SHARED_PROD_CF_API)"
        SHARED_CF_USERNAME="$(_cfg SHARED_PROD_CF_USERNAME)"
        SHARED_CF_PASSWORD="$(_cfg SHARED_PROD_CF_PASSWORD)"
        if [ -z "$SHARED_CF_API" ] || [ -z "$SHARED_CF_USERNAME" ] || [ -z "$SHARED_CF_PASSWORD" ]; then
            print_error "SHARED_PROD_CF_CREDS=true but SHARED_PROD_CF_API, SHARED_PROD_CF_USERNAME, or SHARED_PROD_CF_PASSWORD is missing"
            rm -f "$tmpfile"
            exit 1
        fi
        print_success "Using shared CF credentials for all prod targets"
    fi

    for t in $(seq 1 $NUM_PROD_TARGETS); do
        local raw_label="$(_cfg PROD_${t}_LABEL)"
        raw_label="${raw_label:-prod-${t}}"
        TARGET_LABELS[$t]=$(sanitize_label "$raw_label")

        # Validate uniqueness
        for prev in $(seq 0 $((t - 1))); do
            if [ "${TARGET_LABELS[$t]}" = "${TARGET_LABELS[$prev]}" ]; then
                print_error "Duplicate target label: ${TARGET_LABELS[$t]}"
                rm -f "$tmpfile"
                exit 1
            fi
        done

        # Per-target CF creds with shared fallback
        local per_target_api="$(_cfg PROD_${t}_CF_API)"
        local per_target_user="$(_cfg PROD_${t}_CF_USERNAME)"
        local per_target_pass="$(_cfg PROD_${t}_CF_PASSWORD)"
        TARGET_CF_APIS[$t]="${per_target_api:-$SHARED_CF_API}"
        TARGET_CF_USERNAMES[$t]="${per_target_user:-$SHARED_CF_USERNAME}"
        TARGET_CF_PASSWORDS[$t]="${per_target_pass:-$SHARED_CF_PASSWORD}"
        TARGET_CF_ORGS[$t]="$(_cfg PROD_${t}_CF_ORG)"
        TARGET_CF_SPACES[$t]="$(_cfg PROD_${t}_CF_SPACE)"

        for i in $(seq 1 $NUM_APPS); do
            local idx=$(target_app_idx $t $((i - 1)))
            local tname="$(_cfg PROD_${t}_APP_${i}_NAME)"
            APP_TARGET_NAMES[$idx]="${tname:-${APP_NAMES[$((i-1))]}-${TARGET_LABELS[$t]}}"
            local troute="$(_cfg PROD_${t}_APP_${i}_ROUTE)"
            APP_TARGET_ROUTES[$idx]="${troute:-${APP_NAMES[$((i-1))]}.apps.internal}"
            APP_TARGET_CF_ENV_JSONS[$idx]="$(_cfg PROD_${t}_APP_${i}_CF_ENV_JSON)"
        done
    done

    rm -f "$tmpfile"
    print_success "Config loaded: ${NUM_APPS} apps, $((NUM_PROD_TARGETS + 1)) targets"
}

# ─── Main ────────────────────────────────────────────────────────

main() {
    # Parse command-line arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"
                NON_INTERACTIVE=true
                shift 2
                ;;
            --generate-template)
                generate_template
                exit 0
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --config <file>       Load configuration from a file (non-interactive)"
                echo "  --generate-template   Print a template config file to stdout"
                echo "  --help, -h            Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0                              # Interactive mode"
                echo "  $0 --generate-template > my.env # Create a template config"
                echo "  $0 --config my.env              # Run from config file"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
    done

    clear 2>/dev/null || true

    print_header "Multi-Target Deployment Setup"

    check_gh_cli

    if [ "$NON_INTERACTIVE" = true ]; then
        # ── Non-interactive mode: load from config file ──
        load_config_file "$CONFIG_FILE"

        # Show review
        echo ""
        print_header "Configuration Summary"

        echo -e "${BOLD}Workflow group:${NC} ${CYAN}${WORKFLOW_GROUP}${NC}"
        echo -e "${BOLD}Runner:${NC} ${CYAN}${RUNNER}${NC}"
        echo -e "${BOLD}Post-deploy script:${NC} ${CYAN}${POST_DEPLOY_SCRIPT:-(none)}${NC}"
        echo ""

        echo -e "${BOLD}Apps (${NUM_APPS}):${NC}"
        for i in $(seq 0 $((NUM_APPS - 1))); do
            echo -e "  ${CYAN}${APP_NAMES[$i]}${NC} (${APP_DEPLOY_TYPES[$i]})"
        done
        echo ""

        echo -e "${BOLD}Targets (${#TARGET_LABELS[@]}):${NC}"
        for t in $(seq 0 $((${#TARGET_LABELS[@]} - 1))); do
            echo -e "  ${CYAN}${TARGET_LABELS[$t]}${NC} → ${TARGET_CF_APIS[$t]} (${TARGET_CF_ORGS[$t]}/${TARGET_CF_SPACES[$t]})"
        done
        echo ""

        # Generate + set secrets without prompting for confirmation
        print_header "Generating Workflows & Manifests"
        generate_workflows
        generate_manifests

    else
        # ── Interactive mode ──

    echo ""
    choose_platform

    # Workflow group name
    echo ""
    echo -e "${BOLD}Workflow group name${NC}"
    echo -e "  ${DIM}A short name for the workflow files and deployment group.${NC}"
    echo -e "  ${DIM}Examples: 'mcp-services', 'team-alpha', 'platform-apis'${NC}"
    echo ""
    prompt_value "Group name" ""
    WORKFLOW_GROUP="$REPLY"
    if [ -z "$WORKFLOW_GROUP" ]; then
        print_error "Group name is required."
        exit 1
    fi

    # Runner label
    echo ""
    echo -e "${BOLD}GitHub Actions runner label${NC}"
    echo -e "  ${DIM}Use 'ubuntu-latest' for github.com hosted runners,${NC}"
    echo -e "  ${DIM}or specify your self-hosted runner label for GHES.${NC}"
    echo ""
    prompt_value "Runner" "ubuntu-latest"
    RUNNER="$REPLY"

    # Number of apps
    echo ""
    echo -e "${BOLD}How many applications in this deployment pack?${NC}"
    echo -e "  ${DIM}Max 5 (workflow_dispatch input limit)${NC}"
    read -p "Enter number of apps [1-5]: " NUM_APPS

    if ! [[ "$NUM_APPS" =~ ^[0-9]+$ ]] || [ "$NUM_APPS" -lt 1 ] || [ "$NUM_APPS" -gt 5 ]; then
        print_error "Invalid number. Must be between 1 and 5."
        exit 1
    fi

    # Collect per-app base config
    print_header "Application Base Configuration"

    echo "These settings are shared across all deployment targets."
    echo ""

    for i in $(seq 0 $((NUM_APPS - 1))); do
        print_subheader "Application $((i+1))"
        prompt_value "App name" "fetch-mcp"
        APP_NAMES[$i]="$REPLY"

        # Validate: GitHub Actions forbids secrets starting with GITHUB_
        local prefix_check
        prefix_check=$(echo "${APP_NAMES[$i]}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
        if [[ "$prefix_check" == GITHUB_* ]]; then
            print_error "App name '${APP_NAMES[$i]}' produces prefix '${prefix_check}_*' which starts with GITHUB_"
            echo -e "  ${DIM}GitHub Actions does not allow secrets starting with GITHUB_${NC}"
            echo -e "  ${DIM}Choose a different name (e.g., 'gh-mcp' instead of 'github-mcp')${NC}"
            exit 1
        fi

        prompt_value "Upstream repo" "org/my-api"
        APP_UPSTREAM_REPOS[$i]="$REPLY"
        prompt_value "Artifact pattern" "${APP_NAMES[$i]}-*.jar"
        APP_ARTIFACT_PATTERNS[$i]="$REPLY"

        echo ""
        echo -e "  ${BOLD}Deploy type:${NC}"
        echo -e "    ${BOLD}1)${NC} file    — Push the downloaded artifact directly (JAR, WAR, ZIP)"
        echo -e "    ${BOLD}2)${NC} archive — Extract tar.gz/zip first, then push the extracted directory"
        echo ""
        read -p "  Choose deploy type [1]: " deploy_type_choice
        case "$deploy_type_choice" in
            2) APP_DEPLOY_TYPES[$i]="archive" ;;
            *) APP_DEPLOY_TYPES[$i]="file" ;;
        esac

        echo ""
        echo -e "  ${BOLD}CF Manifest:${NC}"
        echo -e "    ${BOLD}1)${NC} Generate — Auto-generate a starter manifest (${APP_DEPLOY_TYPES[$i]} template)"
        echo -e "    ${BOLD}2)${NC} Bring your own — Provide path to an existing manifest"
        echo ""
        local manifest_choice
        read -p "  Choose manifest mode [1]: " manifest_choice
        if [ "$manifest_choice" = "2" ]; then
            APP_MANIFEST_MODES[$i]="byom"
            prompt_value "Manifest path" "manifests/${APP_NAMES[$i]}/manifest.yml"
            APP_BASE_MANIFEST_PATHS[$i]="$REPLY"
        else
            APP_MANIFEST_MODES[$i]="generate"
            APP_BASE_MANIFEST_PATHS[$i]="manifests/${APP_NAMES[$i]}/manifest.yml"
        fi
    done

    compute_prefixes
    compute_names

    # ── Nonprod target ──────────────────────────────────────────
    print_header "Nonprod Target Configuration"

    TARGET_LABELS[0]="nonprod"

    print_subheader "Nonprod CF Credentials"
    prompt_value "CF API endpoint" "https://api.sys.nonprod.example.com"
    TARGET_CF_APIS[0]="$REPLY"
    prompt_value "CF username" "cf-deployer"
    TARGET_CF_USERNAMES[0]="$REPLY"
    prompt_hidden "CF password"
    TARGET_CF_PASSWORDS[0]="$REPLY"
    prompt_value "CF org" "my-org"
    TARGET_CF_ORGS[0]="$REPLY"
    prompt_value "CF space" "nonprod"
    TARGET_CF_SPACES[0]="$REPLY"

    print_subheader "Nonprod App Configuration"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        local idx=$(target_app_idx 0 $i)
        echo -e "  ${BOLD}${APP_NAMES[$i]}:${NC}"
        prompt_value "  App name for nonprod" "${APP_NAMES[$i]}-dev"
        APP_TARGET_NAMES[$idx]="$REPLY"
        prompt_value "  Nonprod route" "${APP_NAMES[$i]}.apps-nonprod.internal"
        APP_TARGET_ROUTES[$idx]="$REPLY"
        echo -e "  ${DIM}Optional: JSON env vars for cf set-env (leave empty if not needed)${NC}"
        prompt_hidden "  CF_ENV_JSON (optional)"
        APP_TARGET_CF_ENV_JSONS[$idx]="$REPLY"
    done

    # ── Prod targets ────────────────────────────────────────────
    print_header "Production Target Configuration"

    echo -e "${BOLD}How many production targets (BUs/LOBs)?${NC}"
    echo -e "  ${DIM}Each target gets its own CF credentials, app names, and routes.${NC}"
    echo -e "  ${DIM}All targets deploy in parallel after a single approval.${NC}"
    echo ""
    read -p "Enter number of prod targets [1-10]: " NUM_PROD_TARGETS

    if ! [[ "$NUM_PROD_TARGETS" =~ ^[0-9]+$ ]] || [ "$NUM_PROD_TARGETS" -lt 1 ] || [ "$NUM_PROD_TARGETS" -gt 10 ]; then
        print_error "Invalid number. Must be between 1 and 10."
        exit 1
    fi

    # Ask if all prod targets share the same CF API/credentials
    local SHARED_PROD_CF_CREDS=false
    local SHARED_CF_API="" SHARED_CF_USERNAME="" SHARED_CF_PASSWORD=""
    if [ "$NUM_PROD_TARGETS" -gt 1 ]; then
        echo ""
        echo -e "  ${BOLD}Do all prod targets use the same CF API endpoint and credentials?${NC}"
        echo -e "  ${DIM}If yes, you'll enter CF API/username/password once and they'll be reused.${NC}"
        echo -e "  ${DIM}You'll still configure org, space, and app settings per target.${NC}"
        echo ""
        read -p "  Share CF credentials across all prod targets? [y/N]: " share_reply
        if [[ "$share_reply" =~ ^[Yy]$ ]]; then
            SHARED_PROD_CF_CREDS=true
            print_subheader "Shared Production CF Credentials"
            prompt_value "CF API endpoint" "https://api.sys.prod.example.com"
            SHARED_CF_API="$REPLY"
            prompt_value "CF username" "cf-deployer"
            SHARED_CF_USERNAME="$REPLY"
            prompt_hidden "CF password"
            SHARED_CF_PASSWORD="$REPLY"
        fi
    fi

    for t in $(seq 1 $NUM_PROD_TARGETS); do
        print_subheader "Production Target $t"
        prompt_value "Target label" "prod-bu-$t"
        local raw_label="$REPLY"
        TARGET_LABELS[$t]=$(sanitize_label "$raw_label")

        # Validate uniqueness
        for prev in $(seq 0 $((t - 1))); do
            if [ "${TARGET_LABELS[$t]}" = "${TARGET_LABELS[$prev]}" ]; then
                print_error "Duplicate target label: ${TARGET_LABELS[$t]}"
                exit 1
            fi
        done

        echo -e "  ${DIM}Target: ${TARGET_LABELS[$t]}${NC}"
        echo ""

        if [ "$SHARED_PROD_CF_CREDS" = true ]; then
            TARGET_CF_APIS[$t]="$SHARED_CF_API"
            TARGET_CF_USERNAMES[$t]="$SHARED_CF_USERNAME"
            TARGET_CF_PASSWORDS[$t]="$SHARED_CF_PASSWORD"
            print_success "Using shared CF credentials (API: ${SHARED_CF_API})"
        else
            print_subheader "${TARGET_LABELS[$t]} CF Credentials"
            prompt_value "CF API endpoint" "https://api.sys.prod.example.com"
            TARGET_CF_APIS[$t]="$REPLY"
            prompt_value "CF username" "cf-deployer"
            TARGET_CF_USERNAMES[$t]="$REPLY"
            prompt_hidden "CF password"
            TARGET_CF_PASSWORDS[$t]="$REPLY"
        fi
        prompt_value "CF org" "my-org"
        TARGET_CF_ORGS[$t]="$REPLY"
        prompt_value "CF space" "prod"
        TARGET_CF_SPACES[$t]="$REPLY"

        echo ""
        echo -e "  ${BOLD}App configuration for ${TARGET_LABELS[$t]}:${NC}"
        for i in $(seq 0 $((NUM_APPS - 1))); do
            local idx=$(target_app_idx $t $i)
            echo ""
            echo -e "  ${BOLD}${APP_NAMES[$i]}:${NC}"
            prompt_value "  App name for ${TARGET_LABELS[$t]}" "${APP_NAMES[$i]}-${TARGET_LABELS[$t]}"
            APP_TARGET_NAMES[$idx]="$REPLY"
            prompt_value "  Route for ${TARGET_LABELS[$t]}" "${APP_NAMES[$i]}.apps-${TARGET_LABELS[$t]}.internal"
            APP_TARGET_ROUTES[$idx]="$REPLY"
            echo -e "  ${DIM}Optional: JSON env vars for cf set-env (leave empty if not needed)${NC}"
            prompt_hidden "  CF_ENV_JSON (optional)"
            APP_TARGET_CF_ENV_JSONS[$idx]="$REPLY"
        done
    done

    # ── Post-deploy script ──────────────────────────────────────
    print_header "Post-Deploy Script (Optional)"

    echo -e "  ${DIM}Optionally specify a bash script in this repo to run after each target's deployments.${NC}"
    echo -e "  ${DIM}The script runs with CF CLI authenticated. Available env vars:${NC}"
    echo -e "  ${DIM}  TARGET_LABEL, DEPLOYED_APPS (space-separated), per-app {APP}_NAME and {APP}_VERSION${NC}"
    echo -e "  ${DIM}Leave empty to skip.${NC}"
    echo ""
    prompt_value "Post-deploy script path" "scripts/post-deploy.sh"
    POST_DEPLOY_SCRIPT="$REPLY"

    # ── GitHub auth ─────────────────────────────────────────────
    print_header "GitHub Authentication"

    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        prompt_value "GHE_HOST" "github.mycompany.com"
        GHE_HOST="$REPLY"
        prompt_hidden "GHE_TOKEN"
        GHE_TOKEN="$REPLY"
    else
        echo -e "  ${DIM}A Personal Access Token with 'repo' scope is required${NC}"
        echo -e "  ${DIM}to download release assets from the upstream repositories.${NC}"
        echo ""
        prompt_hidden "GHE_TOKEN"
        GHE_TOKEN="$REPLY"
    fi

    # ── Approval reviewers ──────────────────────────────────────
    print_subheader "Approval Gate"
    prompt_value "APPROVAL_REVIEWERS" "user1,user2"
    APPROVAL_REVIEWERS="$REPLY"

    # ── Review ──────────────────────────────────────────────────
    print_header "Review Your Configuration"

    echo -e "${BOLD}Workflow group:${NC} ${CYAN}${WORKFLOW_GROUP}${NC}"
    echo -e "${BOLD}Runner:${NC} ${CYAN}${RUNNER}${NC}"
    echo -e "${BOLD}Reusable workflow:${NC} ${CYAN}${REUSABLE_WORKFLOW}${NC}"
    echo -e "${BOLD}Orchestrator workflow:${NC} ${CYAN}${ORCHESTRATOR_WORKFLOW}${NC}"
    echo -e "${BOLD}Post-deploy script:${NC} ${CYAN}${POST_DEPLOY_SCRIPT:-(none)}${NC}"
    echo ""

    echo -e "${BOLD}Apps (${NUM_APPS}):${NC}"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        echo -e "  ${CYAN}${APP_NAMES[$i]}${NC} (${APP_DEPLOY_TYPES[$i]}, prefix: ${APP_UPPERS[$i]}_*)"
        echo -e "    Upstream: ${APP_UPSTREAM_REPOS[$i]}"
        echo -e "    Artifact: ${APP_ARTIFACT_PATTERNS[$i]}"
        echo -e "    Manifest: ${APP_BASE_MANIFEST_PATHS[$i]}"
    done
    echo ""

    echo -e "${BOLD}Targets (${#TARGET_LABELS[@]}):${NC}"
    for t in $(seq 0 $((${#TARGET_LABELS[@]} - 1))); do
        echo ""
        echo -e "  ${CYAN}${TARGET_LABELS[$t]}${NC}"
        echo -e "    CF: ${TARGET_CF_APIS[$t]} → ${TARGET_CF_ORGS[$t]}/${TARGET_CF_SPACES[$t]}"
        for i in $(seq 0 $((NUM_APPS - 1))); do
            local idx=$(target_app_idx $t $i)
            echo -e "    ${APP_NAMES[$i]}: name=${APP_TARGET_NAMES[$idx]}, route=${APP_TARGET_ROUTES[$idx]}"
        done
    done
    echo ""

    echo -e "${BOLD}Approval reviewers:${NC} ${APPROVAL_REVIEWERS}"
    echo ""

    read -p "Generate workflows, create environments, and set secrets? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        print_warning "Cancelled. No changes were made."
        exit 0
    fi

    # ── Generate ────────────────────────────────────────────────
    print_header "Generating Workflows & Manifests"
    generate_workflows
    generate_manifests

    fi  # end interactive/non-interactive branch

    # ── Create environments & set secrets ───────────────────────
    print_header "Creating GitHub Environments"

    for t in $(seq 0 $((${#TARGET_LABELS[@]} - 1))); do
        create_environment "${TARGET_LABELS[$t]}"
    done
    create_environment "production"

    print_header "Setting Repo-Level Secrets"

    local success_count=0

    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        set_secret "GHE_HOST" "$GHE_HOST" && ((success_count++)) || true
    fi
    set_secret "GHE_TOKEN" "$GHE_TOKEN" && ((success_count++)) || true

    for i in $(seq 0 $((NUM_APPS - 1))); do
        set_secret "${APP_UPPERS[$i]}_UPSTREAM_REPO" "${APP_UPSTREAM_REPOS[$i]}" && ((success_count++)) || true
        set_secret "${APP_UPPERS[$i]}_ARTIFACT_PATTERN" "${APP_ARTIFACT_PATTERNS[$i]}" && ((success_count++)) || true
        set_secret "${APP_UPPERS[$i]}_DEPLOY_TYPE" "${APP_DEPLOY_TYPES[$i]}" && ((success_count++)) || true
        set_secret "${APP_UPPERS[$i]}_MANIFEST_PATH" "${APP_BASE_MANIFEST_PATHS[$i]}" && ((success_count++)) || true
    done

    if [ -n "$POST_DEPLOY_SCRIPT" ]; then
        set_secret "POST_DEPLOY_SCRIPT" "$POST_DEPLOY_SCRIPT" && ((success_count++)) || true
    fi
    set_secret "APPROVAL_REVIEWERS" "$APPROVAL_REVIEWERS" && ((success_count++)) || true

    print_header "Setting Environment Secrets"

    for t in $(seq 0 $((${#TARGET_LABELS[@]} - 1))); do
        local env="${TARGET_LABELS[$t]}"
        print_subheader "Environment: ${env}"

        set_env_secret "$env" "CF_API" "${TARGET_CF_APIS[$t]}" && ((success_count++)) || true
        set_env_secret "$env" "CF_USERNAME" "${TARGET_CF_USERNAMES[$t]}" && ((success_count++)) || true
        set_env_secret "$env" "CF_PASSWORD" "${TARGET_CF_PASSWORDS[$t]}" && ((success_count++)) || true
        set_env_secret "$env" "CF_ORG" "${TARGET_CF_ORGS[$t]}" && ((success_count++)) || true
        set_env_secret "$env" "CF_SPACE" "${TARGET_CF_SPACES[$t]}" && ((success_count++)) || true

        for i in $(seq 0 $((NUM_APPS - 1))); do
            local idx=$(target_app_idx $t $i)
            set_env_secret "$env" "${APP_UPPERS[$i]}_NAME" "${APP_TARGET_NAMES[$idx]}" && ((success_count++)) || true
            set_env_secret "$env" "${APP_UPPERS[$i]}_ROUTE" "${APP_TARGET_ROUTES[$idx]}" && ((success_count++)) || true
            set_env_secret "$env" "${APP_UPPERS[$i]}_CF_ENV_JSON" "${APP_TARGET_CF_ENV_JSONS[$idx]}" && ((success_count++)) || true
        done
    done

    echo ""
    print_success "Secrets configured! ($success_count total)"

    # ── Production reviewers ────────────────────────────────────
    print_header "Configuring Production Approval Gate"
    setup_production_reviewers "$APPROVAL_REVIEWERS"

    # ── Debug file ──────────────────────────────────────────────
    save_debug_file

    # ── Done ────────────────────────────────────────────────────
    print_header "Setup Complete"

    echo -e "${BOLD}Generated files:${NC}"
    echo -e "  ${CYAN}${REUSABLE_WORKFLOW}${NC}  (reusable deploy logic)"
    echo -e "  ${CYAN}${ORCHESTRATOR_WORKFLOW}${NC}  (trigger + fan-out)"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        if [ -f "${APP_BASE_MANIFEST_PATHS[$i]}" ]; then
            echo -e "  ${CYAN}${APP_BASE_MANIFEST_PATHS[$i]}${NC}"
        fi
    done
    echo ""

    echo -e "${BOLD}GitHub Environments created:${NC}"
    for t in $(seq 0 $((${#TARGET_LABELS[@]} - 1))); do
        echo -e "  ${CYAN}${TARGET_LABELS[$t]}${NC}"
    done
    echo -e "  ${CYAN}production${NC}  (approval gate)"
    echo ""

    echo -e "${BOLD}Pipeline flow:${NC}"
    echo -e "  ${DIM}validate → deploy-nonprod → approve →${NC}"
    for t in $(seq 1 $((${#TARGET_LABELS[@]} - 1))); do
        echo -e "  ${DIM}  → deploy-${TARGET_LABELS[$t]} (parallel)${NC}"
    done
    echo ""

    echo -e "${BOLD}Next steps:${NC}"
    echo ""

    local git_add_paths="${REUSABLE_WORKFLOW} ${ORCHESTRATOR_WORKFLOW}"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        git_add_paths="${git_add_paths} ${APP_BASE_MANIFEST_PATHS[$i]}"
    done

    echo "1. Review and commit the generated files:"
    echo -e "   ${DIM}git add ${git_add_paths}${NC}"
    echo -e "   ${DIM}git commit -m \"Add multi-target deployment workflows\"${NC}"
    echo -e "   ${DIM}git push${NC}"
    echo ""
    echo "2. Verify the production approval gate:"
    echo -e "   ${DIM}Settings > Environments > production > Required reviewers${NC}"
    echo ""
    echo "3. Trigger a deployment:"
    echo -e "   ${DIM}Actions > ${WORKFLOW_GROUP} - Orchestrator > Run workflow${NC}"
    echo ""
    if [ -n "$POST_DEPLOY_SCRIPT" ]; then
        echo "4. Create your post-deploy script:"
        echo -e "   ${DIM}${POST_DEPLOY_SCRIPT}${NC}"
        echo -e "   ${DIM}It receives the target label as \$1 (e.g., 'nonprod', 'prod-alpha')${NC}"
        echo ""
    fi
    echo -e "${DIM}Debug file: ${DEBUG_FILE}${NC}"
    echo ""
}

main "$@"
