#!/usr/bin/env bash
# Bring up an Airflow 3 stack and provision the connections the product asks
# for by name. Everything here is platform business; the product never sees it.
set -euo pipefail

airflow db migrate >/dev/null

# api-server FIRST: in Airflow 3 the scheduler hands tasks to it over HTTP and
# a worker with nothing listening fails every task with `Connection refused`.
# ORDER MATTERS, and getting it wrong is a race a restart loses every time.
# The scheduler must not start until the connections exist: this DAG ships
# unpaused with a daily schedule, so the moment the dag-processor finds it the
# scheduler fires a run -- measured at FOUR SECONDS after container start,
# against a platform that had provisioned nothing. The task then failed with
# `The conn_id 'fabric' isn't defined`, which reads like a fault in the product
# rather than a platform that was not ready yet.
#
# api-server first because tasks execute through it and the CLI below wants it
# live; scheduler and dag-processor last, once there is something to run against.
airflow api-server &

for _ in $(seq 1 60); do
  curl -sf http://localhost:8080/api/v2/monitor/health >/dev/null 2>&1 && break
  sleep 2
done

# THE SEAM. The product's DAGs say conn_id="fabric" and nothing else -- no
# host, no tenant, no grant type. Here that resolves to the emulator; in
# production the same conn_id is provisioned against real Fabric and not one
# line of product code changes.
airflow connections delete fabric >/dev/null 2>&1 || true
airflow connections add fabric \
  --conn-type generic \
  --conn-host "${FABRIC_API_ROOT}" \
  --conn-extra "$(python3 - <<'PY'
import json, os
print(json.dumps({
    "api_root": os.environ["FABRIC_API_ROOT"],
    "onelake_url": os.environ["FABRIC_ONELAKE_URL"],
    # The emulator serves OneLake on the Fabric port and routes by Host header,
    # the way `curl --resolve` does. Real Fabric has its own hostname, so this
    # is empty there -- the one target difference, and it lives in the
    # connection rather than in the product.
    "onelake_host_header": os.environ.get("FABRIC_ONELAKE_HOST_HEADER", ""),
    "token_url": os.environ["ENTRA_TOKEN_URL"],
    "client_id": os.environ["ENTRA_CLIENT_ID"],
    "client_secret": os.environ["ENTRA_CLIENT_SECRET"],
    "target": os.environ.get("FABRIC_TARGET", "emulator"),
}))
PY
)" >/dev/null
echo "platform: connection 'fabric' provisioned -> ${FABRIC_API_ROOT}"

# ONE CONNECTION PER DECLARED VENDOR. The product's DAG asks for these by the
# name the declaration gives them and learns nothing else -- so in production
# the same names are provisioned against the real vendors and no DAG changes.
if [ -f "${SOURCES_DECL:-/nonexistent}" ]; then
  python3 - <<'PYEOF'
import json, os, pathlib, subprocess
decl = pathlib.Path(os.environ["SOURCES_DECL"])
root = decl.parent
vendors, cur = [], None
for raw in decl.read_text().splitlines():
    line = raw.split("#", 1)[0].rstrip()
    if not line.strip() or line.strip() == "vendors:" or line.startswith("version:"):
        continue
    t = line.strip()
    if t.startswith("- "):
        cur = {}; vendors.append(cur); t = t[2:]
    if cur is None or ":" not in t:
        continue
    k, _, v = t.partition(":")
    cur[k.strip()] = v.strip()
for v in vendors:
    if v.get("kind") != "openapi":
        continue
    host = f"http://{v['name'].replace('_','-')}:{v['port']}"
    # The vendor's own credential, from its fixture directory. Each vendor has
    # its own key that rotates separately -- that is the point of there being
    # more than one vendor, and sharing one here would erase it.
    key_file = root / v["data"] / ".api-key"
    key = key_file.read_text().strip() if key_file.exists() else ""
    # IDEMPOTENT, and LOUD when it fails. Provisioning runs on every start
    # against a metadata DB that may already carry these -- an existing
    # connection is the normal case on restart, not an error. It used to be
    # both: `check=True` under `set -e` meant a second `make up` killed the
    # entire platform, and `capture_output` hid the reason.
    subprocess.run(["airflow", "connections", "delete", v["conn"]],
                   capture_output=True)
    r = subprocess.run(["airflow", "connections", "add", v["conn"],
                        "--conn-type", "http", "--conn-host", host,
                        "--conn-password", key],
                       capture_output=True, text=True)
    if r.returncode != 0:
        # Report and carry on: one vendor that cannot be provisioned should
        # fail ITS OWN tasks with a missing-connection error, not prevent the
        # platform from starting at all.
        print(f"platform: WARNING could not provision {v['conn']!r}: "
              f"{(r.stderr or r.stdout).strip()[:300]}", flush=True)
    else:
        print(f"platform: connection {v['conn']!r} provisioned -> {host}", flush=True)
PYEOF
fi

# Only now is it safe to let anything run.
airflow scheduler &
airflow dag-processor &

echo "platform: ready. Airflow UI on :8080 (published as ${AIRFLOW_PORT:-18080})"
wait -n
