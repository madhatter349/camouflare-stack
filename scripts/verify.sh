#!/usr/bin/env bash
# Gate for this deployment repo. Self-sufficient: python3 stdlib + bash only.
# Does not touch the running stack and needs no network.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

command -v python3 >/dev/null || fail "python3 required"

# 1. shim compiles
python3 -m py_compile shim/shim.py && ok "shim/shim.py compiles"

# 2. shim behaviour, exercised through the real functions
python3 - <<'PY' || exit 1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("shim", "shim/shim.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def check(body, stripped, label):
    raw = json.dumps(body).encode()
    out, flag = m.sanitize(raw)
    assert flag is stripped, f"{label}: stripped={flag} expected {stripped}"
    parsed = json.loads(out)
    if stripped:
        assert "proxy" not in parsed, f"{label}: proxy survived"
    return parsed

check({"cmd":"request.get","url":"https://x","proxy":{"url":None,"username":None,"password":None}}, True, "null proxy dropped")
check({"cmd":"request.get","url":"https://x","proxy":{}}, True, "empty proxy dropped")
check({"cmd":"request.get","url":"https://x","proxy":{"url":"","server":None}}, True, "blank proxy dropped")
check({"cmd":"request.get","url":"https://x","proxy":{"url":"socks5://1.2.3.4:1080"}}, False, "real proxy kept")
check({"cmd":"request.get","url":"https://x","proxy":{"server":"http://p:1"}}, False, "server form kept")
check({"cmd":"request.get","url":"https://x"}, False, "no proxy untouched")
assert m.sanitize(b"not json")[1] is False, "invalid json must pass through"
print("ok: shim sanitize() rules")
PY

# 3. compose guardrails
grep -q 'card_drop' docker-compose.yaml 2>/dev/null || true
grep -q 'cap_drop: \[ALL\]' docker-compose.yaml || fail "camouflare must drop all capabilities"
grep -q 'no-new-privileges:true' docker-compose.yaml || fail "no-new-privileges required"
grep -q 'shm_size: "2gb"' docker-compose.yaml || fail "shm_size required (Firefox dies on the 64MB default)"
test -s conf/default.conf || fail "nginx config missing"
grep -q "listen 8191" conf/default.conf || fail "nginx must listen on 8191"
grep -q 'mehmetcansahin/camouflare:2.1.0' docker-compose.yaml || fail "camouflare image must be pinned, not :latest"
grep -qE '^\s+ports:' docker-compose.yaml && fail "no published ports: Traefik reaches services over the network"
grep -qE 'container_name:' docker-compose.yaml && fail "container_name breaks Coolify redeploys"
grep -q 'CAPOUFLARE' docker-compose.yaml && fail "typo"
ok "compose guardrails"

# 4. no secrets committed
if grep -rInE '([A-Za-z0-9_-]{40,}|BEGIN [A-Z ]*PRIVATE KEY)' --include='*.yaml' --include='*.py' --include='*.template' . \
   | grep -v "basicauth.users" | grep -vE '^\S+:[0-9]+:\s*#'; then
  fail "possible secret committed"
fi
ok "no secrets in tree"

# 5. the isolation invariant this stack depends on
python3 - <<'PY' || exit 1
import re
s = open("docker-compose.yaml").read()
def block(name):
    m = re.search(r"^  %s:\n(.*?)(?=^  \S|\Z)" % re.escape(name), s, re.S | re.M)
    assert m, f"{name} service missing"
    return m.group(1)
cf = block("camouflare")
assert "networks: [arr]" in cf, "camouflare must stay off the coolify bridge"
assert "coolify" not in cf.replace("camouflare", ""), "camouflare must not join coolify net"
auth = block("camouflare-auth")
assert "coolify" in auth, "ingress hop must join coolify so Traefik can route it"
shim = block("camouflare-shim")
assert "coolify" not in shim, "shim must stay private"
print("ok: network isolation invariants")
PY

printf '\nverify: PASS\n'
