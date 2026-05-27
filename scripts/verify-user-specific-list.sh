#!/bin/bash
# Verify the user-specific tool list feature against a running Kind cluster.
# Prereqs: make local-env-setup && make deploy-test-servers
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://mcp.127-0-0-1.sslip.io:8001/mcp}"
NAMESPACE="${NAMESPACE:-mcp-test}"
DEPLOYMENT="mcp-test-user-specific-server"
BROKER_DEPLOY="${BROKER_DEPLOY:-mcp-gateway}"
BROKER_NS="${BROKER_NS:-mcp-system}"

pass=0
fail=0

info()  { printf "\n\033[1;34m▸ %s\033[0m\n" "$1"; }
ok()    { pass=$((pass+1)); printf "  \033[32m✓ %s\033[0m\n" "$1"; }
fail()  { fail=$((fail+1)); printf "  \033[31m✗ %s\033[0m\n" "$1"; }
check() {
    if eval "$1"; then ok "$2"; else fail "$2"; fi
}

# init_session [extra_headers...] → prints session id
init_session() {
    local hdrs=()
    for h in "$@"; do hdrs+=(-H "$h"); done
    local resp
    resp=$(curl -sS -D - -o /dev/null -X POST "$GATEWAY_URL" \
        -H "Content-Type: application/json" \
        ${hdrs[@]+"${hdrs[@]}"} \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"verify","version":"1.0"},"capabilities":{}}}' 2>&1)
    echo "$resp" | grep -i mcp-session-id | tr -d '\r' | awk '{print $2}'
}

# list_tools session_id [extra_headers...] → prints raw JSON
list_tools() {
    local sid="$1"; shift
    local hdrs=()
    for h in "$@"; do hdrs+=(-H "$h"); done
    curl -sS -X POST "$GATEWAY_URL" \
        -H "Content-Type: application/json" \
        -H "Mcp-Session-Id: $sid" \
        ${hdrs[@]+"${hdrs[@]}"} \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
}

# call_tool session_id tool_name [extra_headers...] → prints raw JSON
call_tool() {
    local sid="$1" tool="$2"; shift 2
    local hdrs=()
    for h in "$@"; do hdrs+=(-H "$h"); done
    curl -sS -X POST "$GATEWAY_URL" \
        -H "Content-Type: application/json" \
        -H "Mcp-Session-Id: $sid" \
        ${hdrs[@]+"${hdrs[@]}"} \
        -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\"}}"
}

# has_tool json tool_name → exit 0 if present
has_tool() { echo "$1" | jq -e --arg t "$2" '.result.tools[]? | select(.name == $t)' >/dev/null 2>&1; }

# ── Preflight ────────────────────────────────────────────────────────
info "Preflight checks"

check "kubectl get deployment $DEPLOYMENT -n $NAMESPACE -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '[1-9]'" \
    "user-specific-server deployment is running"

check "kubectl get mcpsr -n $NAMESPACE test-user-specific-server -o jsonpath='{.spec.userSpecificList}' 2>/dev/null | grep -q Enabled" \
    "MCPServerRegistration has userSpecificList: Enabled"

# ── Step 1: No auth → no user-scoped tools ───────────────────────────
info "Step 1: Unauthenticated client does not see user-scoped tools"

SESSION_NOAUTH=$(init_session)
check '[ -n "$SESSION_NOAUTH" ]' "got session without auth"

TOOLS_NOAUTH=$(list_tools "$SESSION_NOAUTH")
check '! has_tool "$TOOLS_NOAUTH" "uspec_list_repos"'   "uspec_list_repos absent (no auth)"
check '! has_tool "$TOOLS_NOAUTH" "uspec_create_issue"'  "uspec_create_issue absent (no auth)"
check '! has_tool "$TOOLS_NOAUTH" "uspec_run_pipeline"'  "uspec_run_pipeline absent (no auth)"

# ── Step 2: User-A sees their tools ──────────────────────────────────
info "Step 2: User-A sees list_repos and create_issue"

SESSION_A=$(init_session "Authorization: Bearer user-a-token")
check '[ -n "$SESSION_A" ]' "got session for user-a"

TOOLS_A=$(list_tools "$SESSION_A" "Authorization: Bearer user-a-token")
check 'has_tool "$TOOLS_A" "uspec_list_repos"'      "user-a sees uspec_list_repos"
check 'has_tool "$TOOLS_A" "uspec_create_issue"'     "user-a sees uspec_create_issue"
check 'has_tool "$TOOLS_A" "uspec_server_info"'      "user-a sees uspec_server_info (common)"
check '! has_tool "$TOOLS_A" "uspec_run_pipeline"'   "user-a does NOT see uspec_run_pipeline"

# ── Step 3: User-B sees different tools ──────────────────────────────
info "Step 3: User-B sees run_pipeline only"

SESSION_B=$(init_session "Authorization: Bearer user-b-token")
TOOLS_B=$(list_tools "$SESSION_B" "Authorization: Bearer user-b-token")
check 'has_tool "$TOOLS_B" "uspec_run_pipeline"'     "user-b sees uspec_run_pipeline"
check 'has_tool "$TOOLS_B" "uspec_server_info"'      "user-b sees uspec_server_info (common)"
check '! has_tool "$TOOLS_B" "uspec_list_repos"'     "user-b does NOT see uspec_list_repos"
check '! has_tool "$TOOLS_B" "uspec_create_issue"'   "user-b does NOT see uspec_create_issue"

