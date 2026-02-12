#!/bin/bash
#
# Setup GitHub secrets and generate a deployment workflow for a pair of
# applications. Each run creates a new workflow YAML from the template
# (multi-app-deploy.yml) with app-specific names and secret references.
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

# Check if gh CLI is installed and authenticated
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

# Prompt for a secret value with better formatting
prompt_secret() {
    local name="$1"
    local example="$2"
    local value

    echo -e "  ${BOLD}$name${NC}"
    echo -e "  ${DIM}Example: $example${NC}"
    read -p "  > " value
    echo ""
    eval "$name=\"\$value\""
}

# Prompt for a password (hidden input)
prompt_password() {
    local name="$1"
    local value

    echo -e "  ${BOLD}$name${NC}"
    echo -e "  ${DIM}(input hidden)${NC}"
    read -sp "  > " value
    echo ""
    echo ""
    eval "$name=\"\$value\""
}

# Set a GitHub secret
set_secret() {
    local name="$1"
    local value="$2"

    if [ -z "$value" ]; then
        print_warning "Skipping $name (empty value)"
        return 1
    fi

    echo "$value" | gh secret set "$name" 2>/dev/null
    print_success "$name"
}

# Show a value for confirmation (mask passwords, tokens, and API keys in terminal)
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

# Prompt for GitHub platform choice
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

# Ask whether to configure shared secrets
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

