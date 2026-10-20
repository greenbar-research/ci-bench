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

  private

  def provenance(run: {}, job: {}, runner: {})
    digest = YAML.safe_load_file(File.join(ROOT, "benchmark/manifest.yml")).dig("profiles", "smoke", "expected_verification_digest")
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "artifact"))
      write_json(dir, "controller.json", { "inputs" => { "profile" => "smoke", "expected_sha" => SHA } })
      write_json(dir, "run.json", { "status" => "completed", "conclusion" => "success", "head_sha" => SHA, "run_attempt" => 1 }.merge(run))
      write_json(dir, "jobs.json", { "jobs" => [{ "conclusion" => "success" }.merge(job)] })
      write_json(dir, "artifact/result.json",
        { "status" => "passed", "git_dirty" => false, "verification" => { "digest" => digest }, "workloads" => [] })
      runner_env = { "envelope_match" => "true", "checkout_sha" => SHA,
                     "docker_endpoint" => "unix:///var/run/docker.sock", "docker_builder" => "docker" }.merge(runner)
      File.write(File.join(dir, "artifact/runner.env"), runner_env.map { |k, v| "#{k}=#{v}\n" }.join)
      File.write(File.join(dir, "artifact/cache.env"), "cache_expectation=met\n")
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
