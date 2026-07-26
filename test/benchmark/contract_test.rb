require "test_helper"
require "json"
require "json_schemer"
require "yaml"
require Rails.root.join("benchmark/harness/bench")

class BenchmarkContractTest < ActiveSupport::TestCase
  MANIFEST_PATH = Rails.root.join("benchmark/manifest.yml")
  SCHEMA_PATH = Rails.root.join("benchmark/schema/result-v1.json")

  test "manifest pins the smoke profile and toolchain" do
    manifest = YAML.safe_load_file(MANIFEST_PATH)

    assert_equal "ci-bench-v1", manifest.fetch("benchmark_version")
    assert_equal %w[database file-io browser],
      manifest.dig("profiles", "smoke", "workloads").map { |workload| workload.fetch("name") }
    assert_equal RUBY_VERSION, manifest.dig("toolchain", "ruby")
    assert_match(/\A[0-9a-f]{64}\z/, manifest.dig("profiles", "smoke", "expected_verification_digest"))
  end

  test "result schema rejects incomplete attempts" do
    schema = JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH)))

    errors = schema.validate({ "schema_version" => 1 }).to_a

    assert errors.any? { |error| error.fetch("type") == "required" }
  end

  test "result schema rejects passed attempts without workloads" do
    schema = JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH)))
    result = {
      "schema_version" => 1,
      "benchmark_version" => "ci-bench-v1",
      "run_id" => "de305d54-75b4-431b-adb2-eb6b9e546014",
      "commit_sha" => "0" * 40,
      "git_dirty" => false,
      "target" => "local",
      "profile" => "smoke",
      "scenario" => "baseline",
      "status" => "passed",
      "runner" => nil,
      "timeline" => {
        "started_at" => "2026-07-26T00:00:00Z",
        "completed_at" => "2026-07-26T00:00:01Z",
        "duration_ms" => 1_000
      },
      "workloads" => [],
      "caches" => [],
      "resources" => { "samples" => [] },
      "verification" => { "digest" => "0" * 64, "outputs" => {} }
    }

    errors = schema.validate(result).to_a

    assert errors.any? { |error| error.fetch("type") == "minItems" }

    result["status"] = "failed"
    result["error"] = "doctor failed"

    assert_empty schema.validate(result).to_a
  end

  test "resource observation cannot fail a workload" do
    sampler = CiBench::Sampler.new("observer-test")
    sampler.define_singleton_method(:sample) { |*| raise CiBench::Error, "observer failed" }

    _stdout, stderr = capture_io do
      assert_operator sampler.run(
        ["ruby", "-e", "sleep 0.05"],
        env: {},
        timeout_seconds: 1
      ), :>=, 0
    end

    assert_includes stderr, "resource sampling failed"
  end

  test "mismatched expected verification is invalid" do
    manifest = YAML.safe_load_file(MANIFEST_PATH)
    manifest["profiles"]["smoke"]["expected_verification_digest"] = "0" * 64
    runner = CiBench::Runner.new(manifest, "smoke", Rails.root.join("tmp/result.json"))
    runner.instance_variable_set(:@outputs, { "database" => { "count" => 1 } })

    assert_raises(CiBench::InvalidResult) { runner.send(:verify_expected_digest!) }
  end
end
