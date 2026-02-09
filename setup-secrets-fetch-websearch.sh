#!/bin/bash
#
# Setup GitHub secrets for the Fetch & Web Search MCP Servers deployment workflow
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

# Show what secrets are needed
show_requirements() {
    print_header "Fetch & Web Search MCP Servers - Required Secrets"

    echo "This workflow deploys spring-fetch-mcp and web-search-mcp"
    echo "to Cloud Foundry from their separate upstream repos, with"
    echo "independent release tags per server."
    echo ""
    echo -e "${BOLD}Platform: ${CYAN}${GITHUB_PLATFORM}${NC}"
    echo ""
    echo -e "${BOLD}Before you begin, gather the following information:${NC}"
    echo ""

    if [ "$CONFIGURE_SHARED" = "true" ]; then
        if [ "$GITHUB_PLATFORM" = "ghe" ]; then
            echo -e "${CYAN}GitHub Enterprise Server:${NC}"
            print_bullet "GHE_HOST                        - GHE hostname"
            print_bullet "GHE_TOKEN                       - Personal Access Token for GHE"
            echo ""
        else
            echo -e "${CYAN}GitHub Authentication:${NC}"
            print_bullet "GHE_TOKEN                       - Personal Access Token (PAT) with repo scope"
            echo ""
        fi
    fi

    echo -e "${CYAN}Fetch MCP Server (spring-fetch-mcp):${NC}"
    print_bullet "FETCH_MCP_UPSTREAM_REPO         - Source repo (e.g., nkuhn-vmw/spring-fetch-mcp)"
    print_bullet "FETCH_MCP_NAME                  - CF app base name"
    print_bullet "FETCH_MCP_MANIFEST_PATH         - Path to manifest in this repo"
    print_bullet "FETCH_MCP_ARTIFACT_PATTERN      - Release asset pattern"
    echo ""
    echo -e "${CYAN}Web Search MCP Server (web-search-mcp):${NC}"
    print_bullet "WEBSEARCH_MCP_UPSTREAM_REPO     - Source repo (e.g., nkuhn-vmw/web-search-mcp)"
    print_bullet "WEBSEARCH_MCP_NAME              - CF app base name"
    print_bullet "WEBSEARCH_MCP_MANIFEST_PATH     - Path to manifest in this repo"
    print_bullet "WEBSEARCH_MCP_ARTIFACT_PATTERN  - Release asset pattern"
    echo ""

    if [ "$CONFIGURE_SHARED" = "true" ]; then
        echo -e "${CYAN}Nonprod CF Foundation:${NC}"
        print_bullet "CF_NONPROD_API                  - Nonprod API endpoint"
        print_bullet "CF_NONPROD_USERNAME             - Nonprod service account"
        print_bullet "CF_NONPROD_PASSWORD             - Nonprod password"
        print_bullet "CF_NONPROD_ORG                  - Nonprod organization"
        print_bullet "CF_NONPROD_SPACE                - Nonprod space"
        echo ""
        echo -e "${CYAN}Prod CF Foundation:${NC}"
        print_bullet "CF_PROD_API                     - Prod API endpoint"
        print_bullet "CF_PROD_USERNAME                - Prod service account"
        print_bullet "CF_PROD_PASSWORD                - Prod password"
        print_bullet "CF_PROD_ORG                     - Prod organization"
        print_bullet "CF_PROD_SPACE                   - Prod space"
        echo ""
        echo -e "${CYAN}Approval Gate:${NC}"
        print_bullet "APPROVAL_REVIEWERS              - Comma-separated usernames"
        echo ""
    fi

    local total=8
    if [ "$CONFIGURE_SHARED" = "true" ]; then
        total=$((total + 12))
        if [ "$GITHUB_PLATFORM" = "ghe" ]; then
            total=$((total + 1))
        fi
    fi
    echo -e "${DIM}Total: ${total} secrets to configure${NC}"
    echo ""

    read -p "Press Enter when ready to continue (or Ctrl+C to cancel)..."
}