# Compute secret name prefixes from app names
# e.g., "fetch-mcp" -> UPPER="FETCH_MCP", LOWER="fetch_mcp"
compute_prefixes() {
    APP1_UPPER=$(echo "$APP1_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    APP1_LOWER=$(echo "$APP1_NAME" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
    APP2_UPPER=$(echo "$APP2_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    APP2_LOWER=$(echo "$APP2_NAME" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
}

# Generate a workflow YAML from the template with app-specific names
generate_workflow() {
    local template=".github/workflows/multi-app-deploy.yml"
    GENERATED_WORKFLOW=".github/workflows/deploy-${APP1_NAME}-${APP2_NAME}.yml"

    if [ ! -f "$template" ]; then
        print_error "Template workflow not found: ${template}"
        print_error "Expected the template at the root of the repository."
        return 1
    fi

    {
        echo "# AUTO-GENERATED from multi-app-deploy.yml template"
        echo "# Generated by multi-app-setup-secrets.sh on $(date -u '+%Y-%m-%d')"
        echo "# App 1: ${APP1_NAME} (secrets prefix: ${APP1_UPPER}_*)"
        echo "# App 2: ${APP2_NAME} (secrets prefix: ${APP2_UPPER}_*)"
        echo "#"
        # Skip the template header comment block (lines starting with #) and blank lines before 'name:'
        sed -e "s|APP1|${APP1_UPPER}|g" \
            -e "s|app1|${APP1_LOWER}|g" \
            -e "s|App 1|${APP1_NAME}|g" \
            -e "s|Application 1|${APP1_NAME}|g" \
            -e "s|APP2|${APP2_UPPER}|g" \
            -e "s|app2|${APP2_LOWER}|g" \
            -e "s|App 2|${APP2_NAME}|g" \
            -e "s|Application 2|${APP2_NAME}|g" \
            -e "s|Deploy MCP App Group 1|Deploy ${APP1_NAME} \& ${APP2_NAME}|g" \
            -e "s|MCP App Group 1|${APP1_NAME} \& ${APP2_NAME}|g" \
            "$template"
    } > "$GENERATED_WORKFLOW"

    print_success "Workflow generated: ${BOLD}${GENERATED_WORKFLOW}${NC}"
}

# Save debug file with ALL values (nothing masked) for troubleshooting
save_debug_file() {
    local debug_file=".multi-app-secrets-debug-${APP1_NAME}-${APP2_NAME}.txt"
    {
        echo "# Secrets Configuration Debug File"
        echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "# Repository: ${REPO}"
        echo "# Platform: ${GITHUB_PLATFORM}"
        echo "# Shared secrets configured: ${CONFIGURE_SHARED}"
        echo "# Workflow file: ${GENERATED_WORKFLOW}"
        echo ""
        echo "# Secret name prefixes:"
        echo "#   App 1: ${APP1_UPPER}_*"
        echo "#   App 2: ${APP2_UPPER}_*"
        echo ""
        if [ "$CONFIGURE_SHARED" = "true" ]; then
            echo "## GitHub Authentication"
            [ -n "$GHE_HOST" ] && echo "GHE_HOST=${GHE_HOST}"
            echo "GHE_TOKEN=${GHE_TOKEN}"
            echo ""
        fi
        echo "## ${APP1_NAME}"
        echo "${APP1_UPPER}_UPSTREAM_REPO=${APP1_UPSTREAM_REPO}"
        echo "${APP1_UPPER}_NAME=${APP1_NAME}"
        echo "${APP1_UPPER}_MANIFEST_PATH=${APP1_MANIFEST_PATH}"
        echo "${APP1_UPPER}_ARTIFACT_PATTERN=${APP1_ARTIFACT_PATTERN}"
        echo "${APP1_UPPER}_CF_ENV_JSON=${APP1_CF_ENV_JSON:-(not set)}"
        echo ""
        echo "## ${APP2_NAME}"
        echo "${APP2_UPPER}_UPSTREAM_REPO=${APP2_UPSTREAM_REPO}"
        echo "${APP2_UPPER}_NAME=${APP2_NAME}"
        echo "${APP2_UPPER}_MANIFEST_PATH=${APP2_MANIFEST_PATH}"
        echo "${APP2_UPPER}_ARTIFACT_PATTERN=${APP2_ARTIFACT_PATTERN}"
        echo "${APP2_UPPER}_CF_ENV_JSON=${APP2_CF_ENV_JSON:-(not set)}"
        echo ""
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
    } > "$debug_file"
    print_success "Debug file saved: ${BOLD}${debug_file}${NC}"
}

# Show what secrets are needed
show_requirements() {
    print_header "Multi-App Deployment - Required Secrets"

    echo "This script will:"
    echo "  1. Set GitHub secrets for your two applications"
    echo "  2. Generate a deployment workflow from the template"
    echo ""
    echo "Each app pair gets its own workflow and secret prefix."
    echo "Run this script again for additional app pairs."
    echo ""
    echo -e "${BOLD}Platform: ${CYAN}${GITHUB_PLATFORM}${NC}"
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

    echo -e "${CYAN}Application 1:${NC}"
    print_bullet "Name                      - CF app base name (e.g., fetch-mcp)"
    print_bullet "Upstream repo             - Source repo (e.g., org/my-api)"
    print_bullet "Manifest path             - Path to manifest in this repo"
    print_bullet "Artifact pattern          - Release asset pattern"
    print_bullet "CF env vars (optional)    - JSON env vars for cf set-env"
    echo ""
    echo -e "${CYAN}Application 2:${NC}"
    print_bullet "Name                      - CF app base name (e.g., web-search-mcp)"
    print_bullet "Upstream repo             - Source repo (e.g., org/my-worker)"
    print_bullet "Manifest path             - Path to manifest in this repo"
    print_bullet "Artifact pattern          - Release asset pattern"
    print_bullet "CF env vars (optional)    - JSON env vars for cf set-env"
    echo ""

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

# Main
main() {
    clear 2>/dev/null || true

    print_header "Multi-App Deployment Setup"

    check_gh_cli

    echo ""
    choose_platform
    check_shared_secrets

    show_requirements

    print_header "Enter Secret Values"

    # Shared secrets (if selected)
    if [ "$CONFIGURE_SHARED" = "true" ]; then
        if [ "$GITHUB_PLATFORM" = "ghe" ]; then
            print_subheader "GitHub Enterprise Server"
            prompt_secret "GHE_HOST" "github.mycompany.com"
            prompt_password "GHE_TOKEN"
        else
            print_subheader "GitHub Authentication"
            echo -e "  ${DIM}A Personal Access Token with 'repo' scope is required${NC}"
            echo -e "  ${DIM}to download release assets from the upstream repositories.${NC}"
            echo ""
            prompt_password "GHE_TOKEN"
        fi
    fi

    # App 1 secrets
    print_subheader "Application 1"
    prompt_secret "APP1_NAME" "fetch-mcp"
    prompt_secret "APP1_UPSTREAM_REPO" "org/my-api"
    prompt_secret "APP1_MANIFEST_PATH" "manifests/${APP1_NAME}/manifest.yml"
    prompt_secret "APP1_ARTIFACT_PATTERN" "${APP1_NAME}-*.jar"
    echo -e "  ${DIM}Optional: JSON object of env vars to inject via cf set-env${NC}"
    echo -e "  ${DIM}Leave empty if the app does not need runtime env vars.${NC}"
    echo -e "  ${DIM}Example: {\"MY_API_KEY\":\"abc123\",\"DB_URL\":\"jdbc:...\"}${NC}"
    echo ""
    prompt_password "APP1_CF_ENV_JSON"

    # App 2 secrets
    print_subheader "Application 2"
    prompt_secret "APP2_NAME" "web-search-mcp"
    prompt_secret "APP2_UPSTREAM_REPO" "org/my-worker"
    prompt_secret "APP2_MANIFEST_PATH" "manifests/${APP2_NAME}/manifest.yml"
    prompt_secret "APP2_ARTIFACT_PATTERN" "${APP2_NAME}-*.jar"
    echo -e "  ${DIM}Optional: JSON object of env vars to inject via cf set-env${NC}"
    echo -e "  ${DIM}Leave empty if the app does not need runtime env vars.${NC}"
    echo -e "  ${DIM}Example: {\"WEBSEARCH_API_KEY\":\"bravekey123\"}${NC}"
    echo ""
    prompt_password "APP2_CF_ENV_JSON"

    # Compute prefixes now that we have the app names
    compute_prefixes

    # Shared CF + approval secrets (if selected)
    if [ "$CONFIGURE_SHARED" = "true" ]; then
        print_subheader "Nonprod CF Foundation"
        prompt_secret "CF_NONPROD_API" "https://api.sys.nonprod.example.com"
        prompt_secret "CF_NONPROD_USERNAME" "cf-deployer"
        prompt_password "CF_NONPROD_PASSWORD"
        prompt_secret "CF_NONPROD_ORG" "my-org"
        prompt_secret "CF_NONPROD_SPACE" "nonprod"

        print_subheader "Prod CF Foundation"
        prompt_secret "CF_PROD_API" "https://api.sys.prod.example.com"
        prompt_secret "CF_PROD_USERNAME" "cf-deployer"
        prompt_password "CF_PROD_PASSWORD"
        prompt_secret "CF_PROD_ORG" "my-org"
        prompt_secret "CF_PROD_SPACE" "prod"

        print_subheader "Approval Gate"
        prompt_secret "APPROVAL_REVIEWERS" "user1,user2,team-lead"
    fi

    # Confirmation
    print_header "Review Your Configuration"

    echo "Please verify these values before setting the secrets:"
    echo ""
    echo -e "${BOLD}Secret name prefixes:${NC}"
    echo -e "  App 1: ${CYAN}${APP1_UPPER}_*${NC}  (from ${APP1_NAME})"
    echo -e "  App 2: ${CYAN}${APP2_UPPER}_*${NC}  (from ${APP2_NAME})"
    echo ""
    echo -e "${BOLD}Workflow to generate:${NC}"
    echo -e "  ${CYAN}.github/workflows/deploy-${APP1_NAME}-${APP2_NAME}.yml${NC}"
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

    echo -e "${CYAN}${APP1_NAME} (${APP1_UPPER}_*):${NC}"
    show_value "${APP1_UPPER}_UPSTREAM_REPO" "$APP1_UPSTREAM_REPO"
    show_value "${APP1_UPPER}_NAME" "$APP1_NAME"
    show_value "${APP1_UPPER}_MANIFEST_PATH" "$APP1_MANIFEST_PATH"
    show_value "${APP1_UPPER}_ARTIFACT_PATTERN" "$APP1_ARTIFACT_PATTERN"
    show_value "${APP1_UPPER}_CF_ENV_JSON" "$APP1_CF_ENV_JSON"
    echo ""
    echo -e "${CYAN}${APP2_NAME} (${APP2_UPPER}_*):${NC}"
    show_value "${APP2_UPPER}_UPSTREAM_REPO" "$APP2_UPSTREAM_REPO"
    show_value "${APP2_UPPER}_NAME" "$APP2_NAME"
    show_value "${APP2_UPPER}_MANIFEST_PATH" "$APP2_MANIFEST_PATH"
    show_value "${APP2_UPPER}_ARTIFACT_PATTERN" "$APP2_ARTIFACT_PATTERN"
    show_value "${APP2_UPPER}_CF_ENV_JSON" "$APP2_CF_ENV_JSON"

    if [ "$CONFIGURE_SHARED" = "true" ]; then
        echo ""
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

    # Generate the workflow from template
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

    # App 1 secrets (using app-specific prefix)
    set_secret "${APP1_UPPER}_UPSTREAM_REPO" "$APP1_UPSTREAM_REPO" && ((success_count++)) || true
    set_secret "${APP1_UPPER}_NAME" "$APP1_NAME" && ((success_count++)) || true
    set_secret "${APP1_UPPER}_MANIFEST_PATH" "$APP1_MANIFEST_PATH" && ((success_count++)) || true
    set_secret "${APP1_UPPER}_ARTIFACT_PATTERN" "$APP1_ARTIFACT_PATTERN" && ((success_count++)) || true
    set_secret "${APP1_UPPER}_CF_ENV_JSON" "$APP1_CF_ENV_JSON" && ((success_count++)) || true

    # App 2 secrets (using app-specific prefix)
    set_secret "${APP2_UPPER}_UPSTREAM_REPO" "$APP2_UPSTREAM_REPO" && ((success_count++)) || true
    set_secret "${APP2_UPPER}_NAME" "$APP2_NAME" && ((success_count++)) || true
    set_secret "${APP2_UPPER}_MANIFEST_PATH" "$APP2_MANIFEST_PATH" && ((success_count++)) || true
    set_secret "${APP2_UPPER}_ARTIFACT_PATTERN" "$APP2_ARTIFACT_PATTERN" && ((success_count++)) || true
    set_secret "${APP2_UPPER}_CF_ENV_JSON" "$APP2_CF_ENV_JSON" && ((success_count++)) || true

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

    # Save debug file with ALL values (nothing masked)
    save_debug_file

    print_header "Setup Complete"

    echo -e "${BOLD}Generated files:${NC}"
    echo -e "  ${CYAN}${GENERATED_WORKFLOW}${NC}"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo ""
    echo "1. Review and commit the generated workflow:"
    echo -e "   ${DIM}git add ${GENERATED_WORKFLOW} && git commit -m \"Add deployment workflow for ${APP1_NAME} & ${APP2_NAME}\"${NC}"
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
    echo -e "   ${DIM}${APP1_MANIFEST_PATH}${NC}"
    echo -e "   ${DIM}${APP2_MANIFEST_PATH}${NC}"
    echo ""
    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        echo "6. Ensure your GHE PAT has these scopes:"
    else
        echo "6. Ensure your GitHub PAT has these scopes:"
    fi
    echo -e "   ${DIM}repo, read:org, workflow${NC}"
    echo ""
    echo -e "${DIM}Run this script again to create workflows for additional app pairs.${NC}"
    echo ""
}

main "$@"
