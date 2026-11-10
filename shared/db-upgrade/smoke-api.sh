#!/usr/bin/env bash
# API smoke test of an OpenLMIS Gambia environment. Run it before the database upgrade and
# again after, then diff the two outputs:
#   BASE_URL=https://uat.elmis.apps.moh.gm ADMIN_USER=admin ADMIN_PASS=... PROGRAM='Essential Medicines' FACILITY=GCMS REQ_FACILITY=WHR1HCC15 SMOKE_WRITES=1 ./smoke-api.sh | tee smoke-pg14.txt
# Needs curl + jq. Read-only unless SMOKE_WRITES=1, which adds a requisition up to submit at
# REQ_FACILITY, two stock adjustments that cancel out, a physical inventory draft that is
# deleted, a facility update that is reverted and (with a service token) a notification; the
# submitted requisition stays behind, so on prod run read-only or against a test facility.
# IDS_FILE=<path> records the ids the write flows touched. CHECK_LOGS=1 adds a SQL-error scan
# of the compose containers (only on the host). PASS/FAIL lines carry no ids, so two runs diff cleanly.
set -uo pipefail

: "${BASE_URL:?e.g. https://uat.elmis.apps.moh.gm}"
: "${ADMIN_PASS:?password of ADMIN_USER}"
: "${PROGRAM:?program name, e.g. Essential Medicines}"
: "${FACILITY:?code of a facility the admin has requisition and stock rights for}"
ADMIN_USER=${ADMIN_USER:-administrator}
CLIENT_ID=${CLIENT_ID:-user-client}
CLIENT_SECRET=${CLIENT_SECRET:-changeme}
SERVICE_CLIENT_ID=${SERVICE_CLIENT_ID:-}          # e.g. trusted-client; enables the service-token checks
SERVICE_CLIENT_SECRET=${SERVICE_CLIENT_SECRET:-}
REQ_FACILITY=${REQ_FACILITY:-$FACILITY}           # code of the facility that requisitions (when FACILITY itself has no schedule)
SUPPLYING_DEPOT=${SUPPLYING_DEPOT:-}              # facility code; default: first depot the requisition offers
TEST_USER=${TEST_USER:-}                          # password reset round-trip; skipped when unset
TEST_USER_PASS=${TEST_USER_PASS:-}
REPORT_PARAMS=${REPORT_PARAMS:-}                  # query string for every Jasper PDF; default built below from PROGRAM/FACILITY
LINE_ITEM_PATCH=${LINE_ITEM_PATCH:-'{beginningBalance: 0, totalReceivedQuantity: 0, totalConsumedQuantity: 0, totalLossesAndAdjustments: 0, totalStockoutDays: 0, stockOnHand: 0, requestedQuantity: null, requestedQuantityExplanation: null, skipped: false}'}  # Gambia template: all USER_INPUT columns, requestedQuantity hidden (calculated order quantity is used)
SMOKE_WRITES=${SMOKE_WRITES:-0}
CHECK_LOGS=${CHECK_LOGS:-0}
LOG_SINCE=${LOG_SINCE:-30m}
COMPOSE_PROJECT=${COMPOSE_PROJECT:-uat}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TODAY=$(date -u +%F)
PASS=0; FAIL=0; SKIP=0; RESULTS=()
AUTH=none
JSON=(-H 'Content-Type: application/json')
CNT='if type == "array" then length else (.totalElements // (.content | length)) end'

req() { local m=$1 p=$2; shift 2; curl -s --max-time 300 -o "$TMP/body" -w "%{http_code}${W:-}" -X "$m" -H "Authorization: $AUTH" "$@" "$BASE_URL$p"; }
ids() { [ -n "${IDS_FILE:-}" ] && echo "$*" >> "$IDS_FILE"; return 0; }
token() { curl -s --max-time 60 -o "$TMP/body" -w '%{http_code}' -u "$1:$2" -X POST "$BASE_URL/api/oauth/token" "${@:3}"; }
jqb() { jq -r "$@" "$TMP/body" 2>/dev/null; }
err() { jqb '[.. | objects | .messageKey? // empty] | first // empty' | head -c 160; }
check() {  # check <name> <expected code regex> <code> [detail]
  local line
  if [[ $3 =~ ^($2)$ ]]; then PASS=$((PASS + 1)); line="PASS $3 $1 ${4:-}"; else FAIL=$((FAIL + 1)); line="FAIL $3 $1 ${4:-} $(err)"; fi
  RESULTS+=("$line"); echo "$line"
}
skip() { SKIP=$((SKIP + 1)); RESULTS+=("SKIP -   $1 ($2)"); echo "SKIP -   $1 ($2)"; }
writes() { [ "$SMOKE_WRITES" = 1 ]; }
section() { echo; echo "=== $* ==="; }
found() { [ -n "$1" ] && echo found || echo MISSING; }

