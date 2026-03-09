#!/bin/bash
#
# Post-deploy script for the mcp-services alpha/beta deployment pack.
# Adds CF container-to-container network policies so the MCP gateway
# can reach each MCP server on its internal route.
#
# CF CLI is already authenticated to the target foundation/org/space.
#
# Available env vars (set by the workflow):
#   TARGET_LABEL          — "nonprod", "prod-alpha", or "prod-beta"
#   DEPLOYED_APPS         — space-separated deployed CF app names
#   FETCH_MCP_NAME        — CF app name for fetch-mcp (e.g., "fetch-dev", "fetch-alpha")
#   GH_MCP_NAME           — CF app name for gh-mcp (e.g., "gh-mcp-dev", "gh-mcp-alpha")
#   WEB_MCP_NAME          — CF app name for web-mcp (e.g., "web-dev", "web-alpha")
#   DEPLOY_FETCH_MCP      — "true" or "false"
#   DEPLOY_GH_MCP         — "true" or "false"
#   DEPLOY_WEB_MCP        — "true" or "false"
#

set -e

echo "=== Post-deploy network policies: ${TARGET_LABEL} ==="

# ── Gateway app name per environment ─────────────────
# The MCP gateway app that needs to reach each MCP server.
# Adjust these names to match your actual gateway app in each environment.
case "$TARGET_LABEL" in
  nonprod)      GATEWAY="mcp-gateway-dev" ;;
  prod-alpha)   GATEWAY="mcp-gateway-alpha" ;;
  prod-beta)    GATEWAY="mcp-gateway-beta" ;;
  *)            GATEWAY="mcp-gateway-${TARGET_LABEL}" ;;
esac

# ── Add network policies ─────────────────────────────
# Each MCP server listens on port 8080 behind an apps.internal route.
# The gateway needs a network policy to reach each one via C2C networking.

add_policy() {
  local server_app="$1"
  local port="${2:-8080}"
  echo "  cf add-network-policy ${GATEWAY} ${server_app} --protocol tcp --port ${port}"
  cf add-network-policy "$GATEWAY" "$server_app" --protocol tcp --port "$port"
}

if [ "$DEPLOY_FETCH_MCP" = "true" ]; then
  add_policy "$FETCH_MCP_NAME"
fi

if [ "$DEPLOY_GH_MCP" = "true" ]; then
  add_policy "$GH_MCP_NAME"
fi

if [ "$DEPLOY_WEB_MCP" = "true" ]; then
  add_policy "$WEB_MCP_NAME"
fi

echo "=== Network policies complete: ${TARGET_LABEL} ==="