# ── Step 4: tools/call works ─────────────────────────────────────────
info "Step 4: tools/call routes to user-specific server"

CALL_RESULT=$(call_tool "$SESSION_A" "uspec_server_info" "Authorization: Bearer user-a-token")
check 'echo "$CALL_RESULT" | jq -r ".result.content[0].text" 2>/dev/null | grep -q "server=user-specific-test-server"' \
    "server_info returns correct server identity"
check 'echo "$CALL_RESULT" | jq -r ".result.content[0].text" 2>/dev/null | grep -q "user=user-a-token"' \
    "server_info returns correct user identity"

# ── Step 5: Internal headers stripped ─────────────────────────────────
info "Step 5: Internal gateway headers not forwarded to upstream"

HEADERS_RESULT=$(call_tool "$SESSION_A" "uspec_headers" \
    "Authorization: Bearer user-a-token" \
    "X-Mcp-Virtualserver: test/vs")
HEADER_TEXT=$(echo "$HEADERS_RESULT" | jq -r '.result.content[0].text' 2>/dev/null | tr '[:upper:]' '[:lower:]')

check 'echo "$HEADER_TEXT" | grep -q "authorization"'             "authorization header forwarded"
check '! echo "$HEADER_TEXT" | grep -q "x-mcp-virtualserver"'     "x-mcp-virtualserver stripped"
check '! echo "$HEADER_TEXT" | grep -q "x-mcp-authorized"'        "x-mcp-authorized stripped"

# ── Step 6: Graceful degradation ──────────────────────────────────────
info "Step 6: Server down does not break tools/list"

kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=0 --timeout=30s >/dev/null 2>&1
kubectl wait --for=delete pod -l app="$DEPLOYMENT" -n "$NAMESPACE" --timeout=30s >/dev/null 2>&1 || true
sleep 2

SESSION_DOWN=$(init_session "Authorization: Bearer user-a-token")
TOOLS_DOWN=$(list_tools "$SESSION_DOWN" "Authorization: Bearer user-a-token")

check 'echo "$TOOLS_DOWN" | jq -e ".result.tools" >/dev/null 2>&1'  "tools/list succeeds when server is down"
check '! has_tool "$TOOLS_DOWN" "uspec_list_repos"'                  "no user-specific tools when server is down"
# standard tools should still be present
STD_COUNT=$(echo "$TOOLS_DOWN" | jq '.result.tools | length' 2>/dev/null)
check '[ "${STD_COUNT:-0}" -gt 0 ]'                                 "standard tools still returned ($STD_COUNT tools)"

kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=1 --timeout=30s >/dev/null 2>&1
kubectl wait --for=condition=Ready pod -l app="$DEPLOYMENT" -n "$NAMESPACE" --timeout=60s >/dev/null 2>&1

# ── Step 7: Session reuse (second list returns same tools) ────────────
info "Step 7: Session reuse — second tools/list returns consistent results"

SESSION_REUSE=$(init_session "Authorization: Bearer user-a-token")

# first tools/list — triggers upstream init
TOOLS_FIRST=$(list_tools "$SESSION_REUSE" "Authorization: Bearer user-a-token")
FIRST_NAMES=$(echo "$TOOLS_FIRST" | jq -r '[.result.tools[]?.name] | sort | join(",")' 2>/dev/null)
check '[ -n "$FIRST_NAMES" ]'  "first tools/list returned tools"

# second tools/list — should reuse cached session
TOOLS_SECOND=$(list_tools "$SESSION_REUSE" "Authorization: Bearer user-a-token")
SECOND_NAMES=$(echo "$TOOLS_SECOND" | jq -r '[.result.tools[]?.name] | sort | join(",")' 2>/dev/null)

check '[ "$FIRST_NAMES" = "$SECOND_NAMES" ]'  "second tools/list returns identical tool set"
check 'has_tool "$TOOLS_SECOND" "uspec_list_repos"'  "user-specific tools still present on reuse"

# ── Step 8: MCPServerRegistration status ──────────────────────────────
info "Step 8: MCPServerRegistration shows ready status"

STATUS_TYPE=$(kubectl get mcpsr -n "$NAMESPACE" test-user-specific-server \
    -o jsonpath='{.status.conditions[0].type}' 2>/dev/null)
STATUS_VAL=$(kubectl get mcpsr -n "$NAMESPACE" test-user-specific-server \
    -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)
STATUS_MSG=$(kubectl get mcpsr -n "$NAMESPACE" test-user-specific-server \
    -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)

check '[ "$STATUS_TYPE" = "Ready" ]'        "condition type is Ready"
check '[ "$STATUS_VAL" = "True" ]'          "condition status is True"
check 'echo "$STATUS_MSG" | grep -qi "userSpecificList"' "message mentions userSpecificList"

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "============================================"
printf "  \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$pass" "$fail"
echo "============================================"

[ "$fail" -eq 0 ]
