# fabric-platform-airflow3

[![CI](https://github.com/calvinchengx/fabric-platform-airflow3/actions/workflows/ci.yml/badge.svg)](https://github.com/calvinchengx/fabric-platform-airflow3/actions/workflows/ci.yml)
[![Airflow 3.3.1](https://img.shields.io/badge/Apache_Airflow-3.3.1-017CEE?logo=apacheairflow&logoColor=white)](versions.env)
[![fabric-emulator 0.28.0](https://img.shields.io/badge/fabric--emulator-0.28.0-6264A7)](versions.env)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**The platform, and nothing else.** Apache Airflow 3 plus a Fabric target, as a
thing you can pin. It contains no data product: no DAGs, no dlt sources, no dbt
models, and no product name anywhere in it.

Point it at a data product repository and it runs that one:

```sh
make up PRODUCT=../contoso-data-product-fabric-airflow3
```

## Why this is its own repository

A data engineer writes a product once. The platform it runs on is a separate
decision with a separate lifecycle: a fabric-emulator release moves `versions.env`
here and no product repo changes, and a second product can use this unchanged.
That is the test of the boundary, and it only holds if the boundary is a repo.

**Nothing here modifies Airflow or fabric-emulator.** Both are published images,
pinned by digest. The only thing this repo builds is a worker image that is
`apache/airflow` plus `uv pip install` of the product's own `pyproject.toml` —
three lines, and it names no package.

## What a product must provide

| path in the product repo | what it is |
|---|---|
| `dags/` | the DAG bundle Airflow discovers |
| `pyproject.toml` | what the worker must be able to import |

Nothing else is assumed.

## Local and production are the same platform

The difference is configuration, not code:

| | local | production |
|---|---|---|
| DAG bundle | `LocalDagBundle` at a bind mount | `GitDagBundle` at a tag |
| Fabric | `fabric-emulator` image | real Fabric |
| identity | `entra-emulator`, client credentials | real Entra, `DefaultAzureCredential` |
| connections | provisioned by `make up` | provisioned by your deployment |

The DAGs do not change. They ask for a connection by name and never learn which
target answered.

Apache-2.0.
