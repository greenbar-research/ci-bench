require "test_helper"
require "json"
require "json_schemer"
require "yaml"
require Rails.root.join("benchmark/harness/bench")

class BenchmarkContractTest < ActiveSupport::TestCase
  MANIFEST_PATH = Rails.root.join("benchmark/manifest.yml")
  SCHEMA_PATH = Rails.root.join("benchmark/schema/result-v1.json")

  test "manifest pins the validation and smoke profiles with the toolchain" do
    manifest = YAML.safe_load_file(MANIFEST_PATH)

    assert_equal "ci-bench-v1", manifest.fetch("benchmark_version")
    assert_equal %w[database file-io browser],
      manifest.dig("profiles", "smoke", "workloads").map { |workload| workload.fetch("name") }
    assert_equal %w[rails-postgres disk-active-storage memory-import],
      manifest.dig("profiles", "validation", "workloads").map { |workload| workload.fetch("name") }
    validation = manifest.dig("profiles", "validation")
    assert_match(/\A[0-9a-f]{64}\z/, validation.fetch("expected_verification_digest"))
    validation.fetch("workloads").each do |workload|
      assert_match(/\A[0-9a-f]{64}\z/, workload.fetch("expected_verification_digest"))
    end
    rails_postgres = validation.fetch("workloads").find { |workload| workload.fetch("name") == "rails-postgres" }
    assert_operator rails_postgres.dig("parameters", "insert_batch_size"), :>, 0
    assert_operator ActiveRecord::Base.connection_pool.size,
      :>=,
      rails_postgres.dig("parameters", "concurrency_threads") + 1
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
      "partial" => false,
      "scored" => false,
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

  test "CPU time parsing is portable across ps formats" do
    sampler = CiBench::Sampler.new("cpu-test")

    assert_in_delta 12.34, sampler.send(:parse_cpu_time, "0:12.34")
    assert_in_delta 3_723, sampler.send(:parse_cpu_time, "01:02:03")
    assert_in_delta 93_784.5, sampler.send(:parse_cpu_time, "1-02:03:04.5")
  end

  test "mismatched expected verification is invalid" do
    manifest = YAML.safe_load_file(MANIFEST_PATH)
    manifest["profiles"]["smoke"]["expected_verification_digest"] = "0" * 64
    runner = CiBench::Runner.new(manifest, "smoke", Rails.root.join("tmp/result.json"))
    runner.instance_variable_set(:@outputs, { "database" => { "count" => 1 } })

    assert_raises(CiBench::InvalidResult) { runner.send(:verify_expected_digest!) }
  end

  test "verification digests are canonical and reject floats" do
    manifest = YAML.safe_load_file(MANIFEST_PATH)
    runner = CiBench::Runner.new(manifest, "smoke", Rails.root.join("tmp/result.json"))

    first = runner.send(:verification_digest, { "b" => 2, "a" => { "d" => 4, "c" => 3 } })
    second = runner.send(:verification_digest, { "a" => { "c" => 3, "d" => 4 }, "b" => 2 })

    assert_equal first, second
    assert_raises(CiBench::InvalidResult) do
      runner.send(:verification_digest, { "duration" => 1.5 })
    end
  end

  test "fixture generator matches the checked-in checksum manifest" do
    manifest = CiBench::Fixtures.verify_manifest!(
      Rails.root.join("benchmark/fixtures/checksums.json")
    )

    benchmark_manifest = YAML.safe_load_file(MANIFEST_PATH)

    assert_equal benchmark_manifest.fetch("seed"), manifest.fetch("seed")
    assert_equal %w[binary-1mib text-1mib],
      manifest.fetch("fixtures").map { |fixture| fixture.fetch("name") }
  end

  test "resource limits reject a workload that exceeds its declared peak" do
    manifest = YAML.safe_load_file(MANIFEST_PATH)
    runner = CiBench::Runner.new(manifest, "smoke", Rails.root.join("tmp/result.json"))
    workload = manifest.dig("profiles", "smoke", "workloads").first

    error = assert_raises(CiBench::InvalidResult) do
      runner.send(
        :validate_limits!,
        workload,
        [],
        { "peak_rss_bytes" => workload.dig("limits", "peak_rss_bytes") + 1 }
      )
    end

    assert_includes error.message, "peak RSS"
  end
end
