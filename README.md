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

Validation-scale parameters stay small enough for local iteration. The
provisional full profile increases the same manifest inputs for scale testing
before reference-runner calibration.

The provisional full-scale profile exercises the declared resource envelope
and is also unscored:

```console
bin/bench run --profile full
```

Its parameters and verification digests can be functionally checked on other
machines, but timing calibration is authoritative only on x86-64 Ubuntu 24.04
with 4 vCPU and 16 GB of memory. In particular, timings from larger development
orbs must not be used to claim the 19–21 minute reference target.

See [the implementation plan](docs/plans/initial-implementation.md) for the
benchmark contract and remaining delivery slices.
