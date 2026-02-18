#!/bin/bash
#
# Setup GitHub secrets and generate a deployment workflow for N applications.
# Each run creates a new workflow YAML with app-specific names and secret references.
#
# Works with both GitHub Enterprise Server and github.com
# Requires: gh CLI authenticated with repo access
#

set -e

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

check_shared_secrets() {
    echo ""
    echo "Shared secrets (GitHub auth, CF credentials, approval reviewers)"
    echo "are used by all deployment workflows in this repo."
    echo ""
    echo -e "  ${BOLD}1)${NC} Configure all secrets (shared + app-specific)"
    echo -e "  ${BOLD}2)${NC} App-specific secrets only (shared already configured)"
    echo ""

    read -p "Enter choice [1-2]: " shared_choice

    case $shared_choice in
        1)
            CONFIGURE_SHARED="true"
            ;;
        2)
            CONFIGURE_SHARED="false"
            ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
}

# ─── App Data Arrays ────────────────────────────────────────────

NUM_APPS=0
APP_NAMES=()
APP_UPPERS=()
APP_LOWERS=()
APP_UPSTREAM_REPOS=()
APP_MANIFEST_PATHS=()
APP_ARTIFACT_PATTERNS=()
APP_CF_ENV_JSONS=()
APP_DEPLOY_TYPES=()

RUNNER=""
WORKFLOW_SLUG=""
DISPLAY_NAME=""
GENERATED_WORKFLOW=""
DEBUG_FILE=""

