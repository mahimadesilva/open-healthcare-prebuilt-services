#!/bin/bash
# Tests all endpoints affected by the RESOURCE_JSON byte[]→JSONB change:
#   history_handler  → GET /_history, GET /_history/{version}
#   update_handler   → PATCH (reads RESOURCE_JSON before merging)
#   read_mapper      → GET /{id}, GET / (search), GET /?* (search with params)
#
# History is fetched after every mutating operation (POST/PUT/PATCH/DELETE)
# so you can compare the growing version list across commits.
#
# Assumes the server is already running on localhost:9090.
# Run with: bash tests/history-test.sh

BASE_URL="http://localhost:9090/fhir/r4"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0
RES_ID="hist-test-patient-001"

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

get_history() {
    local label="$1"
    local expected="$2"
    print_req "GET" "$BASE_URL/Patient/$RES_ID/_history  ← $label"
    local result; result=$(do_req GET "$BASE_URL/Patient/$RES_ID/_history")
    local code="${result%%|*}"; local body="${result#*|}"
    print_res "$code" "$body"
    if [ "$code" != "200" ]; then
        fail "History after $label (HTTP $code)"
        return
    fi
    local cnt; cnt=$(echo "$body" | grep -o '"versionId"' | wc -l | tr -d ' ')
    if [ -n "$expected" ] && [ "$cnt" != "$expected" ]; then
        fail "History after $label: expected $expected entries, got $cnt"
    else
        pass "History after $label ($cnt version(s))"
    fi
}

# ─── setup ──────────────────────────────────────────────────────────────────

echo "======================================================================"
echo -e "${BOLD}FHIR History + Read Endpoint Tests${NC}"
echo "======================================================================"
echo "Cleaning up any leftover test resource..."
curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$RES_ID" || true
echo ""

# ─── 1. CREATE ──────────────────────────────────────────────────────────────

print_req "POST" "$BASE_URL/Patient  [create v1]"
result=$(do_req POST "$BASE_URL/Patient" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Patient",
    "id": "'"$RES_ID"'",
    "active": true,
    "name": [{"family": "HistoryTest", "given": ["Alice"]}],
    "gender": "female",
    "birthDate": "1990-01-01"
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "201" ]; then pass "Create Patient (v1)"; else fail "Create Patient (HTTP $code)"; fi

get_history "POST (expect 1 entry)" 1

# ─── 2. READ ────────────────────────────────────────────────────────────────

print_req "GET" "$BASE_URL/Patient/$RES_ID  [readResourceById]"
result=$(do_req GET "$BASE_URL/Patient/$RES_ID")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ]; then pass "Read Patient by ID"; else fail "Read Patient (HTTP $code)"; fi

# ─── 3. SEARCH with filter ──────────────────────────────────────────────────

print_req "GET" "$BASE_URL/Patient?name=HistoryTest  [searchResources]"
result=$(do_req GET "$BASE_URL/Patient?name=HistoryTest")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ]; then pass "Search Patient by name"; else fail "Search Patient (HTTP $code)"; fi

# ─── 4. SEARCH all ──────────────────────────────────────────────────────────

print_req "GET" "$BASE_URL/Patient  [getAllResources]"
result=$(do_req GET "$BASE_URL/Patient")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ]; then pass "Get all Patients"; else fail "Get all Patients (HTTP $code)"; fi

# ─── 5. PUT (v2) ────────────────────────────────────────────────────────────

print_req "PUT" "$BASE_URL/Patient/$RES_ID  [update → v2]"
result=$(do_req PUT "$BASE_URL/Patient/$RES_ID" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Patient",
    "id": "'"$RES_ID"'",
    "active": true,
    "name": [{"family": "HistoryTest", "given": ["Alice", "Updated"]}],
    "gender": "female",
    "birthDate": "1990-01-01"
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ]; then pass "PUT Patient (v2)"; else fail "PUT Patient (HTTP $code)"; fi

get_history "PUT (expect 2 entries)" 2

# ─── 6. PATCH (v3) ──────────────────────────────────────────────────────────

print_req "PATCH" "$BASE_URL/Patient/$RES_ID  [getResourceAsJson → v3]"
result=$(do_req PATCH "$BASE_URL/Patient/$RES_ID" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Patient",
    "id": "'"$RES_ID"'",
    "active": false
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ]; then pass "PATCH Patient (v3)"; else fail "PATCH Patient (HTTP $code)"; fi

get_history "PATCH (expect 3 entries)" 3

# ─── 7. version reads ───────────────────────────────────────────────────────

for v in 1 2 3; do
    print_req "GET" "$BASE_URL/Patient/$RES_ID/_history/$v  [getResourceVersion v$v]"
    result=$(do_req GET "$BASE_URL/Patient/$RES_ID/_history/$v")
    code="${result%%|*}"; body="${result#*|}"
    print_res "$code" "$body"
    if [ "$code" = "200" ]; then
        vid=$(echo "$body" | grep -o '"versionId":"[^"]*"' | head -1)
        pass "Get version $v ($vid)"
    else
        fail "Get version $v (HTTP $code)"
    fi
done

# ─── 8. type-level history ──────────────────────────────────────────────────

print_req "GET" "$BASE_URL/Patient/_history  [getAllHistory for type]"
result=$(do_req GET "$BASE_URL/Patient/_history")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ]; then pass "Type-level history"; else fail "Type-level history (HTTP $code)"; fi

# ─── 9. DELETE ──────────────────────────────────────────────────────────────

print_req "DELETE" "$BASE_URL/Patient/$RES_ID  [delete → v4]"
result=$(do_req DELETE "$BASE_URL/Patient/$RES_ID")
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ]; then pass "Delete Patient (v4)"; else fail "Delete Patient (HTTP $code)"; fi

get_history "DELETE (expect 4 entries)" 4

# ─── summary ────────────────────────────────────────────────────────────────

echo ""
echo "======================================================================"
echo -e "${BOLD}Summary${NC}"
echo "======================================================================"
echo -e "${GREEN}Passed: $PASSED${NC}"
if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
fi