section "1 auth"
code=$(token "$CLIENT_ID" "$CLIENT_SECRET" -d grant_type=password --data-urlencode "username=$ADMIN_USER" --data-urlencode "password=$ADMIN_PASS")
TOKEN=$(jqb '.access_token // empty'); AUTH="Bearer $TOKEN"
check auth.token.password 200 "$code"
[ -n "$TOKEN" ] || { echo "no token, aborting"; exit 1; }
STOKEN=""
if [ -n "$SERVICE_CLIENT_ID" ]; then
  code=$(token "$SERVICE_CLIENT_ID" "$SERVICE_CLIENT_SECRET" -d grant_type=client_credentials); STOKEN=$(jqb '.access_token // empty')
  check auth.token.client_credentials 200 "$code"
else skip auth.token.client_credentials "SERVICE_CLIENT_ID unset"; fi
code=$(req GET "/api/users?username=$ADMIN_USER"); ADMIN_ID=$(jqb '.content[0].id // empty'); check auth.users.admin 200 "$code" "admin=$(found "$ADMIN_ID")"
if [ -n "$TEST_USER" ] && [ -n "$TEST_USER_PASS" ] && writes; then
  NEWPW="Pg17smoke$(date +%s)"
  code=$(req POST /api/users/auth/passwordReset "${JSON[@]}" -d "{\"username\":\"$TEST_USER\",\"newPassword\":\"$NEWPW\"}"); check auth.passwordReset 200 "$code"
  code=$(token "$CLIENT_ID" "$CLIENT_SECRET" -d grant_type=password --data-urlencode "username=$TEST_USER" --data-urlencode "password=$NEWPW"); check auth.login.newPassword 200 "$code"
  code=$(req POST /api/users/auth/passwordReset "${JSON[@]}" -d "{\"username\":\"$TEST_USER\",\"newPassword\":\"$TEST_USER_PASS\"}"); check auth.passwordReset.restore 200 "$code"
else skip auth.passwordReset "TEST_USER/TEST_USER_PASS unset or SMOKE_WRITES=0"; fi

section "2 referencedata"
code=$(req GET /api/programs); PROG_ID=$(jqb --arg n "$PROGRAM" '[.[] | select(.name == $n)][0].id // empty'); check ref.programs 200 "$code" "count=$(jqb length) program=$(found "$PROG_ID")"
code=$(req GET "/api/facilities?code=$FACILITY"); FAC_ID=$(jqb --arg c "$FACILITY" '[.content[] | select(.code == $c)][0].id // empty'); FTYPE_ID=$(jqb --arg c "$FACILITY" '[.content[] | select(.code == $c)][0].type.id // empty'); check ref.facilities.byCode 200 "$code" "facility=$(found "$FAC_ID")"
[ -n "$PROG_ID" ] && [ -n "$FAC_ID" ] || { echo "PROGRAM/FACILITY not resolved, aborting"; exit 1; }
REQ_FAC_ID=$FAC_ID
if [ "$REQ_FACILITY" != "$FACILITY" ]; then req GET "/api/facilities?code=$REQ_FACILITY" >/dev/null; REQ_FAC_ID=$(jqb --arg c "$REQ_FACILITY" '[.content[] | select(.code == $c)][0].id // empty'); fi
for r in orderables facilities geographicZones supervisoryNodes requisitionGroups; do code=$(req GET "/api/$r?size=1"); check "ref.$r" 200 "$code" "total=$(jqb "$CNT")"; done
code=$(req GET /api/roles); check ref.roles 200 "$code" "count=$(jqb "$CNT")"
code=$(req GET "/api/users/$ADMIN_ID/permissionStrings"); check ref.permissionStrings 200 "$code" "count=$(jqb "$CNT")"
if writes; then
  req GET "/api/facilities/$FAC_ID" >/dev/null; cp "$TMP/body" "$TMP/facility.json"
  jq '.description = "pg17 smoke"' "$TMP/facility.json" > "$TMP/facility-upd.json"
  code=$(req PUT "/api/facilities/$FAC_ID" "${JSON[@]}" -d @"$TMP/facility-upd.json"); check ref.facility.put 200 "$code"
  code=$(req GET "/api/facilities/$FAC_ID"); check ref.facility.get 200 "$code" "description=$(jqb .description)"
  code=$(req PUT "/api/facilities/$FAC_ID" "${JSON[@]}" -d @"$TMP/facility.json"); check ref.facility.restore 200 "$code"
  code=$(req GET "/api/facilities/$FAC_ID"); check ref.facility.roundtrip 200 "$code" "identical=$(cmp -s <(jq -S . "$TMP/facility.json") <(jq -S . "$TMP/body") && echo yes || echo no)"
