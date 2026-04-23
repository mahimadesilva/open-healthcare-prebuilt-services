#!/bin/bash
# Tests endpoints that exercise search_parameter_sync.bal and terminology/repository.bal:
#   search_parameter_sync.bal → POST/PUT/DELETE SearchParameter
#   terminology/repository.bal → CodeSystem/$lookup, ValueSet/$expand (by ID and by URL)
#
# For terminology ops the key assertion is "not HTTP 500" — the server may return 4xx
# if an operation is not fully implemented, but 500 would indicate the RESOURCE_JSON
# type-mapping bug (byte[] vs JSONB) that was fixed.
#
# Assumes the server is already running on localhost:9090.
# Run with: bash tests/terminology-searchparam-test.sh

BASE_URL="http://localhost:9090/fhir/r4"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0

SP_ID="test-sp-sync-001"
CS_ID="test-cs-repo-001"
VS_ID="test-vs-repo-001"
CS_URL="http://test.example.org/CodeSystem/test-cs-repo-001"
VS_URL="http://test.example.org/ValueSet/test-vs-repo-001"

# ─── helpers ────────────────────────────────────────────────────────────────

print_req() {
    echo ""
    echo -e "${CYAN}${BOLD}>>> $1  $2${NC}"
}

print_res() {
    local code="$1"
    local body="$2"
    echo -e "${YELLOW}<<< HTTP $code${NC}"
    echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
}

pass() { PASSED=$((PASSED+1)); echo -e "${GREEN}✓ PASS${NC}: $1"; }
fail() { FAILED=$((FAILED+1)); echo -e "${RED}✗ FAIL${NC}: $1"; }

do_req() {
    local method="$1"; shift
    local url="$1"; shift
    local tmpfile; tmpfile=$(mktemp)
    local code; code=$(curl -s -w "%{http_code}" -o "$tmpfile" -X "$method" "$url" "$@")
    local body; body=$(cat "$tmpfile")
    rm -f "$tmpfile"
    echo "$code|$body"
}

# ─── cleanup ────────────────────────────────────────────────────────────────

echo "======================================================================"
echo -e "${BOLD}SearchParameter Sync + Terminology Repository Tests${NC}"
echo "======================================================================"
echo "Cleaning up leftover test resources..."
curl -s -o /dev/null -X DELETE "$BASE_URL/SearchParameter/$SP_ID" || true
curl -s -o /dev/null -X DELETE "$BASE_URL/CodeSystem/$CS_ID" || true
curl -s -o /dev/null -X DELETE "$BASE_URL/ValueSet/$VS_ID" || true
echo ""

# ======================================================================
# PART 1: SearchParameter CRUD  (search_parameter_sync.bal)
# ======================================================================

echo -e "${BOLD}--- Part 1: SearchParameter CRUD (search_parameter_sync.bal) ---${NC}"

# Test 1: Create SearchParameter → syncSearchParameterToExpressions
print_req "POST" "$BASE_URL/SearchParameter"
result=$(do_req POST "$BASE_URL/SearchParameter" \
  -H "Content-Type: application/fhir+json" \
  -d "{
    \"resourceType\": \"SearchParameter\",
    \"id\": \"$SP_ID\",
    \"url\": \"http://test.example.org/SearchParameter/$SP_ID\",
    \"name\": \"TestCustomParam\",
    \"status\": \"active\",
    \"description\": \"Test custom search parameter\",
    \"code\": \"test-custom-param\",
    \"base\": [\"Patient\"],
    \"type\": \"token\",
    \"expression\": \"Patient.identifier\"
  }")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "201" ]; then
    pass "POST SearchParameter → syncSearchParameterToExpressions called (HTTP 201)"
else
    fail "POST SearchParameter failed (HTTP $code)"
fi

# Test 2: Read SearchParameter back
print_req "GET" "$BASE_URL/SearchParameter/$SP_ID"
result=$(do_req GET "$BASE_URL/SearchParameter/$SP_ID")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ]; then
    pass "GET SearchParameter/$SP_ID → resource readable (HTTP 200)"
else
    fail "GET SearchParameter/$SP_ID failed (HTTP $code)"
fi

# Test 3: Update SearchParameter → syncSearchParameterToExpressions again with new expression
print_req "PUT" "$BASE_URL/SearchParameter/$SP_ID"
result=$(do_req PUT "$BASE_URL/SearchParameter/$SP_ID" \
  -H "Content-Type: application/fhir+json" \
  -d "{
    \"resourceType\": \"SearchParameter\",
    \"id\": \"$SP_ID\",
    \"url\": \"http://test.example.org/SearchParameter/$SP_ID\",
    \"name\": \"TestCustomParam\",
    \"status\": \"active\",
    \"description\": \"Updated test custom search parameter\",
    \"code\": \"test-custom-param\",
    \"base\": [\"Patient\"],
    \"type\": \"date\",
    \"expression\": \"Patient.birthDate\"
  }")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] || [ "$code" = "201" ]; then
    pass "PUT SearchParameter/$SP_ID → syncSearchParameterToExpressions called (HTTP $code)"
