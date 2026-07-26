# ci-bench

`ci-bench` is an open-source benchmark for measuring end-to-end CI performance
with a realistic Rails application.

The first version uses GitHub as the only source-code host and compares GitHub
Actions on standard GitHub-hosted runners with Buildkite Pipelines on Buildkite
Hosted Agents. Cost is deliberately outside the comparison.

## Local smoke benchmark

Install [mise](https://mise.jdx.dev/) and Docker, then run:

```console
mise install
bin/setup
bin/bench doctor --profile smoke
bin/bench run --profile smoke
```

The smoke profile starts pinned PostgreSQL and Redis containers, exercises
database, file-I/O, and Playwright browser workloads, then writes a validated
JSON record under `results/`. It is intentionally small and is not a scored
provider result. Run `docker compose down` when you no longer need the local
services.

See [the implementation plan](docs/plans/initial-implementation.md) for the
benchmark contract and remaining delivery slices.
