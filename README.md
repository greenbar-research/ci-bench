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
bin/bench fixtures
bin/bench doctor --profile smoke
bin/bench run --profile smoke
```

The smoke profile starts pinned PostgreSQL and Redis containers, exercises
database, file-I/O, and Playwright browser workloads, then writes a validated
JSON record under `results/`. It is intentionally small and is not a scored
provider result. Run `docker compose down` when you no longer need the local
services.

`bin/bench fixtures` regenerates the small contract fixtures in memory and
checks their digests against the checked-in checksum manifest.

Slice 2 workload mechanisms land first in the unscored validation profile. Run
the current groups independently with the commands below. The disk group also
requires ImageMagick 7 (`magick`) and `tar`; `bin/bench doctor` checks both
before starting work.

```console
bin/bench run --profile validation --workload rails-postgres
bin/bench run --profile validation --workload disk-active-storage
bin/bench run --profile validation --workload memory-import
bin/bench run --profile validation --workload cpu-assets
```

Validation-scale parameters stay small enough for local iteration; the same
manifest inputs will be increased for the calibrated full profile.

See [the implementation plan](docs/plans/initial-implementation.md) for the
benchmark contract and remaining delivery slices.
