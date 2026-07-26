---
status: active
last_reviewed: 2026-07-26
---

# Initial ci-bench implementation

## Summary

Build an open-source CI benchmark around a realistic Rails application whose
test workload takes approximately 20 minutes when run serially on the reference
runner. The application will exercise the resources and lifecycle stages that
commonly dominate CI: dependency installation, PostgreSQL and Redis startup,
CPU-heavy work, memory pressure, disk I/O, Docker builds, and browser system
tests.

The first version has one source-code host and two CI targets:

| Source-code host | CI engine | Compute |
| --- | --- | --- |
| GitHub | GitHub Actions | Standard GitHub-hosted runner |
| GitHub | Buildkite Pipelines | Buildkite Hosted Agent |

Both targets will run the same commit, commands, workload inputs, and nominal
resource envelope. The primary result is elapsed time from a GitHub push being
accepted until the target's required check is green. Exact-SHA API-triggered
runs will supplement push-triggered runs when the benchmark needs to repeat an
unchanged tree for warm-cache measurements.

The benchmark will publish timings and reliability directly. It will not
measure cost or collapse materially different profiles into one composite
score.

## Problem

CI performance claims are usually based on synthetic microbenchmarks, selected
customer examples, or runner specifications. Those comparisons do not show how
the complete system behaves when a real application checks out code, restores
caches, installs dependencies, starts services, runs heterogeneous tests,
uploads results, and reports a status to the source-code host.

Caching makes simple repeated-run comparisons especially weak. A provider can
look excellent when nothing changes, then lose most of that advantage after a
lockfile, Docker layer, or broad section of the codebase changes. The benchmark
therefore needs a repeatable sequence of realistic mutations, not only cold and
perfectly warm runs.

## Goals

- Produce a credible Rails workload that takes 19–21 minutes under the serial
  profile on the reference GitHub-hosted runner after the toolchain is present.
- Compare GitHub Actions and Buildkite from the same GitHub repository and
  immutable commit.
- Exercise CPU, memory, disk, Docker, database, cache, and browser workloads
  through useful application behavior rather than sleeps or arbitrary burn
  loops.
- Measure cold, warm, and four-way parallel execution.
- Measure how targeted and broad code changes, dependency changes, and Docker
  layer changes degrade or preserve warm performance.
- Publish raw, machine-readable results with enough phase timing and machine
  metadata to explain the headline elapsed time.
- Make every scored result reproducible and correctness-checked.

## Non-goals for the first version

- Comparing Depot CI, RWX, Namespace runners, other CI systems, or other SCMs.
- Supporting Cursor Origin before the product and its integration contract are
  available.
- Designing a generic forge or CI adapter framework. A third target should
  provide the evidence for any shared abstraction.
- Comparing price, price/performance, macOS, Windows, ARM, GPUs, or
  self-hosted runners.
- Letting either target use more than four concurrent benchmark jobs.
- Testing provider outage recovery, very large concurrency, or organization
  administration.
- Producing a single overall score.

## Benchmark contract

### Reference runner

The portable comparison will use:

- x86-64 Linux
- Ubuntu 24.04 userspace
- 4 vCPU
- 16 GB declared memory
- at least 14 GB of working storage
- at most four concurrent jobs in the parallel profile

This matches the current standard runner for public GitHub repositories and
Buildkite's medium `LINUX_AMD64_4X16` hosted-agent shape. GitHub documents its
public Linux runner as 4 vCPU, 16 GB RAM, and 14 GB SSD. Buildkite documents its
medium Linux hosted agent as 4 vCPU and 16 GB RAM.

The repository must be public before collecting official results because
GitHub's standard runner for a private repository has a different resource
allocation. Every run will record the observed CPU model, CPU count, available
memory, filesystem type, available disk, kernel, image identifier, and relevant
tool versions. Nominally equal sizes do not imply equal processors or storage;
those differences are part of hosted CI performance and must remain visible.

### Workload invariants

- Both targets run the same Git commit and benchmark manifest.
- CI configuration may express orchestration and native cache operations, but
  workload commands live in common `bin/ci/*` and `bin/bench` entry points.
- Dependency versions and container images are locked; container bases are
  pinned by digest for scored runs.
- Workload scale comes from versioned fixtures and manifest parameters. Target
  name, CI provider, branch name, and run ID must never change the amount of
  useful work.
