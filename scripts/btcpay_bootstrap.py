#!/usr/bin/env python3
"""Idempotent BTCPay bootstrap for the BoltMesh stack.

Store-level configuration lives in BTCPay's database, so every fresh
environment (or any environment whose BTCPay Postgres volume was recreated)
must be provisioned before the backend can create invoices. Running this job
against an already-provisioned instance is a no-op apart from ensuring the
payment methods and webhook still match.

Environment:
    BTCPAY_URL                       default http://btcpay:49392
    BTCPAY_ADMIN_EMAIL               admin account to create/use
    BTCPAY_ADMIN_PASSWORD            its password
    BTCPAY_ADMIN_KEY                 optional unlimited key; skips Basic auth
    BTCPAY_STORE_NAME                default "BoltMesh"
    BTCPAY_STORE_ID                  optional; otherwise resolved by name
    BTCPAY_API_KEY                   optional runtime key to validate/reuse
    BTCPAY_WEBHOOK_URL               default http://backend:8000/v1/webhooks/btcpay
    BTCPAY_WEBHOOK_SECRET            optional; generated when creating
    BTCPAY_XMR_ACCOUNT_INDEX         default 0
    BTCPAY_XMR_CONFIRMATIONS         default 1
    BTCPAY_MONITORING_MINUTES        default 10080 (7 days)
    BTCPAY_WAIT_SECONDS              default 120
    BTCPAY_STATE_FILE                optional dotenv file that survives restarts

Values supplied in the state file are used when the environment does not
define them, and every generated secret is written back to it. That keeps the
job idempotent across restarts: Basic auth only works for five minutes after
the admin account is created, so the minted unlimited key must be reused.

Generated secrets are also printed on stdout in dotenv form; progress goes to
stderr.
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request

RUNTIME_PERMISSIONS = [
    "btcpay.store.cancreateinvoice",
    "btcpay.store.canviewinvoices",
    "btcpay.store.canmodifyinvoices",
    "btcpay.store.canviewstoresettings",
]

WEBHOOK_EVENTS = [
    "InvoiceReceivedPayment",
    "InvoicePaymentSettled",
    "InvoiceSettled",
    "InvoiceExpired",
    "InvoiceExpiredPaidPartial",
    "InvoicePaidAfterExpiration",
    "InvoiceInvalid",
    "InvoiceRefund",
]

LIGHTNING_METHOD = "BTC-LN"
XMR_METHOD = "XMR-CHAIN"


class BootstrapError(RuntimeError):
    pass


def log(message: str) -> None:
    print(f"[btcpay-bootstrap] {message}", file=sys.stderr, flush=True)


def load_state(path: str) -> dict[str, str]:
    state: dict[str, str] = {}
    if not path or not os.path.exists(path):
        return state
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            state[name.strip()] = value.strip()
    return state


def save_state(path: str, state: dict[str, str]) -> None:
    if not path:
        return
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        for name, value in sorted(state.items()):
            handle.write(f"{name}={value}\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


class BtcPay:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url.rstrip("/")

    def request(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        *,
        token: str | None = None,
        basic: tuple[str, str] | None = None,
        timeout: float = 30.0,
    ) -> object:
        data = None if body is None else json.dumps(body).encode()
        headers = {"Accept": "application/json"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        if token is not None:
            headers["Authorization"] = f"token {token}"
        elif basic is not None:
            raw = f"{basic[0]}:{basic[1]}".encode()
            headers["Authorization"] = "Basic " + base64.b64encode(raw).decode()

        request = urllib.request.Request(
            f"{self.base_url}{path}", data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            raise BootstrapError(f"{method} {path} -> HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise BootstrapError(f"{method} {path} -> {exc.reason}") from exc

        if not payload:
            return None
        try:
            return json.loads(payload)
        except json.JSONDecodeError as exc:
            raise BootstrapError(f"{method} {path} -> invalid JSON") from exc

    def wait_until_ready(self, seconds: int) -> None:
        deadline = time.monotonic() + seconds
        while True:
            try:
                self.request("GET", "/api/v1/health", timeout=5)
                return
            except BootstrapError as exc:
                if time.monotonic() >= deadline:
                    raise BootstrapError(f"BTCPay did not become ready: {exc}") from exc
                time.sleep(2)


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def ensure_admin(client: BtcPay, email: str, password: str, admin_key: str) -> tuple[str, bool]:
    """Return an unlimited key (and whether it was minted) for this instance."""
    if admin_key:
        client.request("GET", "/api/v1/users/me", token=admin_key)
        log("using the provided admin key")
        return admin_key, False

    if not email or not password:
        raise BootstrapError("set BTCPAY_ADMIN_EMAIL/BTCPAY_ADMIN_PASSWORD or BTCPAY_ADMIN_KEY")

    try:
        client.request("GET", "/api/v1/users/me", basic=(email, password))
    except BootstrapError:
        # First boot: BTCPay only allows creating the first account anonymously.
        log(f"creating the first administrator {email}")
        try:
            client.request(
                "POST",
                "/api/v1/users",
                {"email": email, "password": password, "isAdministrator": True},
            )
        except BootstrapError as exc:
            raise BootstrapError(
                "cannot authenticate and could not create the admin account; "
                "set BTCPAY_ADMIN_KEY with an unlimited key"
            ) from exc
        client.request("GET", "/api/v1/users/me", basic=(email, password))

    try:
        created = client.request(
            "POST",
            "/api/v1/api-keys",
            {"label": "boltmesh-bootstrap", "permissions": ["unrestricted"]},
            basic=(email, password),
        )
    except BootstrapError as exc:
        raise BootstrapError(
            "could not mint an admin key; Basic auth is only available for five "
            "minutes after account creation. Set BTCPAY_ADMIN_KEY with an "
            "unlimited key instead."
        ) from exc
    key = created["apiKey"]
    log("minted an unlimited admin key (printed on stdout; set BTCPAY_ADMIN_KEY)")
    return key, True


def resolve_store(client: BtcPay, key: str, store_id: str, name: str) -> str:
    if store_id:
        try:
            client.request("GET", f"/api/v1/stores/{store_id}", token=key)
        except BootstrapError:
            log(f"store {store_id} does not exist in this BTCPay instance; resolving by name")
        else:
            log(f"using store {store_id}")
            return store_id

    stores = client.request("GET", "/api/v1/stores", token=key) or []
    for store in stores:
        if store.get("name") == name:
            log(f"found store {store['id']} ({name})")
            return store["id"]

    created = client.request(
        "POST", "/api/v1/stores", {"name": name, "defaultCurrency": "USD"}, token=key
    )
    log(f"created store {created['id']} ({name})")
    return created["id"]


def ensure_store_settings(client: BtcPay, key: str, store_id: str, monitoring_minutes: int) -> None:
    store = client.request("GET", f"/api/v1/stores/{store_id}", token=key)
    if store.get("monitoringExpiration") == monitoring_minutes:
        return
    client.request(
        "PUT",
        f"/api/v1/stores/{store_id}",
        {"monitoringExpiration": monitoring_minutes},
        token=key,
    )
    log(f"store monitoring window set to {monitoring_minutes} minutes")


def ensure_lightning(client: BtcPay, key: str, store_id: str) -> None:
    methods = client.request("GET", f"/api/v1/stores/{store_id}/payment-methods", token=key) or []
    current = {m["paymentMethodId"]: m for m in methods}
    lightning = current.get(LIGHTNING_METHOD)
    if lightning and lightning.get("enabled"):
        log(f"{LIGHTNING_METHOD} already enabled")
        return
    client.request(
        "PUT",
        f"/api/v1/stores/{store_id}/payment-methods/{LIGHTNING_METHOD}",
        {"enabled": True, "config": {"connectionString": "Internal Node"}},
        token=key,
    )
    log(f"{LIGHTNING_METHOD} enabled on the server's internal node")


def ensure_xmr(
    client: BtcPay, key: str, store_id: str, account_index: int, confirmations: int
) -> None:
    config = {
        "accountIndex": account_index,
        "invoiceSettledConfirmationThreshold": confirmations,
    }
    client.request(
        "PUT",
        f"/api/v1/stores/{store_id}/payment-methods/{XMR_METHOD}",
        {"enabled": True, "config": config},
        token=key,
    )
    methods = client.request("GET", f"/api/v1/stores/{store_id}/payment-methods", token=key) or []
    if not any(m["paymentMethodId"] == XMR_METHOD and m.get("enabled") for m in methods):
        raise BootstrapError(f"{XMR_METHOD} is not available; is the Monero plugin installed?")
    log(f"{XMR_METHOD} enabled (account {account_index}, {confirmations} confirmation)")


def ensure_webhook(
    client: BtcPay, key: str, store_id: str, url: str, secret: str
) -> tuple[str, bool]:
    webhooks = client.request("GET", f"/api/v1/stores/{store_id}/webhooks", token=key) or []
    existing = next((w for w in webhooks if w.get("url") == url), None)
    payload = {
        "url": url,
        "enabled": True,
        "automaticRedelivery": True,
        "authorizedEvents": {"everything": False, "specificEvents": WEBHOOK_EVENTS},
    }

    if existing is None:
        if not secret:
            secret = secrets.token_hex(32)
            log("generated a webhook secret (printed on stdout)")
        payload["secret"] = secret
        created = client.request("POST", f"/api/v1/stores/{store_id}/webhooks", payload, token=key)
        log(f"created webhook {created['id']} -> {url}")
        return created.get("secret") or secret, True

    if not secret:
        raise BootstrapError(
            "the webhook already exists and BTCPAY_WEBHOOK_SECRET is unset, so "
            "its secret cannot be recovered; set BTCPAY_WEBHOOK_SECRET to the "
            "value the backend uses"
        )
    payload["secret"] = secret
    client.request(
        "PUT", f"/api/v1/stores/{store_id}/webhooks/{existing['id']}", payload, token=key
    )
    log(f"webhook {existing['id']} already present")
    return secret, False


def ensure_runtime_key(client: BtcPay, key: str, store_id: str, api_key: str) -> tuple[str, bool]:
    if api_key:
        try:
            client.request("GET", f"/api/v1/stores/{store_id}/payment-methods", token=api_key)
        except BootstrapError:
            log("the provided BTCPAY_API_KEY is not usable; minting a new one")
        else:
            log("reusing the provided runtime API key")
            return api_key, False

    created = client.request(
        "POST",
        "/api/v1/api-keys",
        {"label": "boltmesh-backend", "permissions": RUNTIME_PERMISSIONS},
        token=key,
    )
    runtime_key = created["apiKey"]
    client.request("GET", f"/api/v1/stores/{store_id}/payment-methods", token=runtime_key)
    log("minted the store-scoped runtime API key (printed on stdout)")
    return runtime_key, True


def wallet_ready(uri: str) -> bool:
    """Return True when the plugin wallet-rpc has an open wallet.

    The XMR payment method is only enabled once the view-only wallet exists;
    otherwise the store would advertise a rail that cannot produce a
    destination, and the backend's ``enabled``-based health would call it up.
    """
    if not uri:
        return True
    body = json.dumps(
        {"jsonrpc": "2.0", "id": "0", "method": "get_accounts", "params": {}}
    ).encode()
    request = urllib.request.Request(
        uri, data=body, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            data = json.load(response)
    except Exception:
        return False
    accounts = (data.get("result") or {}).get("subaddress_accounts") or []
    return bool(accounts)


def main() -> int:
    state_file = env("BTCPAY_STATE_FILE")
    state = load_state(state_file)

    def setting(name: str, default: str = "") -> str:
        return os.environ.get(name, "").strip() or state.get(name, "") or default

    base_url = setting("BTCPAY_URL", "http://btcpay:49392")
    email = env("BTCPAY_ADMIN_EMAIL")
    password = env("BTCPAY_ADMIN_PASSWORD")
    admin_key = setting("BTCPAY_ADMIN_KEY")
    store_name = env("BTCPAY_STORE_NAME", "BoltMesh")
    store_id_env = setting("BTCPAY_STORE_ID")
    api_key_env = setting("BTCPAY_API_KEY")
    webhook_url = setting("BTCPAY_WEBHOOK_URL", "http://backend:8000/v1/webhooks/btcpay")
    webhook_secret_env = setting("BTCPAY_WEBHOOK_SECRET")
    account_index = int(env("BTCPAY_XMR_ACCOUNT_INDEX", "0"))
    confirmations = int(env("BTCPAY_XMR_CONFIRMATIONS", "1"))
    monitoring_minutes = int(env("BTCPAY_MONITORING_MINUTES", "10080"))
    wait_seconds = int(env("BTCPAY_WAIT_SECONDS", "120"))

    client = BtcPay(base_url)
    client.wait_until_ready(wait_seconds)
    log(f"BTCPay is up at {base_url}")

    admin_key, admin_key_minted = ensure_admin(client, email, password, admin_key)
    if state_file:
        # Persist the admin key immediately: Basic auth stops working five
        # minutes after account creation, so a later failure must not lose it.
        save_state(state_file, {**state, "BTCPAY_ADMIN_KEY": admin_key})
    store_id = resolve_store(client, admin_key, store_id_env, store_name)
    ensure_store_settings(client, admin_key, store_id, monitoring_minutes)
    # A rail that is not ready yet (CLN still starting, plugin not installed,
    # wallet not imported) must not prevent the store, webhook and runtime key
    # from being provisioned: the backend needs those to boot, and a later
    # re-run enables the rail once its dependencies exist.
    try:
        ensure_lightning(client, admin_key, store_id)
    except BootstrapError as exc:
        log(f"warning: BTC-LN not enabled yet ({exc}); re-run when lightningd is reachable")
    xmr_wallet = env("BTCPAY_XMR_WALLET_DAEMON_URI")
    if not wallet_ready(xmr_wallet):
        log(
            "warning: XMR-CHAIN not enabled yet (no wallet open at "
            f"{xmr_wallet or 'the plugin wallet RPC'}); import it and re-run"
        )
    else:
        try:
            ensure_xmr(client, admin_key, store_id, account_index, confirmations)
        except BootstrapError as exc:
            log(
                f"warning: XMR-CHAIN not enabled yet ({exc}); re-run after the plugin and wallet are ready"
            )
    webhook_secret, webhook_created = ensure_webhook(
        client, admin_key, store_id, webhook_url, webhook_secret_env
    )
    runtime_key, runtime_created = ensure_runtime_key(client, admin_key, store_id, api_key_env)

    save_state(
        state_file,
        {
            # Merge rather than replace: the same file carries the operator's
            # admin email/password and store/webhook inputs, and a later run
            # needs them if the admin key is ever lost.
            **state,
            "BTCPAY_URL": base_url,
            "BTCPAY_STORE_ID": store_id,
            "BTCPAY_API_KEY": runtime_key,
            "BTCPAY_WEBHOOK_SECRET": webhook_secret,
            "BTCPAY_ADMIN_KEY": admin_key,
        },
    )

    print("# BTCPay bootstrap output - put these in backend/.env", flush=True)
    print(f"BTCPAY_URL={base_url}", flush=True)
    print(f"BTCPAY_STORE_ID={store_id}", flush=True)
    if runtime_created or not api_key_env:
        print(f"BTCPAY_API_KEY={runtime_key}", flush=True)
    if webhook_created:
        print(f"BTCPAY_WEBHOOK_SECRET={webhook_secret}", flush=True)
    if admin_key_minted:
        print(f"BTCPAY_ADMIN_KEY={admin_key}", flush=True)

    log(f"done: store {store_id}, webhook {webhook_url}")
    if runtime_created:
        log("update BTCPAY_API_KEY in backend/.env, then restart backend and worker")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BootstrapError as exc:
        log(f"error: {exc}")
        sys.exit(1)
