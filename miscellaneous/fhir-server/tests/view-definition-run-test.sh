#!/bin/bash
# Tests the ViewDefinition/$run operation (SQL-on-FHIR).
# Covers:
#   - Parameters-wrapped ViewDefinition (DB path, PostgreSQL only)
#   - In-memory evaluation via resource[] parameter (any dbType)
#   - viewReference lookup + run
#   - _format=csv rejection (400)
#   - Unknown resource type rejection (400)
#
# Requires the server to be running.
# If the server is running on H2, DB-path tests are skipped (501); in-memory tests still run.
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
SKIPPED=0

PATIENT_A="vd-run-test-pt-a"
PATIENT_B="vd-run-test-pt-b"
VD_REF_ID="vd-run-ref-test-001"

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

pass()  { PASSED=$((PASSED+1));   echo -e "${GREEN}✓ PASS${NC}: $1"; }
fail()  { FAILED=$((FAILED+1));   echo -e "${RED}✗ FAIL${NC}: $1"; }
skip()  { SKIPPED=$((SKIPPED+1)); echo -e "${YELLOW}⊘ SKIP${NC}: $1"; }

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
IS_POSTGRES=true
if [ "$probe_code" = "501" ]; then
    echo -e "${YELLOW}Server is not configured for PostgreSQL (got 501). DB-path tests will be skipped.${NC}"
    IS_POSTGRES=false
fi

echo "Cleaning up any leftover test resources..."
curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$PATIENT_A"       || true
curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$PATIENT_B"       || true
curl -s -o /dev/null -X DELETE "$BASE_URL/ViewDefinition/$VD_REF_ID" || true
echo ""

# ─── 1. Parameters-wrapped ViewDefinition (DB path) ─────────────────────────

if [ "$IS_POSTGRES" = true ]; then
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

    print_req "POST" "$BASE_URL/ViewDefinition/\$run  [viewResource, DB path]"
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
        pass "viewResource DB path returns both patients"
    else
        fail "viewResource DB path (HTTP $code)"
    fi
else
    skip "viewResource DB path (not PostgreSQL)"
fi

# ─── 2. In-memory evaluation via resource[] ──────────────────────────────────

print_req "POST" "$BASE_URL/ViewDefinition/\$run  [in-memory resource[] evaluation]"
result=$(do_req POST "$BASE_URL/ViewDefinition/\$run" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Parameters",
    "parameter": [
      {
        "name": "viewResource",
        "resource": {
          "resourceType": "ViewDefinition",
          "resource": "Patient",
          "status": "active",
          "select": [{"column": [
            {"name": "id",     "path": "id",     "type": "id"},
            {"name": "active", "path": "active", "type": "boolean"}
          ]}]
        }
      },
      {
        "name": "resource",
        "resource": {"resourceType": "Patient", "id": "inline-pt-1", "active": true}
      },
      {
        "name": "resource",
        "resource": {"resourceType": "Patient", "id": "inline-pt-2", "active": false}
      }
    ]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] && echo "$body" | grep -q '"inline-pt-1"' && echo "$body" | grep -q '"inline-pt-2"'; then
    pass "In-memory resource[] evaluation returns both rows"
else
    fail "In-memory resource[] evaluation (HTTP $code)"
fi

# ─── 3. viewReference ────────────────────────────────────────────────────────

print_req "POST" "$BASE_URL/ViewDefinition  [create ViewDefinition for viewReference test]"
result=$(do_req POST "$BASE_URL/ViewDefinition" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "ViewDefinition",
    "id": "'"$VD_REF_ID"'",
    "name": "RunRefTestView",
    "status": "active",
    "resource": "Patient",
    "select": [{"column": [
      {"name": "id", "path": "id", "type": "id"}
    ]}]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "201" ]; then pass "Create ViewDefinition for viewReference"; else fail "Create ViewDefinition for viewReference (HTTP $code)"; fi

print_req "POST" "$BASE_URL/ViewDefinition/\$run  [viewReference + resource[] in-memory]"
result=$(do_req POST "$BASE_URL/ViewDefinition/\$run" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Parameters",
    "parameter": [
      {
        "name": "viewReference",
        "valueReference": {"reference": "ViewDefinition/'"$VD_REF_ID"'"}
      },
      {
        "name": "resource",
        "resource": {"resourceType": "Patient", "id": "ref-inline-pt-1"}
      }
    ]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "200" ] && echo "$body" | grep -q '"ref-inline-pt-1"'; then
    pass "viewReference + resource[] returns correct row"
else
    fail "viewReference + resource[] (HTTP $code)"
fi

# ─── 4. viewReference + viewResource → 400 ───────────────────────────────────

print_req "POST" "$BASE_URL/ViewDefinition/\$run  [viewReference + viewResource expect 400]"
result=$(do_req POST "$BASE_URL/ViewDefinition/\$run" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Parameters",
    "parameter": [
      {
        "name": "viewReference",
        "valueReference": {"reference": "ViewDefinition/some-id"}
      },
      {
        "name": "viewResource",
        "resource": {
          "resourceType": "ViewDefinition",
          "resource": "Patient",
          "status": "active",
          "select": [{"column":[{"name":"id","path":"id","type":"id"}]}]
        }
      }
    ]
  }')
code="${result%%|*}"; body="${result#*|}"
print_res "$code" "$body"
if [ "$code" = "400" ]; then pass "viewReference + viewResource rejected with 400"; else fail "viewReference + viewResource (HTTP $code)"; fi

# ─── 5. _format=csv → 400 ───────────────────────────────────────────────────

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

# ─── 6. Unknown resource type → 400 ─────────────────────────────────────────

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

curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$PATIENT_A"        || true
curl -s -o /dev/null -X DELETE "$BASE_URL/Patient/$PATIENT_B"        || true
curl -s -o /dev/null -X DELETE "$BASE_URL/ViewDefinition/$VD_REF_ID" || true

echo ""
echo "======================================================================"
echo -e "${BOLD}Results:${NC} ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}, ${YELLOW}${SKIPPED} skipped${NC}"
echo "======================================================================"
[ "$FAILED" -eq 0 ]