# Main
main() {
    clear 2>/dev/null || true

    print_header "Fetch & Web Search MCP - Deployment Secrets Setup"

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

    # Fetch MCP secrets
    print_subheader "Fetch MCP Server (spring-fetch-mcp)"
    prompt_secret "FETCH_MCP_UPSTREAM_REPO" "nkuhn-vmw/spring-fetch-mcp"
    prompt_secret "FETCH_MCP_NAME" "fetch-mcp"
    prompt_secret "FETCH_MCP_MANIFEST_PATH" "manifests/fetch-mcp/manifest.yml"
    prompt_secret "FETCH_MCP_ARTIFACT_PATTERN" "fetch-mcp-*.jar"

    # Web Search MCP secrets
    print_subheader "Web Search MCP Server (web-search-mcp)"
    prompt_secret "WEBSEARCH_MCP_UPSTREAM_REPO" "nkuhn-vmw/web-search-mcp"
    prompt_secret "WEBSEARCH_MCP_NAME" "web-search-mcp"
    prompt_secret "WEBSEARCH_MCP_MANIFEST_PATH" "manifests/websearch-mcp/manifest.yml"
    prompt_secret "WEBSEARCH_MCP_ARTIFACT_PATTERN" "web-search-mcp-*.jar"

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

    echo -e "${CYAN}Fetch MCP Server:${NC}"
    show_value "FETCH_MCP_UPSTREAM_REPO" "$FETCH_MCP_UPSTREAM_REPO"
    show_value "FETCH_MCP_NAME" "$FETCH_MCP_NAME"
    show_value "FETCH_MCP_MANIFEST_PATH" "$FETCH_MCP_MANIFEST_PATH"
    show_value "FETCH_MCP_ARTIFACT_PATTERN" "$FETCH_MCP_ARTIFACT_PATTERN"
    echo ""
    echo -e "${CYAN}Web Search MCP Server:${NC}"
    show_value "WEBSEARCH_MCP_UPSTREAM_REPO" "$WEBSEARCH_MCP_UPSTREAM_REPO"
    show_value "WEBSEARCH_MCP_NAME" "$WEBSEARCH_MCP_NAME"
    show_value "WEBSEARCH_MCP_MANIFEST_PATH" "$WEBSEARCH_MCP_MANIFEST_PATH"
    show_value "WEBSEARCH_MCP_ARTIFACT_PATTERN" "$WEBSEARCH_MCP_ARTIFACT_PATTERN"

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
    read -p "Set these secrets? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo ""
        print_warning "Cancelled. No secrets were set."
        exit 0
    fi

    print_header "Setting GitHub Secrets"

    local success_count=0

    # Shared secrets
    if [ "$CONFIGURE_SHARED" = "true" ]; then
        if [ "$GITHUB_PLATFORM" = "ghe" ]; then
            set_secret "GHE_HOST" "$GHE_HOST" && ((success_count++)) || true
        fi
        set_secret "GHE_TOKEN" "$GHE_TOKEN" && ((success_count++)) || true
    fi

    # Fetch MCP secrets
    set_secret "FETCH_MCP_UPSTREAM_REPO" "$FETCH_MCP_UPSTREAM_REPO" && ((success_count++)) || true
    set_secret "FETCH_MCP_NAME" "$FETCH_MCP_NAME" && ((success_count++)) || true
    set_secret "FETCH_MCP_MANIFEST_PATH" "$FETCH_MCP_MANIFEST_PATH" && ((success_count++)) || true
    set_secret "FETCH_MCP_ARTIFACT_PATTERN" "$FETCH_MCP_ARTIFACT_PATTERN" && ((success_count++)) || true

    # Web Search MCP secrets
    set_secret "WEBSEARCH_MCP_UPSTREAM_REPO" "$WEBSEARCH_MCP_UPSTREAM_REPO" && ((success_count++)) || true
    set_secret "WEBSEARCH_MCP_NAME" "$WEBSEARCH_MCP_NAME" && ((success_count++)) || true
    set_secret "WEBSEARCH_MCP_MANIFEST_PATH" "$WEBSEARCH_MCP_MANIFEST_PATH" && ((success_count++)) || true
    set_secret "WEBSEARCH_MCP_ARTIFACT_PATTERN" "$WEBSEARCH_MCP_ARTIFACT_PATTERN" && ((success_count++)) || true

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
    echo "4. Create the CF manifest files:"
    echo -e "   ${DIM}manifests/fetch-mcp/manifest.yml${NC}"
    echo -e "   ${DIM}manifests/websearch-mcp/manifest.yml${NC}"
    echo ""
    if [ "$GITHUB_PLATFORM" = "ghe" ]; then
        echo "5. Ensure your GHE PAT has these scopes:"
    else
        echo "5. Ensure your GitHub PAT has these scopes:"
    fi
    echo -e "   ${DIM}repo, read:org, workflow${NC}"
    echo ""
}

main "$@"
