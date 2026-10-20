---
status: active
last_reviewed: 2026-10-20
---

# Unscored GitHub native vs Buildkite GHAC pilot

## Purpose

This slice prepares a small, unscored comparison between the same GitHub
Actions workflow on GitHub-hosted runners and on Buildkite through GitHub
Actions compatibility (GHAC). The same workflows also select runner providers
through the `runner` input (see [Matched stage](#matched-stage-rebaseline)).
The Buildkite prerequisites were resolved on 2026-10-20 (see
[Buildkite blocker](#buildkite-blocker-resolved-2026-10-20)).

The pilot does not rank providers, report p95 latency, or publish results.
It produces raw, private evidence that shows whether the contract and
instrumentation are sound before larger runs.

## Contract

- **Source:** one immutable pushed revision of `greenbar-research/ci-bench`.
  `.github/workflows/pilot.yml` dispatches from `main`, and the dispatch
  requires `expected_sha`. A job that checks out any other commit fails and
  is recorded as an invalid sample.
- **Workloads:** the existing `bin/bench` profiles, unchanged:
  - `smoke` is the smoke/setup baseline, with pinned digest `4addb8bd…`.
    It installs the full Ruby, Node, ImageMagick, and browser stack and
    starts services, so it is not pure orchestration overhead.
  - `full` is the existing full serial Rails workload, with pinned digest
    `3bdfcd70…`.
  - Useful work and verification digests come from `benchmark/manifest.yml`
    and must be identical on every target.
  - The approved pilot also includes a short workflow-overhead measurement.
    The smoke/setup baseline does not fulfil it. The initial four-run
    allocation is used up, so it has a separate allocation of at most two
    runs of `.github/workflows/probe.yml` (see
    [Orchestration probe](#orchestration-probe)).
- **Shape:** one job per dispatch. Concurrency group
  `ci-bench-pilot-<runner>` serializes dispatches per target, and the
  controller keeps at most four workload jobs active across all targets.
- **Targets:** the `runner` input selects `runs-on`. `ubuntu-24.04` is
  GitHub-hosted, or Buildkite GHAC through `linux-medium`. Runner providers use
  their own 4 vCPU / 16 GB Ubuntu 24.04 labels. `pilot-runner` derives the
  target from the label and the runner environment, and provenance requires it
  to match the controller's target.
- **Runner envelope:** `bin/ci/pilot-runner` records the runner and enforces
  the envelope:
  - x86-64, Ubuntu 24.04, exactly 4 CPUs, 15–17 GiB of memory, and at least
    14 GiB of free disk;
  - CPU model, kernel, image OS and version, filesystem, and Docker
    server/storage driver;
  - Docker endpoint and buildx driver, which show builder locality.

  A mismatch fails the job before the workload runs and invalidates the
  sample for comparison.
- **Cache epochs:** one explicit `actions/cache` entry stores the Bundler,
  npm, and Playwright browser caches. Its key is:

  ```text
  ci-bench-pilot-<cache_epoch>-<profile>-<os>-<lockfile hash>
  ```

  The cache-phase rules are:
  - A `cold` run must miss the key. A hit fails the run.
  - A `warm` run must use the same epoch and commit after a successful cold
    run, and must hit the key. A miss fails the run.
  - The actual hit or miss outcome is recorded.
- **Not virgin:** provider-owned caches cannot be flushed and remain unknown.
  These include runner image tool caches, preinstalled Docker layers, package
  mirrors, and CDN caches. "Cold" therefore means benchmark-cold only.
- **Unscored:** `benchmark/manifest.yml` keeps `scored: false` for every
  profile.

## Instrumentation and evidence

Evidence is collected at four levels.

**Controller** (`bin/ci/pilot-github dispatch`):
- Records the request time and the API acceptance time on the orb clock.
- Captures the run ID, which the workflow dispatch API returns through
  `return_run_details`, so the controller does not need to poll for the run.

**Provider** (`bin/ci/pilot-github collect`):
- Records the run, attempt, and job IDs and the run creation time.
- Records the job's queued, started, and completed times, plus step timings.
- Records the terminal status, the runner name, and the labels.
- Saves sanitized raw logs.
- Records the collector observation time separately from provider completion
  time.

**In job:**
- `bin/ci/pilot-mark` writes runner-clock phase boundaries for these phases:
  - checkout
  - cache
  - setup
  - dependencies
  - services
  - workload
  - artifact collection
- The job also saves the `bin/bench` result, which includes:
  - the target (`github-actions` or `buildkite-ghac`)
  - the exact SHA and dirty flag
  - per-workload durations and the verification digest
  - resource samples
- It saves runner and cache facts and a `SHA256SUMS` file covering all
  collected evidence.
- An `always()` step uploads the evidence as a GitHub Actions artifact
  retained for 30 days, including after failures.

**Provenance** (`bin/ci/pilot-provenance`):
- Writes one companion record for each sample.
- Marks a phase `unknown` when its timing is unavailable. The artifact upload
  duration comes only from provider step timings.
- Labels each sample's `workload_class` (smoke/setup baseline or full serial
  Rails workload).
- Keeps `controller_accept_to_job_completed_ms` under that name. It runs from
  orb-clock acceptance to GitHub-clock job completion, so it excludes
  request-to-acceptance, carries clock skew, and is not a provider
  terminal-result boundary or a complete trigger-to-result interval.
- Computes `comparative_sample_valid` and lists `invalid_reasons`, covering:
  - provider run status other than `completed`, or run or job conclusion
    other than `success`. Such a sample stays retained and invalid even when
    a passing workload result and artifact exist.
  - Docker builder not verified local (`docker_builder_local` requires a
    `unix://` endpoint and the `docker` or `docker-container` driver).
    Remote or unknown builders are invalid.
  - envelope mismatch
  - cache expectation not met
  - digest mismatch
  - SHA mismatch
  - dirty tree
  - checksum failure
  - retried attempt

Each source uses its own clock: controller timestamps use the orb clock,
provider timestamps use GitHub's clock, and phase marks use the runner clock.
Differences across clocks carry skew uncertainty.

Evidence stays in GitHub Actions artifacts and in the controller's gitignored
`tmp/pilot-evidence/` directory. Nothing is published.

## Pins

Actions are pinned to full commits from Buildkite's audited GHAC snapshots.
Native adapters therefore run the exact releases, without fallback.

| Component | Pin | GHAC handling |
| --- | --- | --- |
| `actions/checkout` | `d23441a48e516b6c34aea4fa41551a30e30af803` (v6.1.0) | Native adapter; listed v6 contract |
| `actions/cache` | `27d5ce7f107fe9357f9df03efb73ab90386fccae` (v5.0.5) | Audited cache-v2 snapshot entry (`@actions/cache` 5.0.5), so no `W_CACHE_UNKNOWN_COMMIT_SUBSTITUTED` |
| `actions/upload-artifact` | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` (v7.0.1) | Native ZIP adapter; `artifact-url` empty on Buildkite |
| `ruby/setup-ruby` | `824c0e29fdfc7d689c191c27acc969d2d04b7dd8` (v1.331.0) | Upstream JavaScript |
| `actions/setup-node` | `249970729cb0ef3589644e2896645e5dc5ba9c38` (v6.5.0) | Upstream JavaScript; built-in caching disabled |
| GHAC importer | `bin/ci/pilot-bk-import` (replaces plugin v0.13.0, which gives API-created builds an empty dispatch payload) | Writes the event snapshot and runs `buildkite-gha upload --event-path` |
| GHAC runtime | `buildkite-gha` `0.105.1` (Linux x86-64 archive SHA-256 `a87844dd3ce3aba871b54c27fc2489614fe51e580364678c979b5754715613e2`) | Downloaded and verified by the importer |
| Workload | the pilot commit, `benchmark/manifest.yml`, and lockfiles | Identical on every target |

These decisions remove unsupported or ambiguous cache paths:

- The pilot workflow does not use `ruby/setup-ruby` `bundler-cache` or the
  `setup-node` `cache:` input. Those inputs would add cache clients outside
  the single audited `actions/cache` entry.
- On Buildkite, GHAC routes `actions/cache` to the Buildkite Results cache-v2
  service, not GitHub's cache. Restore and save operations are measured as a
  different implementation behind the same logical key, not as equivalent
  infrastructure. Any additional Buildkite hosted cache volume is outside
  this contract and must not be added silently.
- GHAC mounts its own toolchain volume, `buildkite-gha-linux-amd64`, on
  generated jobs. It is recorded as a provider-owned cache.
- Cluster container caching and Git mirrors are off. Onboarding attested this
  on 2026-10-20; the setting is not visible through the API. The controller
  records the cluster's cache volumes through the API before and after every
  build.
- A Buildkite cold sample is qualified benchmark-cold only when no volume
  other than the GHAC toolchain volume existed before the build. Volumes are
  never deleted.
- Every target sets `BUILDX_BUILDER=default`. `pilot-runner` fails the job
  unless the Docker endpoint is a unix socket and the driver is `docker` or
  `docker-container`.
- Pilot runs use `BUNDLE_PATH=vendor/bundle`, and the cached Playwright
  download directory is `~/.cache/ms-playwright`. GHAC runs generated Linux
  jobs as a dedicated `runner` user, so home-relative paths resolve under
  that user's home directory.

## Local GHAC compatibility check

`buildkite-gha 0.105.1` was downloaded, its checksum was verified, and it ran
with telemetry disabled. These commands were run against this workflow:

- `validate` returned `compilable`.
- `validate --profile hosted` with a `workflow_dispatch` event snapshot
  returned `admitted`.
- `compile` generated a single job, `Pilot smoke cold`.

The only diagnostic was `W_ACTION_RUNTIME_UNKNOWN`: action JavaScript was not
executed. These checks do not show that the actions run correctly on
Buildkite. No cache, checkout, or artifact substitution warnings were
emitted.

Known GHAC behavioral differences to record when the Buildkite side runs:

- There is no GitHub Actions run. `GITHUB_RUN_ID`, `GITHUB_RUN_NUMBER`, and
  `GITHUB_RUN_ATTEMPT` contain Buildkite build values. Build IDs, job IDs,
  timestamps, and artifacts must come from the Buildkite REST API.
- `RUNNER_ENVIRONMENT` is `self-hosted`, and the runner image is not
  GitHub's. Step processes get an allowlisted environment without
  `BUILDKITE_*` variables. `pilot-runner` therefore identifies the host by the
  `buildkite-agent` binary and records the actual facts.
- A `workflow_dispatch` build needs an explicit event snapshot.
  `bin/ci/pilot-buildkite` creates builds through the REST API with
  `CI_BENCH_*` build env, and the importer turns that env into the snapshot.
- The generated graph has three parts:
  - the importer, on `linux-medium`, using the queue's default image;
  - two concurrency gate steps, on the cluster default queue;
  - one workload job per workflow job, keyed `gha-<job>`.

  Graph parity requires exactly the workflow's jobs as workload jobs.
- Ubuntu 24.04 selection maps explicitly to `linux-medium`. The queue must be
  a hosted Linux AMD64 4 vCPU / 16 GB queue, or the samples are invalid.

## Run plan (GitHub only, this slice)

All runs use one pushed pilot revision. At most four initial runs are
allowed, in this order:

1. `smoke` cold, epoch `pilot-<date>-a`
2. `smoke` warm, same epoch (only after step 1 succeeds)
3. `full` cold, a new epoch, gated on correct identity, hardware, and
   instrumentation from steps 1–2
4. `full` warm, same epoch as step 3

At most two additional diagnostic runs are allowed, and only for a specific
corrected failure. Failed samples are preserved.

### Batch status (2026-10-20)

All four initial runs used pilot revision
`16f944b15a91d8935bb525131b87d8e6d22aaff1`, and the allocation is used up.
No diagnostic runs were used. Each run succeeded and is a valid sample under
the provenance rules above. Evidence artifacts expire on 2026-11-19.

| Sample | Epoch | Run | Artifact | CPU |
| --- | --- | --- | --- | --- |
| smoke cold | `pilot-20261020-a` | [39389806750](https://github.com/greenbar-research/ci-bench/actions/runs/39389806750) | [12248554049](https://github.com/greenbar-research/ci-bench/actions/runs/39389806750/artifacts/12248554049) | AMD EPYC 7763 |
| smoke warm | `pilot-20261020-a` | [39390104570](https://github.com/greenbar-research/ci-bench/actions/runs/39390104570) | [12249296628](https://github.com/greenbar-research/ci-bench/actions/runs/39390104570/artifacts/12249296628) | AMD EPYC 9V45 |
| full cold | `pilot-20261020-b` | [39390259355](https://github.com/greenbar-research/ci-bench/actions/runs/39390259355) | [12249963393](https://github.com/greenbar-research/ci-bench/actions/runs/39390259355/artifacts/12249963393) | AMD EPYC 7763 |
| full warm | `pilot-20261020-b` | [39392838022](https://github.com/greenbar-research/ci-bench/actions/runs/39392838022) | [12251336137](https://github.com/greenbar-research/ci-bench/actions/runs/39392838022/artifacts/12251336137) | AMD EPYC 9V45 |

Qualifications:

- The exact cold misses and warm hits are verified. However, each cold/warm
  pair ran on different CPU models. The full pair also differed in runner
  image (20261018.339.1 cold, 20261012.334.1 warm) and kernel. These four
  samples therefore cannot isolate any causal timing benefit from the
  cache, including in the dependency phases. Do not attribute timing
  improvements to the cache from them.
- The short workflow-overhead measurement is not covered by these four runs.
  It has its own allocation (see [Orchestration probe](#orchestration-probe)).

### Orchestration probe

`.github/workflows/probe.yml` ("Unscored orchestration probe") is the pure
short orchestration measurement. Its job does only the following:

- a pinned checkout;
- the `pilot-runner` identity and envelope record;
- a completion marker containing the checked-out SHA;
- the evidence upload.

It installs no dependencies and starts no services, and it is not the
smoke/setup baseline. `bin/ci/pilot-github probe EXPECTED_SHA` dispatches the
probe, records trigger request and acceptance, and polls every 2 s. It records
the last non-terminal response and the first terminal observation, then
collects the run.

Provenance groups intervals by clock:

- **Same clock, orb:** request to acceptance, and request or acceptance to
  terminal observation. Observation includes up to one poll interval plus API
  latency.
- **Same clock, GitHub:** job queue and duration, and run creation to the
  completed run's `updated_at`. GitHub has no run `completed_at`.
- **Cross-clock estimate:** `controller_accept_to_job_completed_ms`.

A probe sample is valid only if all of these hold:

- the run and job succeeded;
- the envelope matches;
- the source SHA matches;
- the marker equals the expected SHA;
- the tree is clean;
- the checksums verify.

At most two probe runs are allowed. A failure is reported with its cause
before any further run.

## Matched stage (rebaseline)

The revision that added the Buildkite importer, `BUILDX_BUILDER=default`, and
the `runner` input changed both workflow files. Its samples therefore form a
new comparison group, recorded in provenance as
`<workflow>@<workflow blob>/<profile>` and labelled a rebaseline. They are not
compared with the `16f944b` or `c8b087a` samples, which stay preserved
unchanged.

Revision R (`581be1b`) ran valid probes on GitHub and Buildkite. Buildkite
full builds 3 and 4 then failed, for two different causes:

- **Build 3:** the pipeline had workflow-authorized GitHub tokens disabled.
  This was fixed in the ci-bench pipeline settings.
- **Build 4:** the GHAC Ubuntu 24.04 agent image lacks `libfontconfig.so.1`,
  which the pinned ImageMagick AppImage needs, so `magick` exited 127.

R2 adds `bin/ci/pilot-system-deps` to the setup phase. It installs any missing
system packages and records them in `system-packages.txt`:

- `build-essential`;
- the AppImage's non-bundled ELF dependencies (`libx11-6`, `libfontconfig1`,
  `libfreetype6`, `libfribidi0`, `libharfbuzz0b`).

It also checks `docker compose`. Because R2 changes the workflow again, every
target restarts its matched stage at R2. The R samples stay preserved in
their own comparison group.

The comparison group is keyed by the full measured commit, workflow path, and
profile. The verification oracle is read from the measured commit's
manifest, so reprocessing with a later collector cannot change it.

For each ready target, the stage runs at one immutable SHA:

1. two orchestration probes;
2. two independent full pairs. Each pair is a benchmark-cold run followed by
   a warm run, using a cache epoch unique to that target and pair.

That is six runs per target, with at most four workload jobs active globally.

Full runs are gated on all of the following from the target's probes and
earlier runs:

- exact source and useful work;
- the 4 vCPU / 16 GB Ubuntu 24.04 envelope;
- a local Docker builder;
- job-graph parity.

Failures are retained. A repeated identical failure stops that target.

The cluster already holds Buildkite's
`buildkite-local-builder-greenbar-research-ci-bench` volume. Buildkite
creates it for organizations without remote Docker builders, and it cannot be
disabled. Buildkite cold samples are therefore recorded with cold
qualification `missing` while that volume exists.

## Controller contracts

- **Immutable dispatch ref.** Each measured commit is named by a lightweight
  tag `pilot/<full sha>`. The controllers verify that the tag names exactly
  that commit, then:
  - GitHub-dispatched targets dispatch from the tag, so the workflow
    definition is the measured commit's;
  - Buildkite builds name the commit directly.
  Collector-only pushes to `main` therefore never change what a run or a
  cold/warm pair measures.
- **Request budgets.** A shared lock spaces the requests of every controller
  on the host:
  - Buildkite: 1.3 s between requests, under the 50 requests per user per
    minute limit;
  - GitHub: 0.8 s, under 5,000 per hour.

  Every HTTP attempt passes through the lock, including retries. A read
  succeeds only when curl exits 0 and the status is 2xx. Transport failures,
  429s, and 5xx are retried after Retry-After; transport failures include a
  truncated body or a timeout after a 200 status line. A create with a
  transport failure is reconciled even after a 201 status line. Pollers
  sleep 5 s between polls. The recorded limiter delay runs from before the
  lock wait to its release, so it includes time blocked behind other
  callers.
- **Client delay is separated from provider time.** Each record has:
  - `controller_call_started_at`;
  - `trigger_requested_at`, taken before the limiter wait;
  - `trigger_first_http_send_at`, taken after it.

  Provenance reports `controller_limiter_wait_before_send_ms` and
  `controller_send_to_accept_ms`. The terminal observation records the
  limiter wait and attempts summed over polls, because observation lag
  includes that wait, retry backoff, and API latency on top of the 5 s
  sleep. Records from earlier controllers leave these fields
  `not recorded`.
- **Build creation is never blindly retried.** Only a 429 is retried. After
  any other failure, the controller looks up the build by its
  `CI_BENCH_REQUEST_ID` env instead of posting again. A reconciled build
  records that `trigger_accepted_at` is the lookup time.
- **Three revisions per sample:**
  - the measured source, in `comparison_group`;
  - `controller_revision`, the controller code that started and polled the
    run, captured once at controller start before any request;
  - `collector`.

  A running Bash controller keeps the code it started with, so its records
  carry its own poll interval. Earlier records without
  `controller_revision` say so rather than guessing.
- **Depot CI** runs `.depot/workflows/probe.yml` and `pilot.yml`, which are
  byte-identical copies of the GitHub workflows. `pilot-runner` identifies
  Depot CI by `DEPOT_JOB_URL`, and Depot's GitHub Actions runners by
  `RUNNER_ENVIRONMENT=self-hosted`.

## CircleCI target

- `.circleci/config.yml` runs `bin/ci/pilot-native` on the dated
  `ubuntu-2404:2026.05.1` machine image (not the mutable `current` tag) with `resource_class: large.gen2` (4 vCPU /
  16 GiB). It sets `CI_BENCH_RUNNER=circleci`, and `pilot-runner` identifies
  the target by `CIRCLECI=true`.
- The organization disables deploy keys, so CircleCI's SSH `checkout` step
  has no key. A `pinned-checkout` command fetches the public repository
  anonymously over HTTPS at exactly `expected_sha`, and verifies that the
  pipeline revision (`CIRCLE_SHA1`) and tag `pilot/<sha>` name that commit.
- Workflows run only when an API trigger sets `expected_sha`. A push, or a
  pipeline without parameters, resolves to no workflows.
- `restore_cache` and `save_cache` hold the logical cache entry
  (`vendor/bundle`, `tmp/ci-bench-cache`) under the epoch and profile key.
  `docker_layer_caching` stays off.
- R6 added the config. R7 pins the dated image and drops an unsupported
  `when` key on `store_artifacts`. R8 replaces the SSH checkout with the
  pinned HTTPS checkout. CircleCI samples are measured at R8 and
  form their own comparison group over the same useful work. Other targets
  are not rerun because of the CircleCI config.

## Buildkite native YAML target

The `buildkite-native` target runs the same useful work without GHAC:

- `.buildkite/native-probe.yml` and `.buildkite/native-pilot.yml` each have
  one step on `linux-medium`, using the same pinned Ubuntu 24.04 agent image
  that GHAC selects for `ubuntu-24.04`.
- `bin/ci/pilot-native` mirrors `probe.yml` and `pilot.yml` step for step:
  - the same `ruby-builder` Ruby 3.4.10 archive that `setup-ruby` installs;
  - Bundler 4.0.9 and Node 24.18.0;
  - the same system packages, ImageMagick AppImage, and services;
  - the same `bin/bench` commands and phase marks.
  It uses `sudo` only when the job is not running as root.
- `bin/ci/pilot-buildkite run native-probe.yml|native-pilot.yml ...` creates
  builds. The importer uploads the native file instead of translating a
  workflow.
- Caching uses a hosted cache volume named
  `ci-bench-pilot-<epoch>-<profile>`, holding `vendor/bundle` and
  `tmp/ci-bench-cache`. This is the Buildkite-native equivalent of the
  logical `actions/cache` entry. A sentinel written only after a successful
  run proves hits and misses.
- Graph parity compares the native file's step keys with the provider's
  workload jobs.

Native samples form their own comparison group, keyed by the
`.buildkite/<file>` path. They are compared with GHAC and GitHub samples only
as a different orchestration definition over the same measured commit and
useful work.

## Buildkite blocker (resolved 2026-10-20)

Resolved on 2026-10-20. Onboarding set up the following:

- org `greenbardev`, using its Default cluster, which is dedicated to this
  pilot;
- queue `linux-medium`, of shape `LINUX_AMD64_4X16`;
- pipeline `ci-bench`, with GitHub triggers off;
- a Buildkite GitHub App installation limited to this repository;
- an org-scoped API token, delivered as the private Amp project secret
  `BUILDKITE_API_TOKEN`.

The original blocker follows.

Before that, this checkout and its environment had none of the
following:

- Buildkite organization
- Buildkite API credential
- Buildkite source integration
- Buildkite queue
- Buildkite environment variables, CLI configuration, or repository secrets

The repository's only check suites come from `github-actions`. The
Buildkite side therefore needs:

1. a Greenbar Buildkite organization and cluster;
2. a full-access GitHub repository provider limited to
   `greenbar-research/ci-bench`;
3. a hosted Linux AMD64 4 vCPU / 16 GB Ubuntu 24.04 queue, keyed
   `linux-medium`;
4. a `ci-bench` pipeline that uploads `.buildkite/pipeline.yml`, with webhook
   builds disabled;
5. an API credential handled outside this repository.

Provider onboarding is handled separately and is not part of this slice.
