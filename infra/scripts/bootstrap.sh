#!/bin/bash
# Runs inside a Microsoft.Resources/deploymentScripts (AzureCLI) container as
# part of the Bicep deployment, so deploying main.bicep - from the CLI or the
# Bicep extension GUI - performs the entire post-provisioning flow with no
# local scripts:
#   1. Wait for Keycloak's OIDC discovery endpoint.
#   2. Bootstrap realm / confidential client / audience mapper (idempotent).
#   3. Upload the demo blob used by the data-plane verification.
#   4. Re-enable the Caddy admin lockdown.
#   5. Output the service-account UUID; Bicep feeds it into the federated
#      identity credential as the subject.
#
# Expected environment (set by infra/modules/bootstrap.bicep):
#   KEYCLOAK_URL, REALM, CLIENT_ID, KC_ADMIN_PASSWORD, KC_CLIENT_SECRET,
#   STORAGE_ACCOUNT, STORAGE_KEY, CONTAINER_APP, RESOURCE_GROUP
set -euo pipefail

echo "Waiting for Keycloak discovery endpoint at $KEYCLOAK_URL ..."
ready=0
for _ in $(seq 1 90); do
  if curl -fsS "$KEYCLOAK_URL/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 10
done
if [ "$ready" != "1" ]; then
  echo "Keycloak did not become ready within 15 minutes." >&2
  exit 1
fi
echo "Keycloak is up."

TOKEN=$(curl -fsS -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d 'grant_type=password&client_id=admin-cli&username=admin' \
  --data-urlencode "password=$KC_ADMIN_PASSWORD" | jq -r .access_token)
AUTH="Authorization: Bearer $TOKEN"
BASE="$KEYCLOAK_URL/admin/realms"

# --- Realm (short-lived tokens keep the Entra assertions short-lived) --------
if curl -fsS -H "$AUTH" "$BASE/$REALM" >/dev/null 2>&1; then
  echo "Realm '$REALM' already exists."
else
  echo "Creating realm '$REALM' ..."
  jq -n --arg realm "$REALM" '{realm: $realm, enabled: true, accessTokenLifespan: 300}' |
    curl -fsS -X POST -H "$AUTH" -H 'Content-Type: application/json' "$BASE" -d @-
fi

# --- Confidential client, service-account (client_credentials) flow only -----
# The client secret is supplied as a deployment parameter (instead of letting
# Keycloak generate one) so it never has to appear in deployment outputs.
CLIENT_UUID=$(curl -fsS -H "$AUTH" "$BASE/$REALM/clients?clientId=$CLIENT_ID" | jq -r '.[0].id // empty')
if [ -z "$CLIENT_UUID" ]; then
  echo "Creating client '$CLIENT_ID' ..."
  jq -n --arg cid "$CLIENT_ID" --arg secret "$KC_CLIENT_SECRET" '{
      clientId: $cid, protocol: "openid-connect", publicClient: false,
      serviceAccountsEnabled: true, standardFlowEnabled: false,
      implicitFlowEnabled: false, directAccessGrantsEnabled: false,
      secret: $secret
    }' | curl -fsS -X POST -H "$AUTH" -H 'Content-Type: application/json' "$BASE/$REALM/clients" -d @-
  CLIENT_UUID=$(curl -fsS -H "$AUTH" "$BASE/$REALM/clients?clientId=$CLIENT_ID" | jq -r '.[0].id')
else
  echo "Client '$CLIENT_ID' already exists; ensuring the secret matches the parameter."
  jq -n --arg secret "$KC_CLIENT_SECRET" '{secret: $secret}' |
    curl -fsS -X PUT -H "$AUTH" -H 'Content-Type: application/json' "$BASE/$REALM/clients/$CLIENT_UUID" -d @-
fi

# --- Hardcoded audience mapper -> aud: api://AzureADTokenExchange -------------
if curl -fsS -H "$AUTH" "$BASE/$REALM/clients/$CLIENT_UUID/protocol-mappers/models" |
   jq -e '.[] | select(.name == "azure-token-exchange-audience")' >/dev/null; then
  echo "Audience mapper already present."
else
  echo "Adding audience mapper ..."
  jq -n '{
      name: "azure-token-exchange-audience", protocol: "openid-connect",
      protocolMapper: "oidc-audience-mapper",
      config: {
        "included.custom.audience": "api://AzureADTokenExchange",
        "access.token.claim": "true", "id.token.claim": "false"
      }
    }' | curl -fsS -X POST -H "$AUTH" -H 'Content-Type: application/json' \
      "$BASE/$REALM/clients/$CLIENT_UUID/protocol-mappers/models" -d @-
fi

# The service-account user's UUID is the `sub` claim of client_credentials
# tokens; it becomes the federated identity credential's subject.
SUBJECT=$(curl -fsS -H "$AUTH" "$BASE/$REALM/clients/$CLIENT_UUID/service-account-user" | jq -r .id)
echo "Service-account subject: $SUBJECT"

# --- Demo blob for the data-plane verification ---------------------------------
echo 'Hello from the Azure data plane, via your own OIDC provider!' > /tmp/hello.txt
az storage blob upload --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" \
  --container-name demo --name hello.txt --file /tmp/hello.txt --overwrite --only-show-errors
echo "Demo blob uploaded."

# --- Re-enable the public admin lockdown (Caddy sidecar) ------------------------
# The template deploys with CADDY_ADMIN_LOCKDOWN=false so this script can reach
# the admin REST API; flipping it back is the last step. Retries cover RBAC
# propagation on the deployer identity's fresh Contributor assignment.
az extension add --name containerapp --only-show-errors 2>/dev/null || true
locked=0
for _ in $(seq 1 10); do
  if az containerapp update --name "$CONTAINER_APP" --resource-group "$RESOURCE_GROUP" \
       --container-name caddy --set-env-vars CADDY_ADMIN_LOCKDOWN=true \
       --only-show-errors >/dev/null; then
    locked=1
    break
  fi
  echo "containerapp update failed (RBAC propagation?); retrying in 30s ..."
  sleep 30
done
if [ "$locked" != "1" ]; then
  echo "Failed to enable the admin lockdown." >&2
  exit 1
fi
echo "Admin lockdown enabled."

jq -n --arg subject "$SUBJECT" '{subject: $subject}' > "$AZ_SCRIPTS_OUTPUT_PATH"
