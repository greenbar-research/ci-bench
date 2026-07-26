# ci-bench

`ci-bench` is a proposed open-source benchmark for measuring end-to-end CI
performance with a realistic Rails application.

The first version will use GitHub as the only source-code host and compare:

- GitHub Actions on standard GitHub-hosted runners
- Buildkite Pipelines on Buildkite Hosted Agents

The benchmark will cover cold and warm execution, serial and parallel test
profiles, and controlled code, dependency, and Docker-layer churn. Cost is not
part of the comparison.

See [the implementation plan](docs/plans/initial-implementation.md).