- Tests produce checksums, counts, or output manifests that the harness verifies
  before accepting a result.
- A cached task is valid only when it returns the same declared outputs for the
  same inputs. The benchmark must not manually skip tests based on knowledge of
  a published scenario.
- Peak benchmark data must leave enough headroom on GitHub's 14 GB disk. The
  initial target is less than 8 GB of peak benchmark-owned disk and less than
  10 GB total free-space consumption.
- A result is invalid, rather than slow, when the runner violates the declared
  resource envelope or correctness checks fail.

### Platform configuration

GitHub Actions will use `ubuntu-24.04` and supported GitHub cache primitives.
Buildkite will use a medium x86-64 hosted queue and its supported persistent
cache volume. Both configurations will use the same logical cache inputs and
paths even though storage and transfer mechanisms differ.

The first scored comparison will exclude enterprise-only remote Docker
offloading and custom images with preinstalled application dependencies. Those
features can become a separately labelled product-native profile later. The
portable profile should test generally available 4-vCPU hosted execution,
including each platform's normal provisioning and cache implementation.

## Reference application

Create a conventional multi-tenant Rails application at the repository root.
The domain can model projects, builds, test cases, artifacts, audit events, and
users. This gives the benchmark believable relational data, background work,
uploads, reporting, and browser flows without importing third-party application
code or data.

Use PostgreSQL, Redis, Active Job, Active Storage, and a Chromium browser driven
by Playwright. Start PostgreSQL and Redis through the same pinned Docker Compose
definition on both targets instead of using provider-specific service
declarations.

The serial workload will execute these groups sequentially:

| Workload | Approximate reference time | Representative behavior |
| --- | ---: | --- |
| Rails and PostgreSQL | 6 minutes | Model, request, transaction, query, reporting, migration, and concurrent-update tests over generated relational fixtures |
| Disk and Active Storage | 3 minutes | Upload, checksum, archive, extract, copy, transform, and delete multi-gigabyte artifact sets |
| Memory | 2–3 minutes | Import and aggregate large CSV/JSON result sets with a controlled 5–7 GB high-water mark |
| CPU | 2–3 minutes | Asset compilation, compression, hashing, rendering, and serialization using all four cores |
| Docker | 2 minutes | Build the application image, create layers, start it, and verify its health and output |
| Browser system tests | 3 minutes | Authentication, project creation, artifact upload, result filtering, and report views in Chromium |

These are calibration budgets, not sleeps. Fixture cardinality, file sizes, and
test case counts will be adjusted until five reference runs land within the
target range. Each group must remain independently runnable so its timing and
resource profile can be inspected.

## Execution profiles

### Cold serial

Run the complete workload in one job with a new benchmark cache epoch. Explicit
dependency, asset, and Docker caches must miss. Provider-owned image, package,
git-mirror, and infrastructure caches may still be warm and cannot always be
flushed; this profile will be described as **benchmark-cold**, not
infrastructure-virgin.

The primary cold result includes queueing, runner provisioning, checkout,
toolchain setup, dependency installation, service startup, the 20-minute
workload, artifact upload, and status publication.

### Warm serial

Trigger the same commit and configuration again after a successful cold serial
run. Use the same logical cache epoch and record exact, partial, and missed
cache outcomes where the platform exposes them.

### Warm four-way parallel

Run four fixed shards on four 4-vCPU/16-GB jobs after caches are warm. A small
fan-in job verifies every declared test and output exactly once, then publishes
the required status.

The first shard map will be checked into the benchmark manifest and balanced
from reference measurements. Dynamic test allocation is deferred because it
would introduce another product capability before the basic comparison is
stable.

Report total trigger-to-green time, each shard duration, and the slowest-shard
gap. The concurrency cap is four active workload jobs per target.

## Churn protocol

Maintain a versioned baseline commit and independent mutation commits. Each
mutation branches from the same baseline so scenarios do not accumulate.

For each scenario:

1. Run the baseline to prime its logical caches.
2. Repeat the baseline to establish warm performance.
3. Push the mutation commit and measure its first run.
4. Repeat the mutation commit to measure warm-cache recovery.

The initial mutations are:

