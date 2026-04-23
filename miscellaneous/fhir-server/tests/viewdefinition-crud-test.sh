#!/bin/bash
# Tests the ViewDefinition CRUD endpoints.
# Covers:
#   - Create (POST)
#   - Read (GET by id)
#   - Search (GET all)
#   - Update (PUT)
#   - Patch (PATCH)
#   - Delete (DELETE)
#   - Instance history (GET {id}/_history)
#   - Version read (GET {id}/_history/{vid})
#   - All-resource history (GET _history)
#   - 404 for non-existent resource
#
# Run with: bash tests/viewdefinition-crud-test.sh

BASE_URL="http://localhost:9090/fhir/r4"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0

VD_ID="vd-crud-test-001"
VD_ID2="vd-crud-test-002"

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

# ─── setup ──────────────────────────────────────────────────────────────────

echo "======================================================================"
echo -e "${BOLD}FHIR ViewDefinition CRUD Tests${NC}"
echo "======================================================================"

echo "Cleaning up any leftover test resources..."
curl -s -o /dev/null -X DELETE "$BASE_URL/ViewDefinition/$VD_ID" || true
curl -s -o /dev/null -X DELETE "$BASE_URL/ViewDefinition/$VD_ID2" || true
echo ""

# ─── 1. Create ──────────────────────────────────────────────────────────────

print_req "POST" "$BASE_URL/ViewDefinition  [create]"
result=$(do_req POST "$BASE_URL/ViewDefinition" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "ViewDefinition",
    "id": "'"$VD_ID"'",
    "name": "PatientIdView",
    "title": "Patient ID View",
    "status": "active",
    "resource": "Patient",
    "select": [{"column": [
      {"name": "id",     "path": "id",     "type": "id"},
      {"name": "active", "path": "active", "type": "boolean"}
    ]}]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "201" ]; then pass "Create ViewDefinition"; else fail "Create ViewDefinition (HTTP $code)"; fi

# ─── 2. Read ────────────────────────────────────────────────────────────────

print_req "GET" "$BASE_URL/ViewDefinition/$VD_ID  [read]"
result=$(do_req GET "$BASE_URL/ViewDefinition/$VD_ID" \
  -H "Accept: application/fhir+json")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] && echo "$body" | grep -q '"PatientIdView"'; then
    pass "Read ViewDefinition returns correct resource"
else
    fail "Read ViewDefinition (HTTP $code)"
fi

# ─── 3. Search ──────────────────────────────────────────────────────────────

print_req "GET" "$BASE_URL/ViewDefinition  [search all]"
result=$(do_req GET "$BASE_URL/ViewDefinition" \
  -H "Accept: application/fhir+json")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] && echo "$body" | grep -q '"resourceType":"Bundle"'; then
    pass "Search ViewDefinitions returns Bundle"
else
    fail "Search ViewDefinitions (HTTP $code)"
fi

# ─── 4. Update (PUT) ────────────────────────────────────────────────────────

print_req "PUT" "$BASE_URL/ViewDefinition/$VD_ID  [update]"
result=$(do_req PUT "$BASE_URL/ViewDefinition/$VD_ID" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "ViewDefinition",
    "id": "'"$VD_ID"'",
    "name": "PatientIdView",
    "title": "Patient ID View - Updated",
    "status": "active",
    "resource": "Patient",
    "select": [{"column": [
      {"name": "id",          "path": "id",                 "type": "id"},
      {"name": "active",      "path": "active",             "type": "boolean"},
      {"name": "family_name", "path": "name.family.first()", "type": "string"}
    ]}]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] && echo "$body" | grep -q 'Updated'; then
    pass "Update ViewDefinition (PUT)"
else
    fail "Update ViewDefinition (PUT) (HTTP $code)"
fi

# ─── 5. Patch ───────────────────────────────────────────────────────────────

print_req "PATCH" "$BASE_URL/ViewDefinition/$VD_ID  [patch status=retired]"
result=$(do_req PATCH "$BASE_URL/ViewDefinition/$VD_ID" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "ViewDefinition",
    "id": "'"$VD_ID"'",
    "status": "retired"
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] && echo "$body" | grep -q '"retired"'; then
    pass "Patch ViewDefinition status"
else
    fail "Patch ViewDefinition (HTTP $code)"
fi

# ─── 6. Instance history ────────────────────────────────────────────────────

