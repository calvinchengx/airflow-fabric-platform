#!/usr/bin/env bash
# Bring up an Airflow 3 stack and provision the connections the product asks
# for by name. Everything here is platform business; the product never sees it.
set -euo pipefail

airflow db migrate >/dev/null

# api-server FIRST: in Airflow 3 the scheduler hands tasks to it over HTTP and
# a worker with nothing listening fails every task with `Connection refused`.
airflow api-server &
airflow scheduler &
airflow dag-processor &

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

echo "platform: ready. Airflow UI on :8080 (published as ${AIRFLOW_PORT:-18080})"
wait -n
