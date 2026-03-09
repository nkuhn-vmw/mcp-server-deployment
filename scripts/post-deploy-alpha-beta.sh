#!/bin/bash
#
# Post-deploy script for the mcp-services alpha/beta deployment pack.
# Adds CF container-to-container network policies so the gh-mcp server
# can reach fetch-mcp and web-mcp on their internal routes.
#
# CF CLI is already authenticated to the target foundation/org/space.
#
# Available env vars (set by the workflow):
#   TARGET_LABEL          — "nonprod", "prod-alpha", or "prod-beta"
#   DEPLOYED_APPS         — space-separated deployed CF app names
#   FETCH_MCP_NAME        — CF app base name (e.g., "fetch-dev")
#   GH_MCP_NAME           — CF app base name (e.g., "gh-mcp-dev")
#   WEB_MCP_NAME          — CF app base name (e.g., "web-dev")
#   FETCH_MCP_VERSION     — dashed version (e.g., "1-2-0")
#   GH_MCP_VERSION        — dashed version (e.g., "0-31-0")
#   WEB_MCP_VERSION       — dashed version (e.g., "1-0-0")
#   DEPLOY_FETCH_MCP      — "true" or "false"
#   DEPLOY_GH_MCP         — "true" or "false"
#   DEPLOY_WEB_MCP        — "true" or "false"
#

set -e

echo "=== Post-deploy network policies: ${TARGET_LABEL} ==="

# ── Build full deployed app names ─────────────────────
# Deploy name pattern: ${BASE_NAME}-${TARGET_LABEL}-${VERSION}
GH_MCP_FULL="${GH_MCP_NAME}-${TARGET_LABEL}-${GH_MCP_VERSION}"
FETCH_MCP_FULL="${FETCH_MCP_NAME}-${TARGET_LABEL}-${FETCH_MCP_VERSION}"
WEB_MCP_FULL="${WEB_MCP_NAME}-${TARGET_LABEL}-${WEB_MCP_VERSION}"

# ── Add network policies ─────────────────────────────
# gh-mcp is the aggregator that needs C2C access to fetch-mcp and web-mcp
# on port 8080 behind apps.internal routes.

add_policy() {
  local source_app="$1"
  local dest_app="$2"
  local port="${3:-8080}"
  echo "  cf add-network-policy ${source_app} ${dest_app} --protocol tcp --port ${port}"
  cf add-network-policy "$source_app" "$dest_app" --protocol tcp --port "$port"
}

if [ "$DEPLOY_GH_MCP" != "true" ]; then
  echo "gh-mcp not deployed this run, skipping network policies"
  exit 0
fi

if [ "$DEPLOY_FETCH_MCP" = "true" ]; then
  add_policy "$GH_MCP_FULL" "$FETCH_MCP_FULL"
fi

if [ "$DEPLOY_WEB_MCP" = "true" ]; then
  add_policy "$GH_MCP_FULL" "$WEB_MCP_FULL"
fi

echo "=== Network policies complete: ${TARGET_LABEL} ==="
