"""Access Azure as a managed identity using a token from your own Keycloak.

Demonstrates workload identity federation from Python:

    1. Get a client_credentials token from Keycloak (your own OIDC provider).
    2. Hand it to azure-identity's ClientAssertionCredential, which exchanges
       it at Entra ID for an access token of the user-assigned managed
       identity (the federated identity credential authorizes the exchange).
    3. Use that credential against the control plane (ARM: read the resource
       group) and the data plane (Blob Storage: read the demo blob).

No Azure secret is stored anywhere - the only credential is the Keycloak
client secret, which your own IdP issued and can rotate/revoke at will.

Configuration comes from oidc-federation-azure/.env (written by deploy.ps1).

    pip install -r ../requirements.txt
    python client_azure_via_keycloak.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import requests
from azure.identity import ClientAssertionCredential
from azure.storage.blob import BlobClient

ENV_FILE = Path(__file__).resolve().parents[1] / ".env"


def load_env(path: Path) -> dict[str, str]:
    """Minimal .env reader (KEY=VALUE lines, no dependency on python-dotenv)."""
    if not path.exists():
        sys.exit(f"{path} not found - run scripts/deploy.ps1 first.")
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip('"')
    return values


def main() -> None:
    cfg = load_env(ENV_FILE)

    def keycloak_assertion() -> str:
        """Mint a fresh Keycloak token; called by azure-identity on demand."""
        response = requests.post(
            f"{cfg['KEYCLOAK_URL']}/realms/{cfg['KEYCLOAK_REALM']}"
            "/protocol/openid-connect/token",
            data={
                "grant_type": "client_credentials",
                "client_id": cfg["KEYCLOAK_CLIENT_ID"],
                "client_secret": cfg["KEYCLOAK_CLIENT_SECRET"],
            },
            timeout=30,
        )
        response.raise_for_status()
        return response.json()["access_token"]

    credential = ClientAssertionCredential(
        tenant_id=cfg["AZURE_TENANT_ID"],
        client_id=cfg["AZURE_UAMI_CLIENT_ID"],  # the managed identity's client ID
        func=keycloak_assertion,
    )

    # Control plane: read the resource group through ARM.
    arm_token = credential.get_token("https://management.azure.com/.default")
    rg_url = (
        "https://management.azure.com/subscriptions/"
        f"{cfg['AZURE_SUBSCRIPTION_ID']}/resourceGroups/"
        f"{cfg['AZURE_RESOURCE_GROUP']}?api-version=2021-04-01"
    )
    response = requests.get(
        rg_url, headers={"Authorization": f"Bearer {arm_token.token}"}, timeout=30
    )
    response.raise_for_status()
    print(f"Control plane OK: {response.json()['id']}")

    # Data plane: read the demo blob with the same federated credential.
    blob = BlobClient(
        account_url=f"https://{cfg['DEMO_STORAGE_ACCOUNT']}.blob.core.windows.net",
        container_name=cfg.get("DEMO_BLOB_CONTAINER", "demo"),
        blob_name=cfg.get("DEMO_BLOB_NAME", "hello.txt"),
        credential=credential,
    )
    content = blob.download_blob().readall().decode()
    print(f"Data plane OK: {content!r}")


if __name__ == "__main__":
    main()