compute_prefixes() {
    for i in $(seq 0 $((NUM_APPS - 1))); do
        APP_UPPERS[$i]=$(echo "${APP_NAMES[$i]}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
        APP_LOWERS[$i]=$(echo "${APP_NAMES[$i]}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    done
}

compute_names() {
    WORKFLOW_SLUG=""
    DISPLAY_NAME="Deploy"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        [ $i -gt 0 ] && WORKFLOW_SLUG="${WORKFLOW_SLUG}-"
        WORKFLOW_SLUG="${WORKFLOW_SLUG}${APP_NAMES[$i]}"
        [ $i -gt 0 ] && DISPLAY_NAME="${DISPLAY_NAME} &"
        DISPLAY_NAME="${DISPLAY_NAME} ${APP_NAMES[$i]}"
    done
    DISPLAY_NAME="${DISPLAY_NAME} to Cloud Foundry"
    GENERATED_WORKFLOW=".github/workflows/deploy-${WORKFLOW_SLUG}.yml"
    DEBUG_FILE=".multi-app-secrets-debug-${WORKFLOW_SLUG}.txt"
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

emit_header() {
    echo "# AUTO-GENERATED by multi-app-setup-secrets.sh"
    echo "# Generated on $(date -u '+%Y-%m-%d')"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        echo "# App $((i+1)): ${APP_NAMES[$i]} (secrets prefix: ${APP_UPPERS[$i]}_*)"
    done
    echo "#"
    echo "name: ${DISPLAY_NAME}"
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

emit_permissions_and_env() {
    cat <<'EOF'

permissions:
  contents: write
  actions: read
  deployments: write

env:
  CF_CLI_VERSION: "v8"
EOF
}

emit_gh_auth_step() {
    cat <<'EOF'
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
}

emit_git_push_auth_step() {
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
}

emit_validate_job() {
    cat <<EOF
  # ──────────────────────────────────────────────────────────────
  # Job 1: Validate releases and prepare artifacts
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
          %UPPER%_NAME: ${{ secrets.%UPPER%_NAME }}
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
          echo "%NAME% (%LOWER%_release_tag):  ${%UPPER%_NAME}"
          echo "  Upstream repo:           ${%UPPER%_UPSTREAM_REPO}"
          echo "  Deploy:                  ${{ inputs.deploy_%LOWER% }}"
          echo "  Release tag:             ${{ inputs.%LOWER%_release_tag }}"
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

    # Validate releases
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

          # Validate %NAME% release
          if [ "$DEPLOY_%UPPER%" = "true" ]; then
            %UPPER%_TAG="${{ inputs.%LOWER%_release_tag }}"
            echo "Validating %NAME% release ${%UPPER%_TAG} in ${%UPPER%_UPSTREAM_REPO}..."
            RELEASE_INFO=$(gh api "repos/${%UPPER%_UPSTREAM_REPO}/releases/tags/${%UPPER%_TAG}" --jq '.tag_name' 2>&1) || {
              echo "Error: Release ${%UPPER%_TAG} not found in ${%UPPER%_UPSTREAM_REPO}"
              echo "API response: ${RELEASE_INFO}"
              exit 1
            }
            echo "%NAME% release validated: ${RELEASE_INFO}"

            %UPPER%_VERSION=${%UPPER%_TAG#v}
            %UPPER%_APP_VERSION=${%UPPER%_VERSION//./-}
            echo "%LOWER%_release_tag=${%UPPER%_TAG}" >> "$GITHUB_OUTPUT"
            echo "%LOWER%_version=${%UPPER%_APP_VERSION}" >> "$GITHUB_OUTPUT"
            echo "%LOWER%_version_dotted=${%UPPER%_VERSION}" >> "$GITHUB_OUTPUT"
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

emit_deploy_job() {
    local env_name="$1"
    local env_upper env_label

    if [ "$env_name" = "nonprod" ]; then
        env_upper="NONPROD"
        env_label="Nonprod"
    else
        env_upper="PROD"
        env_label="Prod"
    fi

    echo ""
    if [ "$env_name" = "nonprod" ]; then
        cat <<EOF
  # ──────────────────────────────────────────────────────────────
  # Job 2: Deploy apps to Non-Production
  # ──────────────────────────────────────────────────────────────
  deploy-nonprod:
    needs: validate-and-prepare
    runs-on: ${RUNNER}
    steps:
      - uses: actions/checkout@v4
EOF
    else
        cat <<EOF
  # ──────────────────────────────────────────────────────────────
  # Job 4: Deploy apps to Production
  #
  # Gated by the 'production' environment which requires manual
  # approval. GitHub sends email to configured reviewers asking
  # them to approve or reject the deployment.
  #
  # To configure the approval gate:
  #   1. Go to Settings > Environments > New environment > "production"
  #   2. Enable "Required reviewers"
  #   3. Add the users/teams who should approve prod deployments
  #   4. GitHub will email those reviewers when this job is reached
  # ──────────────────────────────────────────────────────────────
  deploy-prod:
    needs: [validate-and-prepare, deploy-nonprod]
    runs-on: ${RUNNER}
    environment: production
    steps:
      - uses: actions/checkout@v4
EOF
    fi

    # Install CF CLI
    cat <<'EOF'

      - name: Install CF CLI
        run: |
          curl -sL "https://packages.cloudfoundry.org/stable?release=linux64-binary&version=${{ env.CF_CLI_VERSION }}&source=github" | tar -zx
          chmod +x cf8
EOF

    # Authenticate to CF
    echo ""
    cat <<CFAUTH_DELIM | sed -e "s|%ENV_UPPER%|${env_upper}|g" -e "s|%ENV_LABEL%|${env_label}|g"
      - name: Authenticate to %ENV_LABEL% CF
        env:
          CF_API: \${{ secrets.CF_%ENV_UPPER%_API }}
          CF_USER: \${{ secrets.CF_%ENV_UPPER%_USERNAME }}
          CF_PASS: \${{ secrets.CF_%ENV_UPPER%_PASSWORD }}
          CF_ORG: \${{ secrets.CF_%ENV_UPPER%_ORG }}
          CF_SPACE: \${{ secrets.CF_%ENV_UPPER%_SPACE }}
        run: |
          ./cf8 api "\$CF_API"
          ./cf8 auth "\$CF_USER" "\$CF_PASS"
          ./cf8 target -o "\$CF_ORG" -s "\$CF_SPACE"
          echo "Authenticated to %ENV_LABEL% CF: \${CF_API}"
CFAUTH_DELIM

    echo ""
    emit_gh_auth_step

    # Per-app download and deploy steps
    for i in $(seq 0 $((NUM_APPS - 1))); do
        echo ""
        if [ "${APP_DEPLOY_TYPES[$i]}" = "archive" ]; then
            # ── Archive mode: download, extract, push directory ──
            cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}" "$env_name" "$env_upper" "$env_label"
      - name: Download and extract %NAME% release assets
        if: needs.validate-and-prepare.outputs.deploy_%LOWER% == 'true'
        env:
          _GHE_HOST: ${{ secrets.GHE_HOST }}
          GH_TOKEN: ${{ secrets.GHE_TOKEN }}
          UPSTREAM_REPO: ${{ secrets.%UPPER%_UPSTREAM_REPO }}
          ARTIFACT_PATTERN: ${{ secrets.%UPPER%_ARTIFACT_PATTERN }}
          %UPPER%_MANIFEST: ${{ secrets.%UPPER%_MANIFEST_PATH }}
        run: |
          [ -n "$_GHE_HOST" ] && export GH_HOST="$_GHE_HOST"
          VERSION_DOTTED="${{ needs.validate-and-prepare.outputs.%LOWER%_version_dotted }}"

          PATTERN=$(echo "${ARTIFACT_PATTERN}" | sed "s/{version}/${VERSION_DOTTED}/g")
          echo "Downloading %NAME% artifact matching: ${PATTERN}"

          mkdir -p ./%LOWER%
          gh release download "${{ needs.validate-and-prepare.outputs.%LOWER%_release_tag }}" \
            --repo "${UPSTREAM_REPO}" \
            --pattern "${PATTERN}" \
            --dir ./%LOWER%

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
            cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}" "$env_name" "$env_upper" "$env_label"
      - name: Deploy %NAME% to %ENV_LABEL%
        if: needs.validate-and-prepare.outputs.deploy_%LOWER% == 'true'
        env:
          %UPPER%_NAME: ${{ secrets.%UPPER%_NAME }}
          VERSION: ${{ needs.validate-and-prepare.outputs.%LOWER%_version }}
          %UPPER%_CF_ENV_JSON: ${{ secrets.%UPPER%_CF_ENV_JSON }}
        run: |
          DEPLOY_NAME="${%UPPER%_NAME}-%ENV%-${VERSION}"
          echo "Deploying ${DEPLOY_NAME} from extracted directory..."

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

          echo "%NAME% deployed to %ENV%: ${DEPLOY_NAME}"
BLOCK
        else
            # ── File mode: download artifact, push directly ──
            cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}" "$env_name" "$env_upper" "$env_label"
      - name: Download %NAME% release assets
        if: needs.validate-and-prepare.outputs.deploy_%LOWER% == 'true'
        env:
          _GHE_HOST: ${{ secrets.GHE_HOST }}
          GH_TOKEN: ${{ secrets.GHE_TOKEN }}
          UPSTREAM_REPO: ${{ secrets.%UPPER%_UPSTREAM_REPO }}
          ARTIFACT_PATTERN: ${{ secrets.%UPPER%_ARTIFACT_PATTERN }}
          %UPPER%_MANIFEST: ${{ secrets.%UPPER%_MANIFEST_PATH }}
        run: |
          [ -n "$_GHE_HOST" ] && export GH_HOST="$_GHE_HOST"
          VERSION_DOTTED="${{ needs.validate-and-prepare.outputs.%LOWER%_version_dotted }}"

          PATTERN=$(echo "${ARTIFACT_PATTERN}" | sed "s/{version}/${VERSION_DOTTED}/g")
          echo "Downloading %NAME% artifact matching: ${PATTERN}"

          mkdir -p ./%LOWER%
          gh release download "${{ needs.validate-and-prepare.outputs.%LOWER%_release_tag }}" \
            --repo "${UPSTREAM_REPO}" \
            --pattern "${PATTERN}" \
            --dir ./%LOWER%

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
            cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}" "$env_name" "$env_upper" "$env_label"
      - name: Deploy %NAME% to %ENV_LABEL%
        if: needs.validate-and-prepare.outputs.deploy_%LOWER% == 'true'
        env:
          %UPPER%_NAME: ${{ secrets.%UPPER%_NAME }}
          VERSION: ${{ needs.validate-and-prepare.outputs.%LOWER%_version }}
          %UPPER%_CF_ENV_JSON: ${{ secrets.%UPPER%_CF_ENV_JSON }}
        run: |
          DEPLOY_NAME="${%UPPER%_NAME}-%ENV%-${VERSION}"
          ARTIFACT=$(ls ./%LOWER%/ | grep -v manifest.yml | head -1)
          echo "Artifact found: ${ARTIFACT}"

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

          echo "%NAME% deployed to %ENV%: ${DEPLOY_NAME}"
BLOCK
        fi
    done

    emit_git_push_auth_step

    # Record deployed versions
    echo ""
    echo "      - name: Record ${env_name} deployed versions"
    echo "        env:"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          %UPPER%_NAME: ${{ secrets.%UPPER%_NAME }}
BLOCK
    done
    echo "        run: |"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          DEPLOY_%UPPER%="${{ needs.validate-and-prepare.outputs.deploy_%LOWER% }}"
BLOCK
    done
    echo ""
    echo "          CHANGED=false"
    if [ "$env_name" = "prod" ]; then
        echo ""
        echo "          git pull --rebase"
    fi
    echo ""
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}" "$env_name"
          if [ "$DEPLOY_%UPPER%" = "true" ]; then
            echo "${{ needs.validate-and-prepare.outputs.%LOWER%_release_tag }}" > ".last-deployed-${%UPPER%_NAME}-%ENV%"
            git add ".last-deployed-${%UPPER%_NAME}-%ENV%"
            CHANGED=true
          fi
BLOCK
        echo ""
    done
    cat <<'EOF'
          if [ "$CHANGED" = "true" ]; then
            git config user.name "github-actions[bot]"
            git config user.email "github-actions[bot]@users.noreply.github.com"
EOF
    echo ""
    echo "            MSG=\"Record ${env_name} deployment:\""
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
            if [ "$DEPLOY_%UPPER%" = "true" ]; then
              MSG="${MSG} ${%UPPER%_NAME}=${{ needs.validate-and-prepare.outputs.%LOWER%_release_tag }}"
            fi
BLOCK
    done
    echo ""
    cat <<'EOF'
            git diff --cached --quiet || git commit -m "${MSG}"
            git push
          fi
EOF
}

emit_notify_job() {
    cat <<EOF

  # ──────────────────────────────────────────────────────────────
  # Job 3: Send approval notification
  #
  # GitHub automatically emails environment reviewers when the
  # deploy-prod job reaches the 'production' environment gate.
  # This job creates an additional deployment notification for
  # broader visibility (repo watchers, team channels, etc).
  # ──────────────────────────────────────────────────────────────
  notify-approval-required:
    needs: [validate-and-prepare, deploy-nonprod]
    runs-on: ${RUNNER}
    steps:
EOF
    emit_gh_auth_step

    echo ""
    echo "      - name: Send deployment approval notification"
    echo "        env:"
    cat <<'EOF'
          _GHE_HOST: ${{ secrets.GHE_HOST }}
          GH_TOKEN: ${{ secrets.GHE_TOKEN }}
          APPROVAL_REVIEWERS: ${{ secrets.APPROVAL_REVIEWERS }}
EOF
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          %UPPER%_NAME: ${{ secrets.%UPPER%_NAME }}
BLOCK
    done
    echo "        run: |"
    cat <<'EOF'
          [ -n "$_GHE_HOST" ] && export GH_HOST="$_GHE_HOST"
          RUN_URL="${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
EOF
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"

          DEPLOY_%UPPER%="${{ needs.validate-and-prepare.outputs.deploy_%LOWER% }}"
BLOCK
    done
    echo ""
    echo '          # Build description of what'\''s being deployed'
    echo '          APPS_LIST=""'
    for i in $(seq 0 $((NUM_APPS - 1))); do
        cat <<'BLOCK' | apply_placeholders "${APP_UPPERS[$i]}" "${APP_LOWERS[$i]}" "${APP_NAMES[$i]}"
          if [ "$DEPLOY_%UPPER%" = "true" ]; then
            %UPPER%_TAG="${{ needs.validate-and-prepare.outputs.%LOWER%_release_tag }}"
            if [ -n "$APPS_LIST" ]; then APPS_LIST="${APPS_LIST}, "; fi
            APPS_LIST="${APPS_LIST}${%UPPER%_NAME} (${%UPPER%_TAG})"
          fi
BLOCK
    done

    cat <<'EOF'

          # Build reviewer mentions for notification
          REVIEWERS_MENTION=""
          if [ -n "$APPROVAL_REVIEWERS" ]; then
            IFS=',' read -ra REVIEWERS <<< "$APPROVAL_REVIEWERS"
            for reviewer in "${REVIEWERS[@]}"; do
              reviewer=$(echo "$reviewer" | xargs)
              REVIEWERS_MENTION="${REVIEWERS_MENTION}@${reviewer} "
            done
          fi

          DESCRIPTION="Production deployment approval required. Apps: ${APPS_LIST}. Review: ${RUN_URL} ${REVIEWERS_MENTION}"

          echo "=========================================="
          echo "PRODUCTION DEPLOYMENT APPROVAL REQUIRED"
          echo "=========================================="
          echo "Apps:       ${APPS_LIST}"
          echo "Approve at: ${RUN_URL}"
          echo "Reviewers:  ${APPROVAL_REVIEWERS}"
          echo "=========================================="

          # Create a deployment event via GitHub API to trigger email notifications
          gh api "repos/${{ github.repository }}/deployments" \
            --input - <<DEPEOF || echo "::warning::Could not create deployment notification (non-blocking)"
          {
            "ref": "${{ github.sha }}",
            "environment": "production-pending",
            "description": "${DESCRIPTION}",
            "auto_merge": false,
            "required_contexts": []
          }
          DEPEOF
EOF
}

generate_workflow() {
    mkdir -p "$(dirname "$GENERATED_WORKFLOW")"
    {
        emit_header
        emit_permissions_and_env
        echo ""
        echo "jobs:"
        emit_validate_job
        emit_deploy_job "nonprod"
        emit_notify_job
        emit_deploy_job "prod"
    } > "$GENERATED_WORKFLOW"

    print_success "Workflow generated: ${BOLD}${GENERATED_WORKFLOW}${NC}"
}

# ─── Debug File ──────────────────────────────────────────────────

save_debug_file() {
    {
        echo "# Secrets Configuration Debug File"
        echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Repository: ${REPO}"
        echo "# Platform: ${GITHUB_PLATFORM}"
        echo "# Shared secrets configured: ${CONFIGURE_SHARED}"
        echo "# Workflow file: ${GENERATED_WORKFLOW}"
        echo "# Runner: ${RUNNER}"
        echo ""
        echo "# Secret name prefixes:"
        for i in $(seq 0 $((NUM_APPS - 1))); do
            echo "#   App $((i+1)): ${APP_UPPERS[$i]}_*"
        done
        echo ""
        if [ "$CONFIGURE_SHARED" = "true" ]; then
            echo "## GitHub Authentication"
            [ -n "$GHE_HOST" ] && echo "GHE_HOST=${GHE_HOST}"
            echo "GHE_TOKEN=${GHE_TOKEN}"
            echo ""
        fi
        for i in $(seq 0 $((NUM_APPS - 1))); do
            echo "## ${APP_NAMES[$i]}"
            echo "${APP_UPPERS[$i]}_UPSTREAM_REPO=${APP_UPSTREAM_REPOS[$i]}"
            echo "${APP_UPPERS[$i]}_NAME=${APP_NAMES[$i]}"
            echo "${APP_UPPERS[$i]}_MANIFEST_PATH=${APP_MANIFEST_PATHS[$i]}"
            echo "${APP_UPPERS[$i]}_ARTIFACT_PATTERN=${APP_ARTIFACT_PATTERNS[$i]}"
            echo "${APP_UPPERS[$i]}_DEPLOY_TYPE=${APP_DEPLOY_TYPES[$i]}"
            echo "${APP_UPPERS[$i]}_CF_ENV_JSON=${APP_CF_ENV_JSONS[$i]:-(not set)}"
            echo ""
        done
        if [ "$CONFIGURE_SHARED" = "true" ]; then
            echo "## Nonprod CF Foundation"
            echo "CF_NONPROD_API=${CF_NONPROD_API}"
            echo "CF_NONPROD_USERNAME=${CF_NONPROD_USERNAME}"
            echo "CF_NONPROD_PASSWORD=${CF_NONPROD_PASSWORD}"
            echo "CF_NONPROD_ORG=${CF_NONPROD_ORG}"
            echo "CF_NONPROD_SPACE=${CF_NONPROD_SPACE}"
            echo ""
            echo "## Prod CF Foundation"
            echo "CF_PROD_API=${CF_PROD_API}"
            echo "CF_PROD_USERNAME=${CF_PROD_USERNAME}"
            echo "CF_PROD_PASSWORD=${CF_PROD_PASSWORD}"
            echo "CF_PROD_ORG=${CF_PROD_ORG}"
            echo "CF_PROD_SPACE=${CF_PROD_SPACE}"
            echo ""
            echo "## Approval Gate"
            echo "APPROVAL_REVIEWERS=${APPROVAL_REVIEWERS}"
        fi
    } > "$DEBUG_FILE"
    print_success "Debug file saved: ${BOLD}${DEBUG_FILE}${NC}"
}

# ─── Requirements Display ───────────────────────────────────────

show_requirements() {
    print_header "Multi-App Deployment - Required Secrets"

    echo "This script will:"
    echo "  1. Set GitHub secrets for your applications"
    echo "  2. Generate a deployment workflow"
    echo ""
    echo "Each app group gets its own workflow and secret prefix."
    echo "Run this script again for additional app groups."
    echo ""
    echo -e "${BOLD}Platform: ${CYAN}${GITHUB_PLATFORM}${NC}"
    echo -e "${BOLD}Number of apps: ${CYAN}${NUM_APPS}${NC}"
    echo ""
    echo -e "${BOLD}Before you begin, gather the following information:${NC}"
    echo ""

    if [ "$CONFIGURE_SHARED" = "true" ]; then
        if [ "$GITHUB_PLATFORM" = "ghe" ]; then
            echo -e "${CYAN}GitHub Enterprise Server:${NC}"
            print_bullet "GHE_HOST                  - GHE hostname (e.g., github.mycompany.com)"
            print_bullet "GHE_TOKEN                 - Personal Access Token for GHE API access"
            echo ""
        else
            echo -e "${CYAN}GitHub Authentication:${NC}"
            print_bullet "GHE_TOKEN                 - Personal Access Token (PAT) with repo scope"
            echo ""
        fi
    fi

    for i in $(seq 0 $((NUM_APPS - 1))); do
        echo -e "${CYAN}Application $((i+1)):${NC}"
        print_bullet "Name                      - CF app base name (e.g., fetch-mcp)"
        print_bullet "Upstream repo             - Source repo (e.g., org/my-api)"
        print_bullet "Manifest path             - Path to manifest in this repo"
        print_bullet "Artifact pattern          - Release asset pattern"
        print_bullet "CF env vars (optional)    - JSON env vars for cf set-env"
        echo ""
    done

    if [ "$CONFIGURE_SHARED" = "true" ]; then
        echo -e "${CYAN}Nonprod CF Foundation:${NC}"
        print_bullet "CF_NONPROD_API            - Nonprod API endpoint"
        print_bullet "CF_NONPROD_USERNAME       - Nonprod service account"
        print_bullet "CF_NONPROD_PASSWORD       - Nonprod password"
        print_bullet "CF_NONPROD_ORG            - Nonprod organization"
        print_bullet "CF_NONPROD_SPACE          - Nonprod space"
        echo ""
        echo -e "${CYAN}Prod CF Foundation:${NC}"
        print_bullet "CF_PROD_API               - Prod API endpoint"
        print_bullet "CF_PROD_USERNAME          - Prod service account"
        print_bullet "CF_PROD_PASSWORD          - Prod password"
        print_bullet "CF_PROD_ORG               - Prod organization"
        print_bullet "CF_PROD_SPACE             - Prod space"
        echo ""
        echo -e "${CYAN}Approval Gate:${NC}"
        print_bullet "APPROVAL_REVIEWERS        - Comma-separated usernames for notifications"
        echo ""
    fi

    read -p "Press Enter when ready to continue (or Ctrl+C to cancel)..."
}

# ─── Main ────────────────────────────────────────────────────────

main() {
    clear 2>/dev/null || true

    print_header "Multi-App Deployment Setup"

    check_gh_cli

    echo ""
    choose_platform
    check_shared_secrets

    # Ask how many apps
    echo ""
    echo -e "${BOLD}How many applications in this deployment group?${NC}"
    read -p "Enter number of apps [1-10]: " NUM_APPS

    if ! [[ "$NUM_APPS" =~ ^[0-9]+$ ]] || [ "$NUM_APPS" -lt 1 ] || [ "$NUM_APPS" -gt 10 ]; then
        print_error "Invalid number. Must be between 1 and 10."
        exit 1
    fi

    # Ask for runner label
    echo ""
    echo -e "${BOLD}GitHub Actions runner label${NC}"
    echo -e "  ${DIM}Use 'ubuntu-latest' for github.com hosted runners,${NC}"
    echo -e "  ${DIM}or specify your self-hosted runner label (e.g., 'self-hosted', 'my-runner').${NC}"
    echo ""
    prompt_value "Runner" "ubuntu-latest"
    RUNNER="$REPLY"

    show_requirements

    print_header "Enter Secret Values"

    # Shared secrets (if selected)
    if [ "$CONFIGURE_SHARED" = "true" ]; then
        if [ "$GITHUB_PLATFORM" = "ghe" ]; then
            print_subheader "GitHub Enterprise Server"
            prompt_value "GHE_HOST" "github.mycompany.com"
            GHE_HOST="$REPLY"
            prompt_hidden "GHE_TOKEN"
            GHE_TOKEN="$REPLY"
        else
            print_subheader "GitHub Authentication"
            echo -e "  ${DIM}A Personal Access Token with 'repo' scope is required${NC}"
            echo -e "  ${DIM}to download release assets from the upstream repositories.${NC}"
            echo ""
            prompt_hidden "GHE_TOKEN"
            GHE_TOKEN="$REPLY"
        fi
    fi

    # Collect app details
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
            echo -e "  ${DIM}Choose a different name (e.g., 'gh-mcp-t5' instead of 'github-mcp-t5')${NC}"
            exit 1
        fi

        prompt_value "Upstream repo" "org/my-api"
        APP_UPSTREAM_REPOS[$i]="$REPLY"
        prompt_value "Manifest path" "manifests/${APP_NAMES[$i]}/manifest.yml"
        APP_MANIFEST_PATHS[$i]="$REPLY"
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
        echo -e "  ${DIM}Optional: JSON object of env vars to inject via cf set-env${NC}"
        echo -e "  ${DIM}Leave empty if the app does not need runtime env vars.${NC}"
        echo -e "  ${DIM}Example: {\"MY_API_KEY\":\"abc123\",\"DB_URL\":\"jdbc:...\"}${NC}"
        echo ""
        prompt_hidden "CF_ENV_JSON (optional)"
        APP_CF_ENV_JSONS[$i]="$REPLY"
    done

    # Compute prefixes and names
    compute_prefixes
    compute_names

    # Shared CF + approval secrets (if selected)
    if [ "$CONFIGURE_SHARED" = "true" ]; then
        print_subheader "Nonprod CF Foundation"
        prompt_value "CF_NONPROD_API" "https://api.sys.nonprod.example.com"
        CF_NONPROD_API="$REPLY"
        prompt_value "CF_NONPROD_USERNAME" "cf-deployer"
        CF_NONPROD_USERNAME="$REPLY"
        prompt_hidden "CF_NONPROD_PASSWORD"
        CF_NONPROD_PASSWORD="$REPLY"
        prompt_value "CF_NONPROD_ORG" "my-org"
        CF_NONPROD_ORG="$REPLY"
        prompt_value "CF_NONPROD_SPACE" "nonprod"
        CF_NONPROD_SPACE="$REPLY"

        print_subheader "Prod CF Foundation"
        prompt_value "CF_PROD_API" "https://api.sys.prod.example.com"
        CF_PROD_API="$REPLY"
        prompt_value "CF_PROD_USERNAME" "cf-deployer"
        CF_PROD_USERNAME="$REPLY"
        prompt_hidden "CF_PROD_PASSWORD"
        CF_PROD_PASSWORD="$REPLY"
        prompt_value "CF_PROD_ORG" "my-org"
        CF_PROD_ORG="$REPLY"
        prompt_value "CF_PROD_SPACE" "prod"
        CF_PROD_SPACE="$REPLY"

        print_subheader "Approval Gate"
        prompt_value "APPROVAL_REVIEWERS" "user1,user2,team-lead"
        APPROVAL_REVIEWERS="$REPLY"
    fi

    # Confirmation
    print_header "Review Your Configuration"

    echo "Please verify these values before setting the secrets:"
    echo ""
    echo -e "${BOLD}Secret name prefixes:${NC}"
    for i in $(seq 0 $((NUM_APPS - 1))); do
        echo -e "  App $((i+1)): ${CYAN}${APP_UPPERS[$i]}_*${NC}  (from ${APP_NAMES[$i]})"
    done
    echo ""
    echo -e "${BOLD}Workflow to generate:${NC}"
    echo -e "  ${CYAN}${GENERATED_WORKFLOW}${NC}"
    echo ""
    echo -e "${BOLD}Runner:${NC}"
    echo -e "  ${CYAN}${RUNNER}${NC}"
    echo ""

    if [ "$CONFIGURE_SHARED" = "true" ]; then
        if [ "$GITHUB_PLATFORM" = "ghe" ]; then
            echo -e "${CYAN}GitHub Enterprise:${NC}"
            show_value "GHE_HOST" "$GHE_HOST"
            show_value "GHE_TOKEN" "$GHE_TOKEN"
        else
            echo -e "${CYAN}GitHub Authentication:${NC}"
            show_value "GHE_TOKEN" "$GHE_TOKEN"
        fi
        echo ""
    fi

    for i in $(seq 0 $((NUM_APPS - 1))); do
        echo -e "${CYAN}${APP_NAMES[$i]} (${APP_UPPERS[$i]}_*):${NC}"
        show_value "${APP_UPPERS[$i]}_UPSTREAM_REPO" "${APP_UPSTREAM_REPOS[$i]}"
        show_value "${APP_UPPERS[$i]}_NAME" "${APP_NAMES[$i]}"
        show_value "${APP_UPPERS[$i]}_MANIFEST_PATH" "${APP_MANIFEST_PATHS[$i]}"
        show_value "${APP_UPPERS[$i]}_ARTIFACT_PATTERN" "${APP_ARTIFACT_PATTERNS[$i]}"
        show_value "Deploy type" "${APP_DEPLOY_TYPES[$i]}"
        show_value "${APP_UPPERS[$i]}_CF_ENV_JSON" "${APP_CF_ENV_JSONS[$i]}"
        echo ""
    done

    if [ "$CONFIGURE_SHARED" = "true" ]; then
        echo -e "${CYAN}Nonprod CF Foundation:${NC}"
        show_value "CF_NONPROD_API" "$CF_NONPROD_API"
        show_value "CF_NONPROD_USERNAME" "$CF_NONPROD_USERNAME"
        show_value "CF_NONPROD_PASSWORD" "$CF_NONPROD_PASSWORD"
        show_value "CF_NONPROD_ORG" "$CF_NONPROD_ORG"
        show_value "CF_NONPROD_SPACE" "$CF_NONPROD_SPACE"
        echo ""
        echo -e "${CYAN}Prod CF Foundation:${NC}"
        show_value "CF_PROD_API" "$CF_PROD_API"
        show_value "CF_PROD_USERNAME" "$CF_PROD_USERNAME"
        show_value "CF_PROD_PASSWORD" "$CF_PROD_PASSWORD"
        show_value "CF_PROD_ORG" "$CF_PROD_ORG"
        show_value "CF_PROD_SPACE" "$CF_PROD_SPACE"
        echo ""
        echo -e "${CYAN}Approval Gate:${NC}"
        show_value "APPROVAL_REVIEWERS" "$APPROVAL_REVIEWERS"
    fi

    echo ""
    read -p "Set these secrets and generate workflow? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        print_warning "Cancelled. No secrets were set."
        exit 0
    fi

    # Generate the workflow
    print_header "Generating Workflow"
    generate_workflow

    print_header "Setting GitHub Secrets"

    local success_count=0

    # Shared secrets
    if [ "$CONFIGURE_SHARED" = "true" ]; then
        if [ "$GITHUB_PLATFORM" = "ghe" ]; then
            set_secret "GHE_HOST" "$GHE_HOST" && ((success_count++)) || true
        fi
        set_secret "GHE_TOKEN" "$GHE_TOKEN" && ((success_count++)) || true
    fi

    # Per-app secrets
    for i in $(seq 0 $((NUM_APPS - 1))); do
        set_secret "${APP_UPPERS[$i]}_UPSTREAM_REPO" "${APP_UPSTREAM_REPOS[$i]}" && ((success_count++)) || true
        set_secret "${APP_UPPERS[$i]}_NAME" "${APP_NAMES[$i]}" && ((success_count++)) || true
        set_secret "${APP_UPPERS[$i]}_MANIFEST_PATH" "${APP_MANIFEST_PATHS[$i]}" && ((success_count++)) || true
        set_secret "${APP_UPPERS[$i]}_ARTIFACT_PATTERN" "${APP_ARTIFACT_PATTERNS[$i]}" && ((success_count++)) || true
        set_secret "${APP_UPPERS[$i]}_CF_ENV_JSON" "${APP_CF_ENV_JSONS[$i]}" && ((success_count++)) || true
    done

    # Shared CF + approval secrets
    if [ "$CONFIGURE_SHARED" = "true" ]; then
        set_secret "CF_NONPROD_API" "$CF_NONPROD_API" && ((success_count++)) || true
        set_secret "CF_NONPROD_USERNAME" "$CF_NONPROD_USERNAME" && ((success_count++)) || true
        set_secret "CF_NONPROD_PASSWORD" "$CF_NONPROD_PASSWORD" && ((success_count++)) || true
        set_secret "CF_NONPROD_ORG" "$CF_NONPROD_ORG" && ((success_count++)) || true
        set_secret "CF_NONPROD_SPACE" "$CF_NONPROD_SPACE" && ((success_count++)) || true
        set_secret "CF_PROD_API" "$CF_PROD_API" && ((success_count++)) || true
        set_secret "CF_PROD_USERNAME" "$CF_PROD_USERNAME" && ((success_count++)) || true
        set_secret "CF_PROD_PASSWORD" "$CF_PROD_PASSWORD" && ((success_count++)) || true
        set_secret "CF_PROD_ORG" "$CF_PROD_ORG" && ((success_count++)) || true
        set_secret "CF_PROD_SPACE" "$CF_PROD_SPACE" && ((success_count++)) || true
        set_secret "APPROVAL_REVIEWERS" "$APPROVAL_REVIEWERS" && ((success_count++)) || true
    fi

    echo ""
    print_success "Deployment configured! ($success_count secrets set)"

    # Save debug file
    save_debug_file

    print_header "Setup Complete"

    echo -e "${BOLD}Generated files:${NC}"
    echo -e "  ${CYAN}${GENERATED_WORKFLOW}${NC}"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo ""

    # Build manifest paths list
    local manifest_list=""
    for i in $(seq 0 $((NUM_APPS - 1))); do
        [ -n "$manifest_list" ] && manifest_list="${manifest_list}\n"
        manifest_list="${manifest_list}   ${DIM}${APP_MANIFEST_PATHS[$i]}${NC}"
    done

    echo "1. Review and commit the generated workflow:"
    echo -e "   ${DIM}git add ${GENERATED_WORKFLOW} && git commit -m \"Add deployment workflow\"${NC}"
    echo -e "   ${DIM}git push${NC}"
    echo ""
    echo "2. Create the 'production' environment for manual approval:"
    echo -e "   ${DIM}Settings > Environments > New environment > 'production'${NC}"
    echo ""
    echo "3. Enable 'Required reviewers' on the production environment"
    echo -e "   ${DIM}Add the users/teams who should approve production deployments${NC}"
    echo -e "   ${DIM}GitHub will email these reviewers when approval is needed${NC}"
    echo ""
    echo "4. Verify your secrets in GitHub:"
    echo -e "   ${DIM}Settings > Secrets and variables > Actions${NC}"
    echo ""
    echo "5. Create the CF manifest files:"
    echo -e "$manifest_list"
    echo ""
    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        echo "6. Ensure your GHE PAT has these scopes:"
    else
        echo "6. Ensure your GitHub PAT has these scopes:"
    fi
    echo -e "   ${DIM}repo, read:org, workflow${NC}"
    echo ""
    echo -e "${DIM}Run this script again to create workflows for additional app groups.${NC}"
    echo ""
}

main "$@"