else skip ref.facility.put "SMOKE_WRITES=0"; fi

section "3 requisition"
RID=""
if writes; then
  code=$(req GET "/api/requisitions/periodsForInitiate?programId=$PROG_ID&facilityId=$REQ_FAC_ID&emergency=false"); PER=$(jqb '.[0].id // empty'); check req.periodsForInitiate 200 "$code" "periods=$(jqb "$CNT") reqFacility=$(found "$REQ_FAC_ID")"
  req GET "/api/requisitions/search?facility=$REQ_FAC_ID&program=$PROG_ID&requisitionStatus=INITIATED&emergency=false&size=1" >/dev/null; RID=$(jqb '.content[0].id // empty')
  if [ -n "$RID" ]; then
    code=$(req GET "/api/requisitions/$RID"); check req.reuse 200 "$code" "INITIATED regular requisition reused, lineItems=$(jqb '.requisitionLineItems | length')"
  else
    code=$(req POST "/api/requisitions/initiate?program=$PROG_ID&facility=$REQ_FAC_ID&suggestedPeriod=$PER&emergency=false"); RID=$(jqb '.id // empty')
    check req.initiate 201 "$code" "lineItems=$(jqb '.requisitionLineItems | length')"
  fi
  ids "requisition=$RID"
fi
if [ -n "$RID" ]; then
  jq ".requisitionLineItems |= map(. + $LINE_ITEM_PATCH)" "$TMP/body" > "$TMP/req.json"
  code=$(req PUT "/api/requisitions/$RID" "${JSON[@]}" -d @"$TMP/req.json"); check req.update 200 "$code"
  for a in submit authorize approve; do code=$(req POST "/api/requisitions/$RID/$a"); check "req.$a" 200 "$code" "status=$(jqb '.status // empty')"; done
  code=$(req GET "/api/requisitions/search?facility=$REQ_FAC_ID&program=$PROG_ID&size=1"); check req.search 200 "$code" "total=$(jqb "$CNT")"
  code=$(W=' %{content_type} %{size_download}' req GET "/api/requisitions/$RID/print"); check req.print "200 application/pdf.* [1-9][0-9]*" "$code"
  DEPOT_ID=""
  if [ -n "$SUPPLYING_DEPOT" ]; then req GET "/api/facilities?code=$SUPPLYING_DEPOT" >/dev/null; DEPOT_ID=$(jqb --arg c "$SUPPLYING_DEPOT" '[.content[] | select(.code == $c)][0].id // empty'); fi
  if [ -z "$DEPOT_ID" ]; then req GET "/api/requisitions/$RID" >/dev/null; DEPOT_ID=$(jqb '.availableSupplyingDepots[0].id // empty'); fi
  code=$(req POST /api/requisitions/convertToOrder "${JSON[@]}" -d "[{\"requisitionId\":\"$RID\",\"supplyingDepotId\":\"$DEPOT_ID\"}]"); check req.convertToOrder 201 "$code" "depot=$(found "$DEPOT_ID")"
  code=$(req GET "/api/requisitions/$RID"); check req.get 200 "$code" "status=$(jqb .status)"
else skip req.cycle "SMOKE_WRITES=0 or initiate failed"; fi

section "4 fulfillment"
code=$(req GET "/api/orders?requestingFacilityId=$REQ_FAC_ID&programId=$PROG_ID&size=100"); ORDER_ID=""
[ -n "$RID" ] && ORDER_ID=$(jqb --arg r "$RID" '[.content[] | select(.externalId == $r)][0].id // empty')
check ful.orders 200 "$code" "total=$(jqb "$CNT") orderOfTestRequisition=$([ -n "$RID" ] && found "$ORDER_ID" || echo n/a)"
[ -n "$ORDER_ID" ] || ORDER_ID=$(jqb '.content[0].id // empty')
if [ -n "$ORDER_ID" ]; then
  code=$(W=' %{content_type} %{size_download}' req GET "/api/orders/$ORDER_ID/print?format=pdf"); check ful.order.print "200 application/pdf.* [1-9][0-9]*" "$code"
  code=$(req GET "/api/proofsOfDelivery?orderId=$ORDER_ID"); check ful.pods 200 "$code" "count=$(jqb "$CNT")"
  code=$(req GET "/api/shipments?orderId=$ORDER_ID"); check ful.shipments 200 "$code" "count=$(jqb "$CNT")"
