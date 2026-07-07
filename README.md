# Self-Hosted OIDC Provider on Azure with Workload Identity Federation

Run your **own OIDC identity provider** — Keycloak fronted by Caddy — on Azure
Container Apps, and federate it with a **user-assigned managed identity** in
Entra ID. External workloads (local scripts, agents, CI jobs) then exchange a
token from *your* Keycloak for an Entra access token and act as the managed
identity against the Azure **control plane** (ARM) and **data plane** (Blob
Storage) — **with zero stored Azure secrets**.

## How the trust works

```
Your workload (PowerShell / Python)
 │ 1. client_credentials
 ▼
Azure Container Apps  ─ ingress TLS (*.azurecontainerapps.io, valid cert)
 ┌─────────────────────────────────────────────┐
 │  caddy :8080 ── reverse_proxy ──► keycloak :8081
 │  (admin lockdown, JWKS cache)      │
 └────────────────────────────────────┼────────┘
                                      ▼
                    Azure Database for PostgreSQL (B1ms)

 2. Keycloak JWT:  iss = https://<fqdn>/realms/azure
                   sub = <service-account UUID>
                   aud = api://AzureADTokenExchange     (RS256)
 3. POST login.microsoftonline.com/<tenant>/oauth2/v2.0/token
      client_id        = <managed identity client ID>
      client_assertion = <the Keycloak JWT>
    Entra validates it against the federated identity credential
    (fetches your issuer's discovery doc + JWKS over public HTTPS).
 4. Entra access token  ──►  ARM (control plane) + Storage (data plane)
```

The federated identity credential (FIC) on the managed identity pins three
values that must **exactly, case-sensitively** match the incoming token:
`issuer`, `subject`, and `audience`. Because Keycloak generates the
service-account UUID (`sub`) when the client is created, the FIC can only be
created *after* Keycloak is bootstrapped — `deploy.ps1` sequences this for you.

Why Container Apps (vs a VM): the platform ingress terminates TLS with a
publicly trusted certificate on the default FQDN, which is exactly what Entra
needs to fetch your discovery document — no domain purchase, no Let's Encrypt
plumbing. Caddy still runs as a sidecar to lock the admin surface away from
the internet and to add cache headers on the JWKS endpoint.

## Prerequisites

- Azure subscription with permission to create resource groups, role
  assignments (Owner or User Access Administrator on the subscription), and
  managed identities.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) logged
  in (`az login`), with Bicep support (`az bicep install`).
- PowerShell 7+ (`pwsh`).
- Docker Desktop only if you want the local development stack.

## Quick start (deploy everything)

```powershell
cd oidc-federation-azure
./scripts/deploy.ps1 -Location eastus2 -BaseName oidcfed
```

One command runs the whole flow (~10–15 minutes on first run):

1. **Preflight** — subscription check, resource-provider registration,
   crypto-random passwords (reused from `.env` on re-runs).
2. **Bicep** (`infra/main.bicep`) — resource group, Log Analytics, Container
   Apps environment, PostgreSQL Flexible Server, the Keycloak + Caddy
   container app, the user-assigned managed identity with `Reader` on the
   resource group and `Storage Blob Data Reader` on a demo storage account.
3. **Readiness** — polls the OIDC discovery endpoint until Keycloak is up.
4. **Bootstrap** (`scripts/bootstrap-keycloak.ps1`) — creates realm `azure`,
   confidential client `azure-federation` (service account only), and the
   hardcoded audience mapper `aud: api://AzureADTokenExchange`; reads the
   service-account UUID that becomes the FIC subject.
5. **Federation** (`scripts/create-federation.ps1`) — creates the FIC on the
   managed identity: issuer `https://<fqdn>/realms/azure`, subject
   `<service-account UUID>`, audience `api://AzureADTokenExchange`.
6. **Lockdown** — uploads the demo blob, then flips the Caddy sidecar to
   block `/admin*`, `/realms/master*`, and `/metrics` from the internet.
7. **Verify** (`scripts/test-federation.ps1`) — mints a Keycloak token,
   exchanges it at Entra, reads the resource group via ARM (control plane)
   and the demo blob (data plane), printing PASS/FAIL per step.
8. Writes all resolved values to `oidc-federation-azure/.env` (gitignored).

Re-run any step standalone later, e.g.:

```powershell
./scripts/test-federation.ps1          # re-verify the trust end to end
python samples/client_azure_via_keycloak.py   # same proof from Python/azure-identity
./scripts/destroy.ps1                  # delete the whole resource group
```

## Using the federation from your own code

Anything that can present the Keycloak client credentials can act as the
managed identity. With `azure-identity` it is three lines (see
`samples/client_azure_via_keycloak.py`):