| Scenario | Change | Intended invalidation |
| --- | --- | --- |
| Empty tree change | Commit metadata only | No workload cache inputs; control for scheduling and checkout |
| Targeted Rails change | One model/service behavior and its tests | Small code and test subset, without dependency invalidation |
| Broad Rails change | A cross-cutting feature spanning models, jobs, views, assets, and tests | Most application/test outputs while preserving dependencies |
| Ruby dependency change | One ordinary direct gem update in `Gemfile.lock` | Bundler cache and downstream application outputs |
| JavaScript dependency change | One package update in the lockfile | Package, asset, and relevant browser outputs |
| Late Docker change | Application content copied near the end of the Dockerfile | Late layers only |
| Early Docker change | Base-system or dependency layer input | Most Docker layers |

The mutation commits must change functioning behavior and update assertions;
bulk touching files or changing comments is not a substitute for code churn.
All scenarios will publish the changed file count, changed byte count, cache
events, setup time, execution time, and delta from the warm baseline.

## Measurement model

### Headline metrics

Publish separate leaderboards for:

- benchmark-cold serial trigger-to-green
- warm serial trigger-to-green
- warm four-way parallel trigger-to-green
- each churn scenario's first-run regression and recovery time

For each, report median, p95, minimum, maximum, and success rate over a labelled
rolling window. Do not trim failures or hide them in a timing average.

### Timeline

The controller and in-job harness together will record:

1. Git push started and accepted by GitHub.
2. Workflow or build created.
3. Job queued.
4. Runner assigned and job started.
5. Checkout completed.
6. Cache restore completed.
7. Toolchain and dependencies ready.
8. PostgreSQL and Redis healthy.
9. Each workload group started and completed.
10. Cache and artifact publication completed.
11. CI run completed.
12. Required GitHub status became green.

The controller's clock is authoritative for the outer push-to-green interval.
The in-job harness will use a monotonic clock for phase durations. Provider API
timestamps are useful supporting evidence but will not be subtracted across
independently synchronized clocks without recording the uncertainty.

### Result record

Every attempt emits a JSON result conforming to a checked-in schema. At minimum
it contains:

```json
{
  "schema_version": 1,
  "benchmark_version": "ci-bench-v1",
  "run_id": "opaque-id",
  "commit_sha": "full-sha",
  "git_dirty": false,
  "partial": false,
  "scored": true,
  "target": "github-actions",
  "profile": "warm-serial",
  "scenario": "ruby-dependency",
  "status": "passed",
  "runner": {},
  "timeline": {},
  "workloads": [],
  "caches": [],
  "resources": {},
  "verification": {}
}
```

Raw attempt records are immutable. Summary generation reads raw records and can
be reproduced locally; it never rewrites or normalizes source measurements.

## Repository structure

Keep the Rails application conventional and put benchmark-specific code in
obvious boundaries:

```text
.buildkite/
  pipeline.yml
.github/
  workflows/
    benchmark.yml
benchmark/
  manifest.yml
  schema/
    result-v1.json
  scenarios/
  harness/
bin/
  bench
  ci/
    setup
    services
    serial
    shard
    verify
docs/
  plans/
results/
  README.md
```

Do not create a general provider SDK. The two CI definitions should call the
same scripts directly, while a small controller may have explicit
`github_actions` and `buildkite` implementations for triggering and observing
runs.

## Safe public-repository operation

Official benchmark runs will use branches pushed by a dedicated controller
identity in the canonical repository. Secret-bearing Buildkite jobs must not
run automatically for forked pull requests.

Contributions from forks will run a reduced, secretless validation profile on
GitHub Actions. A maintainer can explicitly authorize the full benchmark after
review. GitHub environment protections and narrowly scoped GitHub App or token
permissions should prevent benchmark code from changing repository settings,
secrets, historical results, or unrelated branches.

Generated fixtures must contain no production or personal data. Logs and result
artifacts must be scanned for environment variables and tokens before public
publication.

## Current state

Slice 1 is implemented locally on `lox/initial-benchmark`. The repository now
contains the pinned Rails application and toolchain, ephemeral PostgreSQL and
Redis services, a manifest-driven smoke harness, resource sampling, a v1 result
schema, and deterministic database, file-I/O, and Playwright browser workloads.

`bin/bench doctor --profile smoke` passes on the development host. Repeated
smoke runs complete in under ten seconds and produce the pinned verification
digest
`4addb8bd1d607fc7bd4416f69a267077ed2ef65aad278df3f39583fb9ca2185d`.
The smoke profile records dirty-tree provenance and remains explicitly
unscored.