else skip ful.order.print "no order for FACILITY/PROGRAM"; fi

section "5 stockmanagement"
code=$(req GET "/api/v2/stockCardSummaries?programId=$PROG_ID&facilityId=$FAC_ID&nonEmptyOnly=true&size=500"); check stock.summaries 200 "$code" "total=$(jqb "$CNT")"
SC=$(jqb '[.content[].canFulfillForMe[]? | select(.stockOnHand > 0)][0] // empty | {card: .stockCard.id, orderable: .orderable.id, lot: (.lot.id // "")} | @json')
if [ -n "$SC" ]; then
  SC_ID=$(jq -r .card <<<"$SC"); ORD_ID=$(jq -r .orderable <<<"$SC"); LOT_ID=$(jq -r .lot <<<"$SC")
  code=$(req GET "/api/stockCards/$SC_ID"); SOH0=$(jqb .stockOnHand); LI0=$(jqb '.lineItems | length'); check stock.card 200 "$code"
  if writes; then
    req GET "/api/validReasons?program=$PROG_ID&facilityType=$FTYPE_ID" >/dev/null
    CREDIT=$(jqb '[.[] | select((.hidden // false | not) and .reason.reasonCategory == "ADJUSTMENT" and .reason.reasonType == "CREDIT")][0].reason.id // empty')
    DEBIT=$(jqb '[.[] | select((.hidden // false | not) and .reason.reasonCategory == "ADJUSTMENT" and .reason.reasonType == "DEBIT")][0].reason.id // empty')
    ids "stockCard=$SC_ID orderable=$ORD_ID lot=$LOT_ID creditReason=$CREDIT debitReason=$DEBIT"
    # an event line without reason/source/destination is a physical inventory and would SET the stock on hand
    [ -n "$CREDIT" ] && [ -n "$DEBIT" ] || { skip stock.event "no ADJUSTMENT credit+debit reason for program/facility type"; CREDIT=; DEBIT=; }
    for r in "$CREDIT" "$DEBIT"; do [ -n "$r" ] || continue
      jq -n --arg f "$FAC_ID" --arg p "$PROG_ID" --arg o "$ORD_ID" --arg l "$LOT_ID" --arg r "$r" --arg d "$TODAY" \
        '{facilityId: $f, programId: $p, lineItems: [({orderableId: $o, quantity: 1, occurredDate: $d, reasonId: $r} + (if $l == "" then {} else {lotId: $l} end))]}' > "$TMP/event.json"
      code=$(req POST /api/stockEvents "${JSON[@]}" -d @"$TMP/event.json"); check stock.event 201 "$code" "$([ "$r" = "$CREDIT" ] && echo credit || echo debit) reason=$(found "$r")"
    done
    code=$(req GET "/api/stockCards/$SC_ID"); LI1=$(jqb '.lineItems | length'); check stock.card.after 200 "$code" "soh=$(jqb .stockOnHand) before=$SOH0 lineItems+=$(( ${LI1:-0} - ${LI0:-0} ))"
    code=$(req POST /api/physicalInventories "${JSON[@]}" -d "{\"facilityId\":\"$FAC_ID\",\"programId\":\"$PROG_ID\",\"isDraft\":true}"); PI_ID=$(jqb '.id // empty'); check stock.physicalInventory.draft 201 "$code"
    if [ -n "$PI_ID" ]; then code=$(req DELETE "/api/physicalInventories/$PI_ID"); check stock.physicalInventory.delete 204 "$code"; fi
  else skip stock.event "SMOKE_WRITES=0"; fi
else skip stock.card "no stock card with stock on hand for FACILITY/PROGRAM"; fi
code=$(req GET "/api/validSources?programId=$PROG_ID&facilityId=$FAC_ID"); check stock.validSources 200 "$code" "count=$(jqb "$CNT")"
code=$(req GET "/api/validDestinations?programId=$PROG_ID&facilityId=$FAC_ID"); check stock.validDestinations 200 "$code" "count=$(jqb "$CNT")"
code=$(req GET "/api/stockCardRangeSummaries?programId=$PROG_ID&facilityId=$FAC_ID&startDate=$(date -u -d '-30 days' +%F)&endDate=$TODAY"); check stock.rangeSummaries 200 "$code" "count=$(jqb "$CNT")"