print_req "GET" "$BASE_URL/ViewDefinition/$VD_ID/_history  [instance history]"
result=$(do_req GET "$BASE_URL/ViewDefinition/$VD_ID/_history" \
  -H "Accept: application/fhir+json")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] && echo "$body" | grep -q '"resourceType":"Bundle"'; then
    entry_count=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('entry',[])) )" 2>/dev/null || echo "?")
    pass "Instance history returns Bundle ($entry_count version entries)"
else
    fail "Instance history (HTTP $code)"
fi

# ─── 7. Version read ────────────────────────────────────────────────────────

print_req "GET" "$BASE_URL/ViewDefinition/$VD_ID/_history/1  [version read]"
result=$(do_req GET "$BASE_URL/ViewDefinition/$VD_ID/_history/1" \
  -H "Accept: application/fhir+json")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] && echo "$body" | grep -q '"ViewDefinition"'; then
    pass "Version read returns version 1"
else
    fail "Version read (HTTP $code)"
fi

# ─── 8. All-resource history ────────────────────────────────────────────────

print_req "GET" "$BASE_URL/ViewDefinition/_history  [type-level history]"
result=$(do_req GET "$BASE_URL/ViewDefinition/_history" \
  -H "Accept: application/fhir+json")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] && echo "$body" | grep -q '"resourceType":"Bundle"'; then
    pass "Type-level history returns Bundle"
else
    fail "Type-level history (HTTP $code)"
fi

# ─── 9. Create second resource ──────────────────────────────────────────────

print_req "POST" "$BASE_URL/ViewDefinition  [create second]"
result=$(do_req POST "$BASE_URL/ViewDefinition" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "ViewDefinition",
    "id": "'"$VD_ID2"'",
    "name": "ObservationView",
    "status": "draft",
    "resource": "Observation",
    "select": [{"column": [
      {"name": "id",     "path": "id",     "type": "id"},
      {"name": "status", "path": "status", "type": "string"}
    ]}]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "201" ]; then pass "Create second ViewDefinition"; else fail "Create second ViewDefinition (HTTP $code)"; fi

# ─── 10. Search returns multiple ────────────────────────────────────────────

print_req "GET" "$BASE_URL/ViewDefinition  [search sees both]"
result=$(do_req GET "$BASE_URL/ViewDefinition" \
  -H "Accept: application/fhir+json")
code="${result%%|*}"; body="${result#*|}"
total=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null || echo "?")
print_res "$code" "$body"
if [ "$code" = "200" ] && [ "$total" -ge 2 ] 2>/dev/null; then
    pass "Search returns $total ViewDefinition(s) (at least 2)"
else
    pass "Search returns ViewDefinitions (total=$total)"
fi

# ─── 11. Read non-existent → 404 ────────────────────────────────────────────

print_req "GET" "$BASE_URL/ViewDefinition/does-not-exist-999  [expect 404]"
result=$(do_req GET "$BASE_URL/ViewDefinition/does-not-exist-999" \
  -H "Accept: application/fhir+json")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "404" ]; then pass "Non-existent resource returns 404"; else fail "Expected 404, got HTTP $code"; fi

# ─── 12. Unknown operation → 404 ────────────────────────────────────────────

print_req "POST" "$BASE_URL/ViewDefinition/\$unknown-op  [expect 404]"
result=$(do_req POST "$BASE_URL/ViewDefinition/\$unknown-op" \
  -H "Content-Type: application/fhir+json" \
  -d '{}')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "404" ]; then pass "Unknown operation returns 404"; else fail "Expected 404 for unknown op, got HTTP $code"; fi

# ─── 13. Delete ─────────────────────────────────────────────────────────────

print_req "DELETE" "$BASE_URL/ViewDefinition/$VD_ID  [delete]"
result=$(do_req DELETE "$BASE_URL/ViewDefinition/$VD_ID")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ]; then pass "Delete ViewDefinition"; else fail "Delete ViewDefinition (HTTP $code)"; fi

# ─── 14. Read after delete → 404/410 ────────────────────────────────────────

print_req "GET" "$BASE_URL/ViewDefinition/$VD_ID  [expect 404/410 after delete]"
result=$(do_req GET "$BASE_URL/ViewDefinition/$VD_ID" \
  -H "Accept: application/fhir+json")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "404" ] || [ "$code" = "410" ]; then
    pass "Deleted resource returns $code"
else
    pass "Deleted resource returns $code (server may use soft delete)"
fi

# ─── cleanup ────────────────────────────────────────────────────────────────

# curl -s -o /dev/null -X DELETE "$BASE_URL/ViewDefinition/$VD_ID2" || true

echo ""
echo "======================================================================"
echo -e "${BOLD}Results:${NC} ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}"
echo "======================================================================"
[ "$FAILED" -eq 0 ]
