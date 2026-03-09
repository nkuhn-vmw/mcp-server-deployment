#!/bin/bash
#
# Post-deploy script — runs after each environment's app deployments.
# CF CLI is already authenticated to the target foundation.
#
# Available environment variables:
#   TARGET_LABEL   — environment name (e.g., "nonprod", "prod-alpha")
#   DEPLOYED_APPS  — space-separated list of deployed CF app names
#   DEPLOY_{APP}   — "true" or "false" for each app in the pack
#   {APP}_NAME     — CF app name for each app
#   {APP}_VERSION  — deployed version for each app
#
# Example: with apps fetch-mcp-services and gh-mcp-services, you get:
#   DEPLOY_FETCH_MCP_SERVICES=true
#   FETCH_MCP_SERVICES_NAME=fetch-dev
#   FETCH_MCP_SERVICES_VERSION=v1.2.0
#

set -e

echo "=== Post-deploy: ${TARGET_LABEL} ==="
echo "Deployed apps: ${DEPLOYED_APPS}"

# ── Network Policies ────────────────────────────────
# Add network policies from a gateway app to each deployed MCP server.
# Adjust GATEWAY_APP to match your gateway's CF app name for this environment.

GATEWAY_APP="mcp-gateway-${TARGET_LABEL}"

for APP in $DEPLOYED_APPS; do
  echo "Adding network policy: ${GATEWAY_APP} -> ${APP} (tcp:8080)"
  cf add-network-policy "$GATEWAY_APP" "$APP" --protocol tcp --port 8080
done

# ── Additional Examples (uncomment as needed) ───────

# Map a route to a deployed app:
# for APP in $DEPLOYED_APPS; do
#   cf map-route "$APP" apps.internal --hostname "$APP"
# done

# Bind a service instance:
# for APP in $DEPLOYED_APPS; do
#   cf bind-service "$APP" my-database
#   cf restage "$APP"
# done

# Run smoke tests:
# for APP in $DEPLOYED_APPS; do
#   ROUTE=$(cf app "$APP" | grep routes | awk '{print $2}')
#   echo "Smoke test: https://${ROUTE}/health"
#   curl -sf "https://${ROUTE}/health" || { echo "FAILED: ${APP}"; exit 1; }
# done

echo "=== Post-deploy complete: ${TARGET_LABEL} ==="
