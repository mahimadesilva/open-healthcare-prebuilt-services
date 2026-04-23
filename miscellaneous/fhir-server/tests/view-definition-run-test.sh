#!/bin/bash
# Tests the ViewDefinition/$run operation (SQL-on-FHIR).
# Covers:
#   - Parameters-wrapped ViewDefinition
#   - _format=csv rejection (400)
#   - viewReference rejection (400)
#   - Unknown resource type rejection (400)
#
# Requires the server to be running with dbType="postgresql".
# If the server is running on H2, every call returns 501 — the script
# checks for that and exits 0 with a clear message.
#
# Run with: bash tests/view-definition-run-test.sh

BASE_URL="http://localhost:9090/fhir/r4"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0

PATIENT_A="vd-run-test-pt-a"
PATIENT_B="vd-run-test-pt-b"

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
echo -e "${BOLD}FHIR ViewDefinition/\$run Tests${NC}"
echo "======================================================================"

# Probe: is the server on Postgres?
probe_body='{"resourceType":"Parameters","parameter":[{"name":"viewResource","resource":{"resourceType":"ViewDefinition","resource":"Patient","status":"active","select":[{"column":[{"name":"id","path":"id","type":"id"}]}]}}]}'
probe=$(do_req POST "$BASE_URL/ViewDefinition/\$run" \
  -H "Content-Type: application/fhir+json" \
  -d "$probe_body")
probe_code="${probe%%|*}"
if [ "$probe_code" = "501" ]; then
    echo -e "${YELLOW}Server is not configured for PostgreSQL (got 501). Skipping.${NC}"
    exit 0
fi

echo "Cleaning up any leftover test resources..."
curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$PATIENT_A" || true
curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$PATIENT_B" || true
echo ""

# ─── seed patients ──────────────────────────────────────────────────────────

print_req "POST" "$BASE_URL/Patient  [seed A]"
result=$(do_req POST "$BASE_URL/Patient" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Patient",
    "id": "'"$PATIENT_A"'",
    "active": true,
    "name": [{"family": "Alpha", "given": ["Ada"]}]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "201" ]; then pass "Seed Patient A"; else fail "Seed Patient A (HTTP $code)"; fi

print_req "POST" "$BASE_URL/Patient  [seed B]"
result=$(do_req POST "$BASE_URL/Patient" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Patient",
    "id": "'"$PATIENT_B"'",
    "active": false,
    "name": [{"family": "Beta", "given": ["Bob"]}]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "201" ]; then pass "Seed Patient B"; else fail "Seed Patient B (HTTP $code)"; fi

# ─── 1. Parameters-wrapped ViewDefinition ───────────────────────────────────

print_req "POST" "$BASE_URL/ViewDefinition/\$run  [Parameters wrapper]"
result=$(do_req POST "$BASE_URL/ViewDefinition/\$run" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Parameters",
    "parameter": [{
      "name": "viewResource",
      "resource": {
        "resourceType": "ViewDefinition",
        "resource": "Patient",
        "status": "active",
        "select": [{ "column": [
          {"name": "id",     "path": "id",                 "type": "id"},
          {"name": "family", "path": "name.family.first()", "type": "string"}
        ]}]
      }
    }]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] && echo "$body" | grep -q '"Alpha"' && echo "$body" | grep -q '"Beta"'; then
    pass "Parameters-wrapped run returns both patients"
else
    fail "Parameters-wrapped run (HTTP $code)"
fi

# ─── 2. _format=csv → 400 ───────────────────────────────────────────────────

print_req "POST" "$BASE_URL/ViewDefinition/\$run  [_format=csv expect 400]"
result=$(do_req POST "$BASE_URL/ViewDefinition/\$run" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Parameters",
    "parameter": [
      {"name": "_format", "valueCode": "csv"},
      {"name": "viewResource", "resource": {
        "resourceType": "ViewDefinition",
        "resource": "Patient",
        "status": "active",
        "select": [{"column":[{"name":"id","path":"id","type":"id"}]}]
      }}
    ]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "400" ]; then pass "_format=csv rejected with 400"; else fail "_format=csv (HTTP $code)"; fi

# ─── 3. viewReference → 400 ─────────────────────────────────────────────────

print_req "POST" "$BASE_URL/ViewDefinition/\$run  [viewReference expect 400]"
result=$(do_req POST "$BASE_URL/ViewDefinition/\$run" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Parameters",
    "parameter": [
      {"name": "viewReference", "valueReference": {"reference": "ViewDefinition/does-not-exist"}}
    ]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "400" ]; then pass "viewReference rejected with 400"; else fail "viewReference (HTTP $code)"; fi

# ─── 4. Unknown resource type → 400 ─────────────────────────────────────────

print_req "POST" "$BASE_URL/ViewDefinition/\$run  [resource=not-a-type expect 400]"
result=$(do_req POST "$BASE_URL/ViewDefinition/\$run" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Parameters",
    "parameter": [{
      "name": "viewResource",
      "resource": {
        "resourceType": "ViewDefinition",
        "resource": "not-a-type",
        "status": "active",
        "select": [{"column":[{"name":"id","path":"id","type":"id"}]}]
      }
    }]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "400" ]; then pass "Invalid resource name rejected with 400"; else fail "Invalid resource name (HTTP $code)"; fi

# ─── cleanup ────────────────────────────────────────────────────────────────

curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$PATIENT_A" || true
curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$PATIENT_B" || true

echo ""
echo "======================================================================"
echo -e "${BOLD}Results:${NC} ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}"
echo "======================================================================"
[ "$FAILED" -eq 0 ]