```python
credential = ClientAssertionCredential(
    tenant_id=..., client_id="<UAMI client ID>",
    func=lambda: keycloak_client_credentials_token(),
)
```

Every Azure SDK accepts that credential; scope it to any resource
(`https://management.azure.com/.default`, `https://storage.azure.com/.default`,
Key Vault, etc.). To grant more access, add role assignments to the managed
identity (`id-<baseName>-federation`) — e.g. `Contributor` on a subscription
for control-plane automation. Keep grants as narrow as the workload needs.

## Administering Keycloak after lockdown

The Caddy sidecar returns 403 on the admin surface when
`CADDY_ADMIN_LOCKDOWN=true`. To use the admin console or REST API:

```powershell
az containerapp update -n keycloak-<baseName> -g rg-<baseName> `
  --container-name caddy --set-env-vars CADDY_ADMIN_LOCKDOWN=false
# ... administer at https://<fqdn>/admin (user 'admin', KC_ADMIN_PASSWORD from .env) ...
az containerapp update -n keycloak-<baseName> -g rg-<baseName> `
  --container-name caddy --set-env-vars CADDY_ADMIN_LOCKDOWN=true
```

## Local development stack (docker compose)

The compose file mirrors the Azure topology (Caddy → Keycloak → Postgres) for
iterating on realm/client configuration before deploying:

```powershell
cd oidc-federation-azure
docker compose up -d
Invoke-WebRequest -SkipCertificateCheck https://localhost/realms/master/.well-known/openid-configuration
# Admin console: https://localhost/admin  (admin / localdev-admin)
```

A local issuer **cannot** federate with Entra — the discovery document must be
reachable over the public internet. Use the local stack for configuration
development only.

## Security notes

- **The Keycloak client secret *is* the key to the managed identity.** Anyone
  who can obtain a `client_credentials` token from that client can act as the
  UAMI within its RBAC grants. Guard the secret and the Keycloak admin
  password like any Azure credential; rotate/revoke them in Keycloak at will
  (that's the point of owning the IdP).
- The FIC matches `issuer`/`subject`/`audience` exactly — no wildcards exist,
  and a mismatch fails silently at token-exchange time, not at FIC creation.
- Only RS256-signed tokens are supported for the exchange (Keycloak default).
- Access-token lifetime in the realm is 300 s, keeping assertions short-lived.
- Keycloak signing-key rotation is transparent: Entra re-fetches your JWKS.
- A maximum of 20 FICs fit on one managed identity; add more clients/realms
  as extra FICs, or more identities for blast-radius isolation.
- Hardening beyond this lab setup: VNet-integrate the Container Apps
  environment and PostgreSQL (drop the "allow Azure services" firewall rule),
  put IP restrictions on the ingress, disable shared-key access on real
  storage accounts, and export the realm config to keep it in code.

## Files

| Path | Purpose |
| --- | --- |
| `infra/main.bicep` (+ `infra/modules/*.bicep`) | Subscription-scope deployment of all Azure resources. |
| `caddy/Caddyfile.aca` | Sidecar proxy: admin lockdown + JWKS cache headers. |
| `caddy/Caddyfile.local` | Local TLS proxy for the compose stack. |
| `docker-compose.yml` | Local Caddy + Keycloak + Postgres stack. |
| `scripts/deploy.ps1` | One-shot orchestrator (steps above). |
| `scripts/bootstrap-keycloak.ps1` | Realm/client/audience-mapper setup (idempotent). |
| `scripts/create-federation.ps1` | Creates/updates the FIC on the managed identity. |
| `scripts/test-federation.ps1` | End-to-end PASS/FAIL verification. |
| `scripts/destroy.ps1` | Deletes the resource group (and local `.env`). |
| `samples/client_azure_via_keycloak.py` | Python client using `ClientAssertionCredential`. |

## Troubleshooting

- **`AADSTS70021: No matching federated identity record found`** — the token's
  `iss`/`sub`/`aud` don't match the FIC. Decode the Keycloak token (the test
  script prints the claims) and compare against
  `az identity federated-credential list --identity-name id-<baseName>-federation -g rg-<baseName>`.
- **Exchange fails right after deploy** — FIC and RBAC propagation can take a
  few minutes; `test-federation.ps1` already retries for ~4 minutes.
- **Keycloak never becomes ready** — check container logs:
  `az containerapp logs show -n keycloak-<baseName> -g rg-<baseName> --container keycloak`.
  The most common cause is PostgreSQL connectivity (firewall/password).
- **403 on `/admin`** — that's the lockdown working; see the admin section above.
