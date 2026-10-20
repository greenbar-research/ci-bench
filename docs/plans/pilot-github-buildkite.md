---
status: active
last_reviewed: 2026-10-20
---

# Unscored GitHub native vs Buildkite GHAC pilot

## Purpose

This slice prepares a small, unscored comparison between the same GitHub
Actions workflow on GitHub-hosted runners and on Buildkite through GitHub
Actions compatibility (GHAC). The GitHub side runs now. The Buildkite side
stays blocked until a Greenbar Buildkite organization exists (see
[Buildkite blocker](#buildkite-blocker)).

The pilot does not rank providers, report p95 latency, or publish results.
It produces raw, private evidence that shows whether the contract and
instrumentation are sound before larger runs.

## Contract

- **Source:** one immutable pushed revision of `greenbar-research/ci-bench`.
  `.github/workflows/pilot.yml` dispatches from `main`, and the dispatch
  requires `expected_sha`. A job that checks out any other commit fails and
  is recorded as an invalid sample.
- **Workloads:** the existing `bin/bench` profiles, unchanged:
  - `smoke` is the short, deterministic overhead workload, with pinned
    digest `4addb8bd…`.
  - `full` is the existing full serial Rails workload, with pinned digest
    `3bdfcd70…`.
  - Useful work and verification digests come from `benchmark/manifest.yml`
    and must be identical on every target.
- **Shape:** one serial job per dispatch, and at most one active workload job,
  which stays well below the limit of four. Concurrency group
  `ci-bench-pilot` serializes dispatches.
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
- Computes `comparative_sample_valid` and lists `invalid_reasons`, covering:
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
| GHAC plugin | `github-actions#98159d5e696d06b70df490b9d7d9eabc32bc2b21` (v0.13.0) | Plugin code |
| GHAC runtime | `buildkite-gha` `0.105.1` (Linux x86-64 archive SHA-256 `a87844dd…13e2`) | Runtime, pinned separately via `version` |
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
  GitHub's. `pilot-runner` records the actual facts.
- A `workflow_dispatch` build needs an explicit event snapshot or
  authoritative event metadata. Server-side dispatch does not handle
  `workflow_dispatch`, so builds use the explicit-workflow pipeline in
  `.buildkite/pipeline.yml` and are created by the REST API with inputs.
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

## Buildkite blocker

As of 2026-10-20, this checkout and its environment have none of the
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
