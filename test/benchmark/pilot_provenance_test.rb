require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "yaml"

# Runs bin/ci/pilot-provenance against synthetic evidence; needs no database.
# The expected SHA is this checkout's HEAD so workflow files resolve through git.
class PilotProvenanceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SHA = `git -C #{ROOT} rev-parse HEAD`.strip

  def test_valid_sample_requires_provider_success_and_local_builder
    valid = provenance
    assert_equal [], valid.fetch("invalid_reasons")
    measured = YAML.safe_load(`git -C #{ROOT} show #{SHA}:benchmark/manifest.yml`).dig("profiles", "smoke", "expected_verification_digest")
    assert_equal measured, valid.dig("comparison_group", "expected_verification_digest")
    assert_equal "#{SHA}:.github/workflows/pilot.yml:smoke", valid.dig("comparison_group", "key")

    wrong_digest = provenance(digest: "0" * 64)
    assert_includes wrong_digest.fetch("invalid_reasons"), "verification digest mismatch"

    failed = provenance(run: { "conclusion" => "failure" }, job: { "conclusion" => "failure" })
    assert_equal false, failed.fetch("comparative_sample_valid")
    assert_equal "passed", failed.dig("result", "status")
    assert_includes failed.fetch("invalid_reasons"), 'provider run conclusion "failure" is not success'
    assert_includes failed.fetch("invalid_reasons"), 'provider job conclusion "failure" is not success'

    remote = provenance(runner: { "docker_endpoint" => "tcp://builder:2376" })
    assert_equal false, remote.fetch("comparative_sample_valid")
    assert_equal false, remote.fetch("docker_builder_local")
    assert_equal 1, remote.fetch("invalid_reasons").grep(/Docker builder is not verified local/).size
  end

  def test_probe_requires_marker_and_separates_clock_classes
    observation = { "observed_at" => "2026-10-20T00:01:05.000Z", "last_nonterminal_response_at" => "2026-10-20T00:01:03.000Z" }
    valid = provenance(probe: { "marker.txt" => "#{SHA}\n", "source.txt" => "#{SHA}\n" }, observation: observation)
    assert_equal [], valid.fetch("invalid_reasons")
    assert_equal 63_500, valid.dig("timeline", "controller_request_to_terminal_observed_ms")
    assert_includes valid.dig("timeline", "interval_clock_classes", "cross_clock_estimate"), "controller_accept_to_job_completed_ms"

    sent = provenance(probe: { "marker.txt" => "#{SHA}\n", "source.txt" => "#{SHA}\n" }, observation: observation,
                      controller_extra: { "trigger_first_http_send_at" => "2026-10-20T00:00:01.800Z" })
    assert_equal 300, sent.dig("timeline", "controller_limiter_wait_before_send_ms")
    assert_equal 200, sent.dig("timeline", "controller_send_to_accept_ms")
    assert_equal "not recorded", valid.dig("timeline", "controller_limiter_wait_before_send_ms")

    wrong = provenance(probe: { "marker.txt" => "#{"b" * 40}\n", "source.txt" => "#{SHA}\n" }, observation: observation)
    assert_equal ["completion marker missing or not the expected SHA"], wrong.fetch("invalid_reasons")
  end

  def test_buildkite_build_requires_graph_parity_no_retries_and_recorded_cold_volumes
    valid = provenance(buildkite: {}, volumes: [{ "tag" => "01a15893-52af-4f15-98e9-7e88099b5337/buildkite-gha-linux-amd64" }])
    assert_equal [], valid.fetch("invalid_reasons")
    assert_equal "buildkite-ghac", valid.fetch("target")
    assert_equal 12_000, valid.dig("timeline", "provider_job_ms")
    assert_match(/\ABuildkite /, valid.dig("timeline", "clock_note").split("provider times use ").last)
    assert_equal "2026-10-20T00:00:21Z", valid.dig("timeline", "provider_terminal_boundary", "build_finished_at")
    assert_equal "unknown: not recorded at controller start", valid.fetch("controller_revision")
    assert_match(/Buildkite-clock workload job finished_at/, valid.dig("timeline", "controller_accept_to_job_completed_note"))
    refute_match(/GitHub/, valid.dig("timeline", "controller_accept_to_job_completed_note"))
    assert_match(/\Abenchmark-cold: .*GHAC toolchain volume present/, valid.fetch("cold_qualification"))

    extra = provenance(buildkite: { "extra_jobs" => [{ "step_key" => "gha-other", "state" => "passed" }] }, volumes: [])
    assert_equal 1, extra.fetch("invalid_reasons").grep(/job graph parity failed/).size

    retried = provenance(buildkite: { "retried" => true }, volumes: [])
    assert_includes retried.fetch("invalid_reasons"), "run attempt is not 1 or a job was retried"

    cached = provenance(buildkite: {}, volumes: [{ "tag" => "ci-bench/container-cache" }])
    assert_equal [], cached.fetch("invalid_reasons")
    assert_equal "missing: cache volumes present before the build: ci-bench/container-cache", cached.fetch("cold_qualification")
  end

  def test_buildkite_native_uses_pipeline_steps_for_graph_parity
    valid = provenance(buildkite: { "native" => true }, volumes: [{ "tag" => "buildkite-local-builder-greenbar-research-ci-bench" }])
    assert_equal [], valid.fetch("invalid_reasons")
    assert_equal "buildkite-native", valid.fetch("target")
    assert_equal ".buildkite/native-pilot.yml", valid.dig("comparison_group", "workflow_path")
    assert_equal ["native-pilot"], valid.dig("graph", "workflow_logical_jobs")
    assert_match(/\Amissing: cache volumes present before the build: buildkite-local-builder/, valid.fetch("cold_qualification"))

    ghac_step = provenance(buildkite: { "native" => true, "workload_key" => "gha-pilot" }, volumes: [])
    assert_equal 1, ghac_step.fetch("invalid_reasons").grep(/job graph parity failed/).size
  end

  def test_runner_providers_and_circleci_qualify_cold_without_cluster_volumes
    depot = provenance(runner: { "target" => "depot" }, controller_extra: { "target" => "depot" })
    assert_equal [], depot.fetch("invalid_reasons")
    assert_match(/\Abenchmark-cold: exact dependency-cache miss verified/, depot.fetch("cold_qualification"))
    assert_includes depot.dig("cache", "provider_owned_unknowns"), "Depot Registry pull auth"

    circle = provenance(circle: {})
    assert_equal [], circle.fetch("invalid_reasons")
    assert_equal ".circleci/config.yml", circle.dig("comparison_group", "workflow_path")
    assert_equal ["pilot"], circle.dig("graph", "workflow_logical_jobs")
    assert_equal 30_000, circle.dig("timeline", "provider_job_ms")
    assert_match(/CircleCI API v2/, circle.dig("timeline", "clock_note"))

    rerun = provenance(circle: { "extra_job" => true })
    assert_includes rerun.fetch("invalid_reasons"), "run attempt is not 1 or a job was retried"
  end

  private

  def provenance(run: {}, job: {}, runner: {}, probe: nil, observation: nil, buildkite: nil, volumes: nil, digest: nil, controller_extra: {}, circle: nil)
    digest ||= YAML.safe_load(`git -C #{ROOT} show #{SHA}:benchmark/manifest.yml`).dig("profiles", "smoke", "expected_verification_digest")
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "artifact"))
      controller = { "trigger_requested_at" => "2026-10-20T00:00:01.500Z", "trigger_accepted_at" => "2026-10-20T00:00:02.000Z",
                     "inputs" => { "profile" => "smoke", "cache_phase" => "cold", "expected_sha" => SHA } }
      controller = controller.merge("profile" => "probe", "inputs" => { "expected_sha" => SHA }, "terminal_observation" => observation) if probe
      target = buildkite&.fetch("native", false) ? "buildkite-native" : "buildkite-ghac"
      controller = controller.merge("target" => target, "provider_cache_volumes_before" => volumes) if buildkite
      controller = controller.merge("target" => "circleci") if circle
      controller = controller.merge("workflow" => "native-pilot.yml") if buildkite&.fetch("native", false)
      write_json(dir, "controller.json", controller.merge(controller_extra))
      if buildkite
        workload_key = buildkite["workload_key"] || (buildkite["native"] ? "native-pilot" : "gha-pilot")
        workload = { "step_key" => workload_key, "state" => "passed", "retried" => buildkite["retried"] || false,
                     "runnable_at" => "2026-10-20T00:00:05Z", "started_at" => "2026-10-20T00:00:08Z", "finished_at" => "2026-10-20T00:00:20Z" }
        write_json(dir, "build.json", { "number" => 1, "state" => "passed", "commit" => SHA, "created_at" => "2026-10-20T00:00:02Z",
                                        "started_at" => "2026-10-20T00:00:03Z", "finished_at" => "2026-10-20T00:00:21Z",
                                        "jobs" => [{ "step_key" => "gha-importer", "state" => "passed" }, workload] + (buildkite["extra_jobs"] || []) })
      elsif circle
        job = { "name" => "pilot", "status" => "success", "number" => 7, "queued_at" => "2026-10-20T00:00:04Z",
                "started_at" => "2026-10-20T00:00:05Z", "stopped_at" => "2026-10-20T00:00:35Z",
                "executor" => { "type" => "machine", "resource_class" => "large.gen2" } }
        write_json(dir, "circleci.json", { "pipeline" => { "number" => 3, "created_at" => "2026-10-20T00:00:02Z", "vcs" => { "revision" => SHA } },
                                           "workflow" => { "status" => "success", "created_at" => "2026-10-20T00:00:03Z", "stopped_at" => "2026-10-20T00:00:36Z" },
                                           "jobs" => [job] + (circle["extra_job"] ? [job.merge("number" => 8)] : []) })
      else
        write_json(dir, "run.json", { "status" => "completed", "conclusion" => "success", "head_sha" => SHA, "run_attempt" => 1 }.merge(run))
        write_json(dir, "jobs.json", { "jobs" => [{ "conclusion" => "success" }.merge(job)] })
      end
      if probe
        probe.each { |name, content| File.write(File.join(dir, "artifact", name), content) }
      else
        write_json(dir, "artifact/result.json",
          { "status" => "passed", "git_dirty" => false, "verification" => { "digest" => digest }, "workloads" => [] })
        File.write(File.join(dir, "artifact/cache.env"), "cache_expectation=met\n")
      end
      runner_env = { "target" => buildkite ? target : (circle ? "circleci" : "github-actions"), "envelope_match" => "true", "checkout_sha" => SHA,
                     "docker_endpoint" => "unix:///var/run/docker.sock", "docker_builder" => "docker" }.merge(runner)
      File.write(File.join(dir, "artifact/runner.env"), runner_env.map { |k, v| "#{k}=#{v}\n" }.join)
      File.write(File.join(dir, "artifact-checksums.txt"), "verified\n")

      out, status = Open3.capture2(RbConfig.ruby, File.join(ROOT, "bin/ci/pilot-provenance"), dir, "2026-10-20T00:00:00Z")
      assert status.success?
      JSON.parse(out)
    end
  end

  def write_json(dir, name, value)
    File.write(File.join(dir, name), JSON.generate(value))
  end
end