Slice 2 harness work is active. CPU samples now use per-process CPU-time deltas
rather than platform-specific `ps %cpu` values, so Linux and macOS share the
same measurement mechanism.

The harness-contract step is complete: workload parameters, timeouts, resource
limits, expected digests, partial workload runs, verification/telemetry
separation, canonical digesting, scoped disk cleanup, and deterministic fixture
checks are implemented. The Rails domain now includes users and sessions,
project ownership, builds and test cases, artifact metadata and Active Storage,
audit events, and deterministic build-report filtering. All six full workload
groups are implemented at validation scale. The Rails/PostgreSQL group
streams deterministic relational fixtures,
executes ORM transactions, repeats aggregate reports, and applies atomic
concurrent updates. Its validation profile is pinned and unscored; calibration
scale remains pending. PostgreSQL uses a 1.5 GiB tmpfs cap, and each workload
reports its database bytes into the benchmark disk limit. The disk and Active
Storage group is also implemented at validation scale, covering deterministic
multi-file generation, upload/download, archive/extract/copy, a MiniMagick
variant, and synchronous record-and-byte cleanup. Its concurrent source,
storage, download, archive, extract, and copy trees amplify source bytes by
about six times, so calibration will keep source artifacts at or below 1.5 GiB
and the measured peak below the benchmark's 10 GiB disk envelope. The memory
group now streams deterministic CSV and NDJSON imports separately from
incompressible retained allocations, so row volume and the eventual 5–7 GiB
high-water mark can be calibrated independently. The CPU group now compiles the
real Propshaft asset graph and runs deterministic compression, hashing, ERB
rendering, and JSON serialization across four worker processes. The Docker
group builds the production application image with BuildKit, verifies its
layers and runtime metadata, boots it against a scoped PostgreSQL database,
checks its health and deterministic Rails output, accounts for exact daemon
disk bytes, and removes scoped containers and images on success or failure. The
browser system group drives authentication, project and build creation, test
result filtering, report totals, artifact upload, and sign-out through
Chromium, with generated inputs and verification digests kept deterministic.

## Delivery strategy

### Slice 1: Contract and smoke workload (implemented)

Create the Rails application, pinned toolchain, Docker Compose services,
benchmark manifest, result schema, resource sampler, and `bin/bench` entry
point. Implement one database test, one file-I/O test, and one browser flow that
complete locally in under two minutes.

Definition of done:

- `bin/bench doctor` validates required tools and available resources.
- `bin/bench run --profile smoke` produces a schema-valid JSON record.
- Repeating the smoke run produces identical verification outputs.
- No CI account or remote pipeline is required.

### Slice 2: Full serial workload

Implement each workload group and deterministic fixture generator. Add
correctness manifests and resource limits before scaling fixture sizes.
Calibrate on the standard public GitHub-hosted runner.

Start with a harness-contract step before implementing workload groups:

- Split deterministic verification values from host-dependent telemetry.
- Canonically digest verification objects and reject floating-point values.
- Put seed, parameters, timeout, resource limits, and expected verification on
  each manifest workload.
- Support `bin/bench run --profile full --workload NAME` so every group can run
  and verify independently.
- Throttle disk-size sampling so the observer does not materially perturb
  multi-gigabyte I/O, and account for Active Storage and Docker-owned bytes.

Slice 2 may add one temporary, explicitly unscored GitHub Actions calibration
workflow. It installs the pinned toolchain and runs only the full serial
profile, with no benchmark caches, sharding, cold/warm orchestration, scheduled
runs, or publication. This is the minimum mechanism needed to complete the five
reference runs in this slice; Slice 3 replaces it with the scored Actions
baseline.

Definition of done:

- Every group runs and verifies independently.
- The combined workload takes 19–21 minutes across five reference runs after
  dependencies are present.
- No individual group exceeds the disk or memory envelope.
- Variance and resource traces are documented; unstable workload mechanisms
  are replaced rather than masked.

### Slice 3: GitHub Actions baseline

Add benchmark-cold, warm serial, and four-shard GitHub Actions jobs. Implement
the logical dependency, asset, browser, and Docker caches. Upload raw attempt
records and a fan-in verification manifest.

Definition of done:

- Cold and warm runs can be triggered against an exact SHA.
- Four shards account for every declared test and output exactly once.
- Phase timings reconcile with the outer workflow duration.
- Failed or incomplete verification cannot produce a green required check.

### Slice 4: Buildkite comparison

Provision a medium Buildkite Hosted Agent queue and add the Buildkite pipeline.
Map the same logical cache contract to a Buildkite cache volume without changing
workload inputs or scale.

Definition of done:

- One GitHub push triggers both CI targets for the same SHA.
- The controller discovers and follows both runs without using UI scraping.
- Both results pass the same schema and correctness verification.
- Machine metadata confirms the declared runner envelope.

### Slice 5: Churn suite

Create and review the independent mutation commits, then automate the
prime/warm/mutate/recover protocol.

Definition of done:

- Every scenario starts from the recorded baseline tree.
- Both targets receive byte-identical commits.
- Cache events and phase deltas explain each headline result.
- Running scenarios in a different order does not materially change their
  conclusions.

### Slice 6: Scheduled publication

Run three core trials per target nightly and the complete churn suite weekly.
Generate a static report from immutable JSON records. Use a rolling sample large
enough to report p95 rather than treating three nightly attempts as a
distribution.

Definition of done:

- The scheduler randomizes or simultaneously launches targets to limit
  time-of-day bias.
- Failed attempts remain public and contribute to success rate.
- A clean checkout can validate raw records and reproduce the published tables
  and charts.
- Benchmark version changes start a new result series.

## Verification

- Unit-test manifest parsing, event collection, cache-key derivation, shard
  accounting, result validation, and summary statistics.
- Run malformed and partial result fixtures through the reporter; it must fail
  closed rather than publishing incomplete timings.
- Verify fixture generation is deterministic from a checked-in seed and emits
  expected checksums.
- Sample CPU, resident memory, disk bytes, filesystem capacity, and process exit
  status throughout each workload.
- Repeat reference calibration at least five times and investigate groups whose
  coefficient of variation exceeds 10%.
- Confirm a deliberately failed test, missing shard, corrupted output, cache
  mismatch, and out-of-resource runner all prevent a scored green result.
- Compare the common command transcript from both targets to ensure CI YAML has
  not silently changed workload behavior.
- Validate that fork pull requests cannot access Buildkite or publication
  credentials.

## Resolved decisions

- GitHub is the only SCM for the first version.
- The initial comparison is GitHub Actions versus Buildkite Hosted Agents.
- The repository will be public for official results.
- The reference envelope is x86-64 Ubuntu 24.04 with 4 vCPU and 16 GB RAM.
- Four concurrent workload jobs is the parallelism limit.
- The suite itself targets 20 minutes serially; setup and reporting remain
  visible additional time.
- Performance and reliability are reported; cost is excluded.
- Cold, warm, parallel, and churn results stay separate instead of becoming one
  composite score.
- Provider-native caching is allowed when it implements the same declared cache
  inputs and outputs.
- A generic target or forge adapter API is deferred until another CI system or
  SCM is actually added.

## Key learnings from pressure-testing

An absolutely cold hosted machine is not observable or enforceable, so the plan
defines coldness at the benchmark's cache boundary and records transparent
platform caches instead of making a stronger claim. Matching vCPU and memory
also does not normalize CPU generation, storage, or network, so the plan records
the hardware rather than attempting to subtract those product differences.

The 20-minute workload makes a full matrix too expensive and slow to repeat
enough for useful tail statistics every day. The schedule therefore keeps a
small nightly core and runs the full churn journey weekly, with p95 calculated
over a clearly labelled rolling series.

The public repository needs secrets to trigger and publish the Buildkite side,
which makes untrusted pull-request execution unsafe. Full benchmark runs are
restricted to controller-owned branches, while ordinary contributions receive
a reduced secretless validation path.

Finally, two targets do not justify a provider framework. Keeping two explicit
pipeline definitions around common workload scripts makes the first result
easier to audit and avoids guessing at requirements from Depot, RWX, Namespace,
or a future forge.

## References

- [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Using GitHub-hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/use-github-hosted-runners)
- [Buildkite Linux hosted agents](https://buildkite.com/docs/agent/v3/buildkite-hosted/linux)
- [Buildkite hosted agents](https://buildkite.com/docs/agent/buildkite-hosted)
- [ComputeSDK public benchmark methodology](https://github.com/computesdk/benchmarks)
