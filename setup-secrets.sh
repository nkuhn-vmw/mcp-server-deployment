#!/bin/bash
#
# Setup GitHub secrets for MCP App Group 1 CF deployment workflow
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

# Show a value for confirmation (mask passwords)
show_value() {
    local name="$1"
    local value="$2"

    if [[ "$name" == *"PASSWORD"* ]] || [[ "$name" == *"TOKEN"* ]]; then
        echo -e "  ${BOLD}$name${NC}: ${DIM}(hidden)${NC}"
    elif [ -z "$value" ]; then
        echo -e "  ${BOLD}$name${NC}: ${YELLOW}(empty - will be skipped)${NC}"
    else
        echo -e "  ${BOLD}$name${NC}: $value"
    fi
}

# Prompt for GitHub platform choice
choose_platform() {
    echo "Where is the upstream release repository hosted?"
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

# Show what secrets are needed
show_requirements() {
    print_header "MCP App Group 1 Deployment - Required Secrets"

    echo "This workflow deploys TWO applications to Cloud Foundry,"
    echo "with separate Nonprod and Prod foundations and an"
    echo "email-based approval gate for production."
    echo ""
    echo -e "${BOLD}Platform: ${CYAN}${GITHUB_PLATFORM}${NC}"
    echo ""
    echo -e "${BOLD}Before you begin, gather the following information:${NC}"
    echo ""

    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        echo -e "${CYAN}GitHub Enterprise Server:${NC}"
        print_bullet "GHE_HOST               - GHE hostname (e.g., github.mycompany.com)"
        print_bullet "GHE_TOKEN              - Personal Access Token for GHE API access"
        echo ""
    else
        echo -e "${CYAN}GitHub Authentication:${NC}"
        print_bullet "GHE_TOKEN              - Personal Access Token (PAT) with repo scope"
        echo ""
    fi

    echo -e "${CYAN}Application Configuration:${NC}"
    print_bullet "APP_UPSTREAM_REPO      - Repo to pull releases from (owner/repo)"
    print_bullet "APP1_NAME              - Application 1 base name"
    print_bullet "APP1_MANIFEST_PATH     - Path to app1 manifest in this repo"
    print_bullet "APP1_ARTIFACT_PATTERN  - Release asset pattern for app1"
    print_bullet "APP2_NAME              - Application 2 base name"
    print_bullet "APP2_MANIFEST_PATH     - Path to app2 manifest in this repo"
    print_bullet "APP2_ARTIFACT_PATTERN  - Release asset pattern for app2"
    echo ""
    echo -e "${CYAN}Nonprod CF Foundation:${NC}"
    print_bullet "CF_NONPROD_API         - Nonprod API endpoint"
    print_bullet "CF_NONPROD_USERNAME    - Nonprod service account"
    print_bullet "CF_NONPROD_PASSWORD    - Nonprod password"
    print_bullet "CF_NONPROD_ORG         - Nonprod organization"
    print_bullet "CF_NONPROD_SPACE       - Nonprod space"
    echo ""
    echo -e "${CYAN}Prod CF Foundation:${NC}"
    print_bullet "CF_PROD_API            - Prod API endpoint"
    print_bullet "CF_PROD_USERNAME       - Prod service account"
    print_bullet "CF_PROD_PASSWORD       - Prod password"
    print_bullet "CF_PROD_ORG            - Prod organization"
    print_bullet "CF_PROD_SPACE          - Prod space"
    echo ""
    echo -e "${CYAN}Approval Gate:${NC}"
    print_bullet "APPROVAL_REVIEWERS     - Comma-separated usernames for notifications"
    echo ""

    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        echo -e "${DIM}Total: 20 secrets to configure${NC}"
    else
        echo -e "${DIM}Total: 19 secrets to configure (GHE_HOST not needed)${NC}"
    fi
    echo ""

    read -p "Press Enter when ready to continue (or Ctrl+C to cancel)..."
}

# Main
main() {
    clear 2>/dev/null || true

    print_header "MCP App Group 1 - Deployment Secrets Setup"

    check_gh_cli

    echo ""
    choose_platform

    show_requirements

    print_header "Enter Secret Values"

    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        print_subheader "GitHub Enterprise Server"
        prompt_secret "GHE_HOST" "github.mycompany.com"
        prompt_password "GHE_TOKEN"
    else
        print_subheader "GitHub Authentication"
        echo -e "  ${DIM}A Personal Access Token with 'repo' scope is required${NC}"
        echo -e "  ${DIM}to download release assets from the upstream repository.${NC}"
        echo ""
        prompt_password "GHE_TOKEN"
    fi

    print_subheader "Application Configuration"
    prompt_secret "APP_UPSTREAM_REPO" "org/repo-name"
    prompt_secret "APP1_NAME" "my-api"
    prompt_secret "APP1_MANIFEST_PATH" "manifests/app1/manifest.yml"
    prompt_secret "APP1_ARTIFACT_PATTERN" "my-api-{version}.jar"
    prompt_secret "APP2_NAME" "my-worker"
    prompt_secret "APP2_MANIFEST_PATH" "manifests/app2/manifest.yml"
    prompt_secret "APP2_ARTIFACT_PATTERN" "my-worker-{version}.jar"

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

    # Confirmation
    print_header "Review Your Configuration"

    echo "Please verify these values before setting the secrets:"
    echo ""
    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        echo -e "${CYAN}GitHub Enterprise:${NC}"
        show_value "GHE_HOST" "$GHE_HOST"
        show_value "GHE_TOKEN" "$GHE_TOKEN"
    else
        echo -e "${CYAN}GitHub Authentication:${NC}"
        show_value "GHE_TOKEN" "$GHE_TOKEN"
    fi
    echo ""
    echo -e "${CYAN}Application Configuration:${NC}"
    show_value "APP_UPSTREAM_REPO" "$APP_UPSTREAM_REPO"
    show_value "APP1_NAME" "$APP1_NAME"
    show_value "APP1_MANIFEST_PATH" "$APP1_MANIFEST_PATH"
    show_value "APP1_ARTIFACT_PATTERN" "$APP1_ARTIFACT_PATTERN"
    show_value "APP2_NAME" "$APP2_NAME"
    show_value "APP2_MANIFEST_PATH" "$APP2_MANIFEST_PATH"
    show_value "APP2_ARTIFACT_PATTERN" "$APP2_ARTIFACT_PATTERN"
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

    echo ""
    read -p "Set these secrets? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        print_warning "Cancelled. No secrets were set."
        exit 0
    fi

    print_header "Setting GitHub Secrets"

    local success_count=0
    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        set_secret "GHE_HOST" "$GHE_HOST" && ((success_count++)) || true
    fi
    set_secret "GHE_TOKEN" "$GHE_TOKEN" && ((success_count++)) || true
    set_secret "APP_UPSTREAM_REPO" "$APP_UPSTREAM_REPO" && ((success_count++)) || true
    set_secret "APP1_NAME" "$APP1_NAME" && ((success_count++)) || true
    set_secret "APP1_MANIFEST_PATH" "$APP1_MANIFEST_PATH" && ((success_count++)) || true
    set_secret "APP1_ARTIFACT_PATTERN" "$APP1_ARTIFACT_PATTERN" && ((success_count++)) || true
    set_secret "APP2_NAME" "$APP2_NAME" && ((success_count++)) || true
    set_secret "APP2_MANIFEST_PATH" "$APP2_MANIFEST_PATH" && ((success_count++)) || true
    set_secret "APP2_ARTIFACT_PATTERN" "$APP2_ARTIFACT_PATTERN" && ((success_count++)) || true
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

    echo ""
    print_success "Deployment configured! ($success_count secrets set)"

    print_header "Setup Complete"

    echo -e "${BOLD}Next steps:${NC}"
    echo ""
    echo "1. Create the 'production' environment for manual approval:"
    echo -e "   ${DIM}Settings > Environments > New environment > 'production'${NC}"
    echo ""
    echo "2. Enable 'Required reviewers' on the production environment"
    echo -e "   ${DIM}Add the users/teams who should approve production deployments${NC}"
    echo -e "   ${DIM}GitHub will email these reviewers when approval is needed${NC}"
    echo ""
    echo "3. Verify your secrets in GitHub:"
    echo -e "   ${DIM}Settings > Secrets and variables > Actions${NC}"
    echo ""
    echo "4. Update the CF manifest files for your applications:"
    echo -e "   ${DIM}manifests/app1/manifest.yml${NC}"
    echo -e "   ${DIM}manifests/app2/manifest.yml${NC}"
    echo ""
    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        echo "5. Ensure your GHE PAT has these scopes:"
        echo -e "   ${DIM}repo, read:org, workflow${NC}"
    else
        echo "5. Ensure your GitHub PAT has these scopes:"
        echo -e "   ${DIM}repo, read:org, workflow${NC}"
    fi
    echo ""
}

main "$@"
