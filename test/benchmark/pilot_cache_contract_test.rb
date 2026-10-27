require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

# Runs pilot.yml's own cache steps (record sentinel, check expectation) in a
# scratch checkout with a fake HOME, so the warm hit is proven by the sentinel
# key and content digest and never by the provider's cache-hit output, which
# CircleCI's GitHub Actions runtime always reports as false. Needs no database.
class PilotCacheContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  STEPS = YAML.safe_load(File.read(File.join(ROOT, ".github/workflows/pilot.yml"))).dig("jobs", "pilot", "steps")
  KEY = "ci-bench-pilot-e1-smoke-ubuntu-24.04-Linux-abc"

  def test_cold_run_with_no_entry_meets_and_records_a_miss
    in_checkout do |dir|
      out, ok = check(dir, phase: "cold", provider_hit: "false")
      assert ok, out
      assert_includes cache_env(dir), "cache_hit=false"
      assert_includes cache_env(dir), "cache_expectation=met"
    end
  end

  def test_warm_hit_is_proven_by_sentinel_even_when_provider_reports_false
    in_checkout do |dir|
      record(dir)
      out, ok = check(dir, phase: "warm", provider_hit: "false")
      assert ok, out
      env = cache_env(dir)
      assert_includes env, "cache_hit=true"
      assert_includes env, "cache_digest=match"
      assert_includes env, "provider_cache_hit_output=false"
      assert_includes env, "cache_restore_evidence=sentinel_key_and_content_digest"
    end
  end

  def test_warm_without_restored_entry_is_violated
    in_checkout do |dir|
      out, ok = check(dir, phase: "warm", provider_hit: "false")
      refute ok, out
      assert_includes cache_env(dir), "cache_expectation=violated: warm run missed the cache"
    end
  end

  def test_restored_content_that_differs_from_the_saved_digest_is_violated
    in_checkout do |dir|
      record(dir)
      File.write(File.join(dir, "home/.npm/index"), "changed after save")
      out, ok = check(dir, phase: "warm", provider_hit: "false")
      refute ok, out
      assert_includes cache_env(dir), "cache_digest=mismatch"
    end
  end

  def test_sentinel_for_another_key_is_violated
    in_checkout do |dir|
      record(dir, key: "#{KEY}-other")
      _, ok = check(dir, phase: "warm", provider_hit: "false")
      refute ok
      assert_includes cache_env(dir), "cache_digest=mismatch"
    end
  end

  def test_cold_run_that_restores_an_entry_is_violated
    in_checkout do |dir|
      record(dir)
      _, ok = check(dir, phase: "cold", provider_hit: "false")
      refute ok
      assert_includes cache_env(dir), "cache_expectation=violated: cold run restored an existing entry"
    end
  end

  def test_provider_hit_without_sentinel_is_violated
    in_checkout do |dir|
      _, ok = check(dir, phase: "warm", provider_hit: "true")
      refute ok
      assert_includes cache_env(dir), "cache_expectation=violated: provider reported a hit without the sentinel"
    end
  end

  private

  def in_checkout
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(%w[bin/ci tmp/pilot vendor/bundle/gems home/.npm home/.cache/ms-playwright].map { |d| File.join(dir, d) })
      FileUtils.cp(File.join(ROOT, "bin/ci/pilot-cache-digest"), File.join(dir, "bin/ci/"))
      File.write(File.join(dir, "bin/ci/pilot-mark"), "#!/bin/sh\n")
      File.chmod(0o755, File.join(dir, "bin/ci/pilot-mark"))
      File.write(File.join(dir, "vendor/bundle/gems/rails"), "gem")
      File.write(File.join(dir, "home/.npm/index"), "npm")
      File.write(File.join(dir, "home/.cache/ms-playwright/chromium"), "browser")
      yield dir
    end
  end

  def step(name)
    STEPS.find { |s| s["name"] == name }.fetch("run")
  end

  def run_step(dir, name, env)
    Open3.capture2e(env.merge("HOME" => File.join(dir, "home")), "bash", "-e", "-c", step(name), chdir: dir)
  end

  def record(dir, key: KEY)
    out, status = run_step(dir, "Record benchmark-cache sentinel", "CACHE_KEY" => key)
    assert status.success?, out
  end

  def check(dir, phase:, provider_hit:)
    out, status = run_step(dir, "Check cache expectation",
                           "CACHE_KEY" => KEY, "PROVIDER_CACHE_HIT" => provider_hit, "CI_BENCH_CACHE_PHASE" => phase)
    [out, status.success?]
  end

  def cache_env(dir)
    File.read(File.join(dir, "tmp/pilot/cache.env"))
  end
end
