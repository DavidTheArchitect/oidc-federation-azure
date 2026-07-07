# Design: Self-Hosted OIDC Provider with Azure Workload Identity Federation

## Goal

Host our own OIDC identity provider (Keycloak fronted by Caddy, both containers)
and federate it with a **user-assigned managed identity (UAMI)** in Entra ID, so
workloads outside Azure can exchange a Keycloak-issued token for an Entra access
token and reach the Azure **control plane** (ARM) and **data plane** (Blob
Storage) without storing any Azure credential. Deployment is as automatic as
possible: one Bicep template plus PowerShell orchestration.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Hosting | Azure Container Apps | Platform ingress terminates TLS with a publicly trusted cert on the default `*.azurecontainerapps.io` FQDN — exactly what Entra needs to fetch the issuer's discovery document; no custom domain or Let's Encrypt plumbing. |
| Caddy's role | Sidecar in the same Container App | TLS is already terminated at ingress, so Caddy handles admin-surface lockdown (`/admin*`, master realm, `/metrics`) and JWKS cache headers instead. On a VM-based alternative it would own TLS. |
| Persistence | Azure Database for PostgreSQL Flexible Server (B1ms) | Realm/client config and signing keys survive revisions and restarts. |
| Scripting | PowerShell 7 + `az` CLI | Matches the repo's PowerShell-first convention. |
| Local dev | `docker-compose.yml` (Caddy + Keycloak + Postgres) | Mirrors the Azure topology for iterating on realm config; a local issuer cannot federate (not publicly reachable). |

## Hard constraints (from Microsoft Learn)

- The federated identity credential (FIC) goes on a **user-assigned** managed
  identity (system-assigned unsupported); max 20 FICs per identity.
- FIC `issuer` must be a public HTTPS, OIDC-Discovery-compliant URL matching the
  token's `iss` exactly; Entra fetches `<issuer>/.well-known/openid-configuration`
  and the JWKS from it.
- FIC `subject` must match the token's `sub` exactly and case-sensitively. For a
  Keycloak `client_credentials` token, `sub` is the service-account user UUID
  generated when the client is created — so the FIC can only be created **after**
  Keycloak is bootstrapped (this drives the deploy ordering).
- FIC `audience` is `api://AzureADTokenExchange`; a hardcoded-audience protocol
  mapper on the Keycloak client emits it.
- Tokens must be RS256-signed (Keycloak's default).
- Mismatches fail silently at token-exchange time, not at FIC creation time.

## Token flow

1. A principal gets a Keycloak token from `https://<fqdn>/realms/azure`
   (client `azure-federation`) — either the service account via
   `client_credentials` (`sub` = service-account UUID) or the test user via the
   `password` grant (`sub` = test user UUID). Both tokens carry
   `aud=api://AzureADTokenExchange` from the client's audience mapper.
2. Workload POSTs to `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token`
   with `client_id=<UAMI client ID>`,
   `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`,
   `client_assertion=<Keycloak token>`, and the target scope
   (`https://management.azure.com/.default` or `https://storage.azure.com/.default`).
3. Entra validates the assertion against the matching FIC (one per subject) and
   issues an access token for the managed identity, whose RBAC grants (`Reader`
   on the resource group, `Storage Blob Data Reader` on a demo account) bound
   what the workload can do.

Two federated credentials are created on the one managed identity — one for the
service-account subject, one for the test-user subject — both with the same
issuer and audience. This shows that any Keycloak principal you provision can be
federated by adding a credential for its `sub`, up to the 20-per-identity limit.

## Deliverables

- `infra/main.bicep` + `infra/modules/{network-logs,postgres,keycloak-app,identity,bootstrap,federation,storage-demo}.bicep`
  — self-sufficient subscription-scope deployment. An embedded
  `deploymentScripts` resource (`infra/scripts/bootstrap.sh`, run in Azure
  under a dedicated deployer identity with Contributor on the resource group)
  waits for Keycloak, bootstraps realm/client/audience mapper, provisions a
  test user, uploads the demo blob, and re-enables the admin lockdown; the two
  FICs (service account + test user) are then created from its `subject` /
  `userSubject` outputs. This means deploying `main.bicep` alone — including
  from the Bicep extension GUI — produces a fully working federation. The
  Keycloak client secret and the test-user password are secure *input*
  parameters so they never appear in deployment outputs.
- `caddy/Caddyfile.aca` (sidecar lockdown/caching) and `caddy/Caddyfile.local`.
- `docker-compose.yml` — local parity stack.
- `scripts/deploy.ps1` — optional convenience wrapper: preflight/provider
  registration → secret generation (reused from `.env` on re-runs) → the Bicep
  deployment → write `.env` → `test-federation.ps1`. Idempotent/re-runnable.
- `scripts/test-federation.ps1` — PASS/FAIL proof: Keycloak token → Entra
  exchange → ARM GET (control plane) → blob read (data plane), with retries for
  FIC/RBAC propagation.
- `scripts/destroy.ps1` — single resource-group delete.
- `samples/client_azure_via_keycloak.py` — the same proof via `azure-identity`'s
  `ClientAssertionCredential`, showing that every Azure SDK can consume the
  federation.

## Verification

- Local: `docker compose up` then fetch
  `https://localhost/realms/master/.well-known/openid-configuration`.
- Static: `az bicep build` on all templates.
- Live: `./scripts/deploy.ps1` then `./scripts/test-federation.ps1` must pass
  every check — the service-account flow (token → exchange → ARM GET → blob
  read) and the test-user flow (`password` token → exchange → ARM GET); a token
  minted without the audience mapper (or a wrong subject) must be rejected with
  an `AADSTS` error, confirming the trust scope.
