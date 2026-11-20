import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

PANEL_URL = "http://127.0.0.1:2053"
INBOUNDS_DIR = Path("/bootstrap/inbounds")
WAIT_ATTEMPTS = 60
WAIT_SECONDS = 2


def panel_api() -> str:
    path = os.environ["XUI_PANEL_BASE_PATH"].strip("/")
    return f"{PANEL_URL}/{path}/panel/api/"


def sub_base() -> str:
    return "/" + os.environ["XUI_SUBSCRIPTION_BASE_PATH"].strip("/") + "/"


def env_list(name: str) -> list[str]:
    return [part.strip() for part in os.environ[name].split(",") if part.strip()]


def with_port(inbound: dict[str, object]) -> None:
    if inbound["protocol"] == "amneziawg":
        port = os.environ["XUI_AWG_PORT"]
    else:
        port = os.environ["XUI_VLESS_PORT"]
    inbound["port"] = int(port)


def with_credentials(inbound: dict[str, object]) -> None:
    settings = inbound["settings"]
    assert isinstance(settings, dict)
    if inbound["protocol"] == "amneziawg":
        server = settings["server"]
        assert isinstance(server, dict)
        server["privateKey"] = os.environ["XUI_AWG_PRIVATE_KEY"]
        server["publicKey"] = os.environ["XUI_AWG_PUBLIC_KEY"]
        server["headerProtectionKey"] = os.environ[
            "XUI_AWG_HEADER_PROTECTION_KEY"
        ]
        return

    stream = inbound["streamSettings"]
    assert isinstance(stream, dict)
    reality = stream["realitySettings"]
    assert isinstance(reality, dict)
    reality["privateKey"] = os.environ["XUI_REALITY_PRIVATE_KEY"]
    reality["shortIds"] = env_list("XUI_REALITY_SHORT_IDS")
    reality["target"] = os.environ["XUI_REALITY_TARGET"]
    reality["serverNames"] = env_list("XUI_REALITY_SERVER_NAMES")
    reality_settings = reality["settings"]
    assert isinstance(reality_settings, dict)
    reality_settings["publicKey"] = os.environ["XUI_REALITY_PUBLIC_KEY"]


def call(token: str, method: str, path: str, payload: object = None) -> object:
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    body = None
    if isinstance(payload, dict):
        body = urllib.parse.urlencode(payload).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif payload is not None:
        body = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        panel_api() + path, data=body, headers=headers, method=method
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        answer = json.load(response)
    if not answer.get("success"):
        raise RuntimeError(f"{method} {path}: {answer.get('msg')}")
    return answer.get("obj")


def wait_for_panel(token: str) -> None:
    for attempt in range(WAIT_ATTEMPTS):
        try:
            call(token, "GET", "inbounds/list/slim")
            return
        except (urllib.error.URLError, TimeoutError):
            if attempt == WAIT_ATTEMPTS - 1:
                raise
            time.sleep(WAIT_SECONDS)


def set_sub_path(token: str) -> bool:
    settings = call(token, "POST", "setting/all")
    assert isinstance(settings, dict)
    base = sub_base()
    if settings["subPath"] == base:
        return False
    settings["subPath"] = base
    settings["subJsonPath"] = base + "json/"
    settings["subClashPath"] = base + "clash/"
    call(token, "POST", "setting/update", settings)
    return True


def import_inbounds(token: str) -> None:
    listed = call(token, "GET", "inbounds/list/slim")
    assert isinstance(listed, list)
    existing = {inbound["tag"] for inbound in listed}
    for path in sorted(INBOUNDS_DIR.glob("*.json")):
        inbound = json.loads(path.read_text())
        if inbound["tag"] in existing:
            continue
        with_port(inbound)
        with_credentials(inbound)
        call(token, "POST", "inbounds/import", {"data": json.dumps(inbound)})


def main() -> None:
    panel_path = os.environ["XUI_PANEL_BASE_PATH"].strip("/")
    sub_path = os.environ["XUI_SUBSCRIPTION_BASE_PATH"].strip("/")
    if panel_path == sub_path:
        raise SystemExit("panel and subscription paths must differ")
    token = os.environ["XUI_TOKEN"]
    wait_for_panel(token)
    path_changed = set_sub_path(token)
    import_inbounds(token)
    if path_changed:
        call(token, "POST", "setting/restartPanel")
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
