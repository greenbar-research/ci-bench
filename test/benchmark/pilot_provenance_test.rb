require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "yaml"

# Runs bin/ci/pilot-provenance against synthetic evidence; needs no database.
class PilotProvenanceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SHA = "a" * 40

  def test_valid_sample_requires_provider_success_and_local_builder
    assert_equal [], provenance.fetch("invalid_reasons")

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

    wrong = provenance(probe: { "marker.txt" => "#{"b" * 40}\n", "source.txt" => "#{SHA}\n" }, observation: observation)
    assert_equal ["completion marker missing or not the expected SHA"], wrong.fetch("invalid_reasons")
  end

  private

  def provenance(run: {}, job: {}, runner: {}, probe: nil, observation: nil)
    digest = YAML.safe_load_file(File.join(ROOT, "benchmark/manifest.yml")).dig("profiles", "smoke", "expected_verification_digest")
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "artifact"))
      controller = { "trigger_requested_at" => "2026-10-20T00:00:01.500Z", "trigger_accepted_at" => "2026-10-20T00:00:02.000Z",
                     "inputs" => { "profile" => "smoke", "expected_sha" => SHA } }
      controller = controller.merge("profile" => "probe", "inputs" => { "expected_sha" => SHA }, "terminal_observation" => observation) if probe
      write_json(dir, "controller.json", controller)
      write_json(dir, "run.json", { "status" => "completed", "conclusion" => "success", "head_sha" => SHA, "run_attempt" => 1 }.merge(run))
      write_json(dir, "jobs.json", { "jobs" => [{ "conclusion" => "success" }.merge(job)] })
      if probe
        probe.each { |name, content| File.write(File.join(dir, "artifact", name), content) }
      else
        write_json(dir, "artifact/result.json",
          { "status" => "passed", "git_dirty" => false, "verification" => { "digest" => digest }, "workloads" => [] })
        File.write(File.join(dir, "artifact/cache.env"), "cache_expectation=met\n")
      end
      runner_env = { "envelope_match" => "true", "checkout_sha" => SHA,
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
