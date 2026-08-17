"""Stand up whatever vendors a sources repo declares.

THE PLATFORM OWNS THE MECHANISM, THE DECLARATION OWNS THE CONTENT — the same
split as the DAG bundle. This file knows how to run an OpenAPI simulator and a
CDC stack; it does not know that Contoso exists, how many vendors there are, or
what any of them serve. Point it at a different `sources.yaml` and it stands up
those vendors instead.

That is not tidiness. In production none of this runs at all: the vendors are
real, and the only thing that survives is their Airflow Connection names. A
platform that hard-coded three mokapis would have encoded a local convenience
into the thing that is supposed to be target-independent.

Emits a compose fragment on stdout rather than starting anything itself, so the
services join the same project, network and lifecycle as the rest of the stack
and `make down` really does take everything with it.
"""
from __future__ import annotations

import json
import pathlib
import sys


def _load(path: pathlib.Path) -> dict:
    """Read sources.yaml without a YAML dependency.

    The platform image is stock `apache/airflow` plus the product's own
    dependencies; adding PyYAML here would mean the platform has opinions about
    the worker's environment. The declaration is a small, flat document, so a
    minimal reader is cheaper than that coupling — and it FAILS on anything it
    does not understand rather than guessing, because a silently-skipped vendor
    would surface much later as an empty landing.
    """
    vendors: list[dict] = []
    current: dict | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip() or line.strip() in ("vendors:",) or line.startswith("version:"):
            continue
        stripped = line.strip()
        if stripped.startswith("- "):
            current = {}
            vendors.append(current)
            stripped = stripped[2:]
        if current is None or ":" not in stripped:
            continue
        key, _, value = stripped.partition(":")
        value = value.strip()
        if value.startswith("[") and value.endswith("]"):
            value = [v.strip() for v in value[1:-1].split(",") if v.strip()]
        current[key.strip()] = value
    return {"vendors": vendors}


def fragment(decl: dict, sources_dir: str, mokapi_version: str) -> dict:
    services: dict = {}
    for v in decl["vendors"]:
        name = v["name"].replace("_", "-")
        kind = v.get("kind")
        if kind == "openapi":
            services[name] = {
                "image": f"mokapi/mokapi:{mokapi_version}",
                # The dashboard retains every request AND its response body. For
                # a large export that is a multi-hundred-MB copy per call, so the
                # history is capped at one entry per API -- the reason this flag
                # exists is a container that was being OOM-killed mid-response.
                "command": ["--event-store-default-size=1",
                            f"/sources/{v['spec']}", f"/sources/{v['script']}"],
                # Go does not read the cgroup limit; without GOMEMLIMIT the heap
                # climbs past mem_limit and the container dies mid-response.
                "environment": {"GOMEMLIMIT": "2GiB"},
                "volumes": [f"{sources_dir}:/sources:ro"],
                "expose": [str(v["port"])],
            }
        elif kind == "cdc":
            # Deliberately unimplemented rather than approximated. The ERP's
            # point is that history arrives as a CHANGE STREAM; standing up a
            # plain Postgres here would serve rows, possibly even the right
            # count, while testing something else entirely.
            print(f"platform: vendor {v['name']!r} is kind=cdc, not yet supported "
                  f"by this platform -- skipping", file=sys.stderr)
        else:
            raise SystemExit(
                f"platform: vendor {v['name']!r} declares kind={kind!r}, which this "
                f"platform does not know how to run. Add it here or fix the "
                f"declaration; guessing would stand up the wrong vendor.")
    return {"services": services}


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit("usage: sources.py <path-to-sources.yaml> <sources-dir-abs>")
    decl = _load(pathlib.Path(sys.argv[1]))
    if not decl["vendors"]:
        sys.exit("platform: that sources.yaml declares no vendors")
    # The simulator version comes from the SOURCES repo. A platform that
    # defaulted it would be deciding what the vendor is, and a wrong guess
    # fails at pull time with `manifest unknown` -- which is how this line got
    # written, after inventing a tag that does not exist.
    versions = pathlib.Path(sys.argv[2]) / "versions.env"
    pins = dict(
        line.split("=", 1) for line in versions.read_text().splitlines()
        if "=" in line and not line.strip().startswith("#")
    ) if versions.exists() else {}
    mokapi = pins.get("MOKAPI_VERSION")
    if not mokapi:
        sys.exit(f"platform: {versions} does not pin MOKAPI_VERSION, and this "
                 f"platform will not guess a vendor simulator's version")
    print(json.dumps(fragment(decl, sys.argv[2], mokapi.strip()), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