else
    fail "PUT SearchParameter/$SP_ID failed (HTTP $code)"
fi

# Test 4: Delete SearchParameter → removeSearchParameterById reads RESOURCE_JSON to get code
print_req "DELETE" "$BASE_URL/SearchParameter/$SP_ID"
result=$(do_req DELETE "$BASE_URL/SearchParameter/$SP_ID")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] || [ "$code" = "204" ]; then
    pass "DELETE SearchParameter/$SP_ID → removeSearchParameterById called (HTTP $code)"
else
    fail "DELETE SearchParameter/$SP_ID failed (HTTP $code)"
fi

# Test 5: Confirm deleted
print_req "GET" "$BASE_URL/SearchParameter/$SP_ID  (expect 404/410)"
result=$(do_req GET "$BASE_URL/SearchParameter/$SP_ID")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "404" ] || [ "$code" = "410" ]; then
    pass "GET SearchParameter/$SP_ID after delete → $code (resource gone)"
else
    fail "Expected 404/410 after delete, got HTTP $code"
fi

# ======================================================================
# PART 2: Terminology operations  (terminology/repository.bal)
# ======================================================================

echo ""
echo -e "${BOLD}--- Part 2: Terminology Operations (terminology/repository.bal) ---${NC}"

# Test 6: Create CodeSystem (setup)
print_req "POST" "$BASE_URL/CodeSystem"
result=$(do_req POST "$BASE_URL/CodeSystem" \
  -H "Content-Type: application/fhir+json" \
  -d "{
    \"resourceType\": \"CodeSystem\",
    \"id\": \"$CS_ID\",
    \"url\": \"$CS_URL\",
    \"status\": \"active\",
    \"content\": \"complete\",
    \"concept\": [
      {\"code\": \"A01\", \"display\": \"Test concept A01\"},
      {\"code\": \"B02\", \"display\": \"Test concept B02\"}
    ]
  }")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] || [ "$code" = "201" ]; then
    pass "POST CodeSystem (setup) → HTTP $code"
else
    fail "POST CodeSystem setup failed (HTTP $code)"
fi

# Test 7: CodeSystem/$lookup by ID → readResourceJsonById
print_req "GET" "$BASE_URL/CodeSystem/$CS_ID/\$lookup?code=A01"
result=$(do_req GET "$BASE_URL/CodeSystem/$CS_ID/\$lookup?code=A01")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" != "500" ]; then
    pass "CodeSystem/$CS_ID/\$lookup by ID → readResourceJsonById called (HTTP $code, not 500)"
else
    fail "CodeSystem/$CS_ID/\$lookup by ID returned 500 — likely RESOURCE_JSON type error"
fi

# Test 8: CodeSystem/$lookup by system URL → readResourceJsonByColumn
print_req "GET" "$BASE_URL/CodeSystem/\$lookup?system=$CS_URL&code=A01"
result=$(do_req GET "$BASE_URL/CodeSystem/\$lookup?system=$CS_URL&code=A01")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" != "500" ]; then
    pass "CodeSystem/\$lookup by system URL → readResourceJsonByColumn called (HTTP $code, not 500)"
else
    fail "CodeSystem/\$lookup by system URL returned 500 — likely RESOURCE_JSON type error"
fi

# Test 9: Create ValueSet (setup)
print_req "POST" "$BASE_URL/ValueSet"
result=$(do_req POST "$BASE_URL/ValueSet" \
  -H "Content-Type: application/fhir+json" \
  -d "{
    \"resourceType\": \"ValueSet\",
    \"id\": \"$VS_ID\",
    \"url\": \"$VS_URL\",
    \"status\": \"active\",
    \"compose\": {
      \"include\": [
        {\"system\": \"$CS_URL\"}
      ]
    }
  }")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] || [ "$code" = "201" ]; then
    pass "POST ValueSet (setup) → HTTP $code"
else
    fail "POST ValueSet setup failed (HTTP $code)"
fi

# Test 10: ValueSet/$expand by ID → readResourceJsonById
print_req "GET" "$BASE_URL/ValueSet/$VS_ID/\$expand"
result=$(do_req GET "$BASE_URL/ValueSet/$VS_ID/\$expand")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" != "500" ]; then
    pass "ValueSet/$VS_ID/\$expand by ID → readResourceJsonById called (HTTP $code, not 500)"
else
    fail "ValueSet/$VS_ID/\$expand by ID returned 500 — likely RESOURCE_JSON type error"
fi

# Test 11: ValueSet/$expand by URL → readResourceJsonByColumn
print_req "GET" "$BASE_URL/ValueSet/\$expand?url=$VS_URL"
result=$(do_req GET "$BASE_URL/ValueSet/\$expand?url=$VS_URL")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" != "500" ]; then
    pass "ValueSet/\$expand by URL → readResourceJsonByColumn called (HTTP $code, not 500)"
else
    fail "ValueSet/\$expand by URL returned 500 — likely RESOURCE_JSON type error"
fi

# ─── summary ────────────────────────────────────────────────────────────────

echo ""
echo "======================================================================"
echo -e "${BOLD}Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
echo "======================================================================"
[ "$FAILED" -eq 0 ]