section "6 notification"
if writes && [ -n "$STOKEN" ]; then
  USER_AUTH=$AUTH; AUTH="Bearer $STOKEN"
  code=$(req POST /api/notifications "${JSON[@]}" -d "{\"userId\":\"$ADMIN_ID\",\"messages\":{\"email\":{\"subject\":\"pg17 smoke\",\"body\":\"pg17 smoke $TODAY\"}}}"); check notif.post "200|201" "$code"
  AUTH=$USER_AUTH
else skip notif.post "SMOKE_WRITES=0 or SERVICE_CLIENT_ID unset (needs a service token)"; fi
code=$(req GET "/api/userContactDetails/$ADMIN_ID"); check notif.userContactDetails 200 "$code"

section "7 reports"
# Every parameter name the Gambia templates use (report.template_parameters); Jasper ignores the extra ones.
if [ -z "$REPORT_PARAMS" ]; then
  D0=$(date -u -d '-30 days' +%F)
  REPORT_PARAMS="program=$PROG_ID&program_name=$PROG_ID&facility=$FAC_ID&supplying_facility=$FAC_ID&supplyingFacility=$FAC_ID&receiving_facility=$FAC_ID&dateFrom=$D0&dateTo=$TODAY&date_from=$D0&date_to=$TODAY&from_date=$D0&to_date=$TODAY&startDate=$D0&endDate=$TODAY&date=$TODAY"
fi
code=$(req GET /api/reports/templates/common); check report.templates 200 "$code" "count=$(jqb "$CNT")"
jqb '.[] | [.id, .name] | @tsv' | sort -t $'\t' -k2 > "$TMP/templates.tsv"
while IFS=$'\t' read -r id name; do
  code=$(W=' %{size_download}' req GET "/api/reports/templates/common/$id/pdf?$REPORT_PARAMS")
  check "report.pdf[$name]" "[234][0-9][0-9] [0-9]+" "$code"
done < "$TMP/templates.tsv"
code=$(req GET /api/reports/dashboardReports); check report.dashboardReports 200 "$code" "count=$(jqb "$CNT")"

section "8 cce"
code=$(req GET "/api/inventoryItems?facilityId=$FAC_ID&programId=$PROG_ID&size=5"); ITEM_ID=$(jqb '.content[0].id // empty'); check cce.inventoryItems 200 "$code" "total=$(jqb "$CNT")"
if [ -n "$ITEM_ID" ] && writes; then
  req GET "/api/inventoryItems/$ITEM_ID" >/dev/null; cp "$TMP/body" "$TMP/item.json"
  code=$(req PUT "/api/inventoryItems/$ITEM_ID" "${JSON[@]}" -d @"$TMP/item.json"); check cce.inventoryItem.put 200 "$code"
else skip cce.inventoryItem.put "no CCE item at FACILITY or SMOKE_WRITES=0"; fi
code=$(req GET "/api/catalogItems?size=1"); check cce.catalogItems 200 "$code" "total=$(jqb "$CNT")"

section "9 buq"
code=$(req GET "/api/bottomUpQuantifications?size=5"); check buq.list "200|403" "$code" "total=$(jqb "$CNT")"
code=$(req GET "/api/sourcesOfFunds?size=5"); check buq.sourcesOfFunds 200 "$code" "total=$(jqb "$CNT")"

section "10 diagnostics, 11 ui"
code=$(req GET /diagnostics); check diagnostics.version "200|403" "$code" "version=$(jqb '.version // empty')"
code=$(curl -s --max-time 60 -o /dev/null -w '%{http_code}' "$BASE_URL/"); check ui.gambia 200 "$code"
code=$(curl -s --max-time 60 -o /dev/null -w '%{http_code}' "$BASE_URL/v2/"); check ui.v2 200 "$code"

if [ "$CHECK_LOGS" = 1 ]; then
  section "12 service logs --since $LOG_SINCE (SQL errors per container)"
  for c in $(docker ps --format '{{.Names}}' | grep "^${COMPOSE_PROJECT}-" | sort); do
    n=$(docker logs --since "$LOG_SINCE" "$c" 2>&1 | grep -cE 'PSQLException|SQLGrammar|JDBCException|ERROR: |SqlExceptionHelper|FlywayException')
    printf '%-40s sql-errors=%s\n' "$c" "$n"
  done
fi

section "summary PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
printf '%s\n' "${RESULTS[@]}" | grep -v '^PASS' || true
exit $(( FAIL > 0 ))
