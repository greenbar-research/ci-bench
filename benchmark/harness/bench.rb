require "digest"
require "etc"
require "fileutils"
require "json"
require "json_schemer"
require "open3"
require "optparse"
require "rbconfig"
require "securerandom"
require "time"
require "yaml"
require_relative "../fixtures/generator"

module CiBench
  ROOT = File.expand_path("../..", __dir__)
  MANIFEST_PATH = File.join(ROOT, "benchmark/manifest.yml")
  SCHEMA_PATH = File.join(ROOT, "benchmark/schema/result-v1.json")

  class Error < StandardError; end
  class InvalidResult < Error; end
  class SchemaError < InvalidResult; end

  module Command
    module_function

    def capture!(*command, env: {})
      stdout, stderr, status = Open3.capture3(env, *command, chdir: ROOT)
      return stdout.strip if status.success?

      message = ([command.join(" "), stdout, stderr].reject(&:empty?)).join("\n")
      raise Error, message
    end

  end

  class Host
    class << self
      def metadata
        {
          "architecture" => RbConfig::CONFIG.fetch("host_cpu"),
          "cpu_count" => Etc.nprocessors,
          "disk_available_bytes" => disk_available_bytes,
          "memory_bytes" => memory_bytes,
          "os" => RbConfig::CONFIG.fetch("host_os"),
          "ruby_version" => RUBY_VERSION,
          "node_version" => Command.capture!("node", "--version").delete_prefix("v")
        }
      end

      def disk_available_bytes
        line = Command.capture!("df", "-Pk", ROOT).lines.last
        line.split.fetch(3).to_i * 1_024
      end

      def memory_bytes
        if File.exist?("/proc/meminfo")
          File.read("/proc/meminfo")[/^MemTotal:\s+(\d+)/, 1].to_i * 1_024
        else
          Command.capture!("sysctl", "-n", "hw.memsize").to_i
        end
      end
    end
  end

  class Doctor
    def initialize(manifest, profile)
      @manifest = manifest
      @profile = profile
    end

    def check!
      runner = Host.metadata
      minimum = @manifest.fetch("profiles").fetch(@profile).fetch("minimum_runner")
      tools = @manifest.fetch("toolchain")
      checks = [
        check("Ruby #{tools.fetch("ruby")}", RUBY_VERSION == tools.fetch("ruby"), RUBY_VERSION),
        command_version_check("Rails", tools.fetch("rails"), "bin/rails", "--version"),
        check("Node #{tools.fetch("node")}", runner.fetch("node_version") == tools.fetch("node"), runner.fetch("node_version")),
        command_version_check(
          "Playwright",
          tools.fetch("playwright"),
          "node",
          "-p",
          "require('@playwright/test/package.json').version"
        ),
        command_check("Bundler", "bundle", "--version"),
        command_check("Git", "git", "--version"),
        command_check("npm", "npm", "--version"),
        command_check("curl", "curl", "--version"),
        command_check("Docker daemon", "docker", "info"),
        command_check("Docker Compose", "docker", "compose", "config", "--quiet"),
        command_check(
          "Playwright Chromium",
          "node",
          "-e",
          "(async()=>{const{chromium}=require('@playwright/test');const b=await chromium.launch();await b.close()})().catch(e=>{console.error(e.message);process.exit(1)})"
        ),
        check("CPU", runner.fetch("cpu_count") >= minimum.fetch("cpu_count"), "#{runner.fetch("cpu_count")} cores"),
        check("memory", runner.fetch("memory_bytes") >= minimum.fetch("memory_bytes"), format_bytes(runner.fetch("memory_bytes"))),
        check(
          "available disk",
          runner.fetch("disk_available_bytes") >= minimum.fetch("disk_available_bytes"),
          format_bytes(runner.fetch("disk_available_bytes"))
        )
      ]

      checks.each do |item|
        marker = item.fetch(:ok) ? "ok" : "FAIL"
        puts format("%-4s %-24s %s", marker, item.fetch(:label), item.fetch(:detail))
      end

      failures = checks.reject { |item| item.fetch(:ok) }
      raise Error, "doctor found #{failures.length} failing check(s)" unless failures.empty?

      runner
    end

    private

    def command_check(label, *command)
      stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
      detail = (stdout.lines.first || stderr.lines.first || command.join(" ")).strip
      check(label, status.success?, detail)
    rescue Errno::ENOENT => error
      check(label, false, error.message)
    end

    def command_version_check(label, expected, *command)
      stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
      actual = (stdout.lines.first || stderr.lines.first || "").strip[/\d+\.\d+\.\d+(?:\.\d+)?/]
      check("#{label} #{expected}", status.success? && actual == expected, actual || "unavailable")
    rescue Errno::ENOENT => error
      check("#{label} #{expected}", false, error.message)
    end

    def check(label, ok, detail)
      { label: label, ok: ok, detail: detail }
    end

    def format_bytes(bytes)
      format("%.1f GiB", bytes.fdiv(1024**3))
    end
  end

  class Sampler
    SAMPLE_INTERVAL = 0.25
    DISK_SAMPLE_INTERVAL = 2.0

    def initialize(workload)
      @workload = workload
      @samples = []
      @cpu_seconds = {}
      @sampled_at = nil
      @disk_sampled_at = nil
      @disk_used_bytes = 0
      @disk_available_bytes = 0
    end

    attr_reader :samples

    def run(command, env:, timeout_seconds:)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout = +""
      stderr = +""

      Open3.popen3(env, *command, chdir: ROOT, pgroup: true) do |stdin, out, err, wait|
        stdin.close
        stdout_reader = Thread.new { stdout << out.read }
        stderr_reader = Thread.new { stderr << err.read }

        loop do
          observe(wait.pid, started)
          break if wait.join(SAMPLE_INTERVAL)
          next unless elapsed_ms(started) >= timeout_seconds * 1_000

          terminate(wait.pid, wait)
          raise Error, "#{@workload} timed out after #{timeout_seconds}s"
        end

        stdout_reader.join
        stderr_reader.join
        duration_ms = elapsed_ms(started)
        return duration_ms if wait.value.success?

        raise Error, ([command.join(" "), stdout, stderr].reject(&:empty?)).join("\n")
      end
    end

    private

    def observe(root_pid, started)
      sample(root_pid, started)
    rescue => error
      warn "resource sampling failed for #{@workload}: #{error.message}"
    end

    def terminate(pid, wait)
      Process.kill("TERM", -pid)
      return if wait.join(5)

      Process.kill("KILL", -pid)
      wait.join
    rescue Errno::ESRCH
      wait.join
    end

    def sample(root_pid, started)
      processes = process_table
      pids = [root_pid]

      loop do
        children = processes.filter_map { |pid, values| pid if pids.include?(values.fetch(:ppid)) }
        additions = children - pids
        break if additions.empty?

        pids.concat(additions)
      end

      selected = processes.values_at(*pids).compact
      sampled_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cpu_seconds = pids.to_h { |pid| [pid, processes.dig(pid, :cpu_seconds) || 0.0] }
      cpu_delta = if @sampled_at
        cpu_seconds.sum do |pid, seconds|
          [seconds - @cpu_seconds.fetch(pid, 0.0), 0.0].max
        end
      else
        0.0
      end
      sample_interval = @sampled_at ? sampled_at - @sampled_at : sampled_at - started
      cpu_percent = sample_interval.positive? ? cpu_delta.fdiv(sample_interval) * 100 : 0.0
      refresh_disk(sampled_at) if @disk_sampled_at.nil? || sampled_at - @disk_sampled_at >= DISK_SAMPLE_INTERVAL

      @samples << {
        "elapsed_ms" => elapsed_ms(started),
        "workload" => @workload,
        "cpu_percent" => cpu_percent.round(2),
        "rss_bytes" => selected.sum { |process| process.fetch(:rss_kib) } * 1_024,
        "disk_used_bytes" => @disk_used_bytes,
        "disk_available_bytes" => @disk_available_bytes
      }
      @cpu_seconds = cpu_seconds
      @sampled_at = sampled_at
    end

    def refresh_disk(sampled_at)
      @disk_used_bytes = benchmark_disk_bytes
      @disk_available_bytes = Host.disk_available_bytes
      @disk_sampled_at = sampled_at
    rescue => error
      warn "disk sampling failed for #{@workload}: #{error.message}"
    end

    def process_table
      Command.capture!("ps", "-axo", "pid=,ppid=,rss=,time=").lines.to_h do |line|
        pid, ppid, rss_kib, cpu_time = line.split
        [
          pid.to_i,
          {
            ppid: ppid.to_i,
            rss_kib: rss_kib.to_i,
            cpu_seconds: linux_cpu_seconds(pid.to_i) || parse_cpu_time(cpu_time)
          }
        ]
      end
    end

    def linux_cpu_seconds(pid)
      path = "/proc/#{pid}/stat"
      return unless File.exist?(path)

      stat = File.read(path)
      return unless (offset = stat.rindex(")"))

      fields = stat.byteslice(offset + 2..).split
      (fields.fetch(11).to_i + fields.fetch(12).to_i).fdiv(Etc.sysconf(Etc::SC_CLK_TCK))
    rescue Errno::ENOENT, IndexError
      nil
    end

    def parse_cpu_time(value)
      parts = value.split(":")
      seconds = parts.pop.to_f
      minutes = parts.pop.to_i
      hours_with_days = parts.pop || "0"
      days, hours = hours_with_days.include?("-") ? hours_with_days.split("-").map(&:to_i) : [0, hours_with_days.to_i]
      (days * 86_400) + (hours * 3_600) + (minutes * 60) + seconds
    end

    def benchmark_disk_bytes
      path = File.join(ROOT, "tmp/bench")
      return 0 unless Dir.exist?(path)

      Command.capture!("du", "-sk", path).split.first.to_i * 1_024
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
    end
  end

  class Runner
    def initialize(manifest, profile, output_path, workload_name: nil)
      @manifest = manifest
      @profile = profile
      @output_path = output_path
      @workload_name = workload_name
      @workloads = []
      @samples = []
      @outputs = {}
      @commit_sha = nil
      @git_dirty = nil
    end

    def run!
      started_at = Time.now.utc
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @commit_sha = Command.capture!("git", "rev-parse", "HEAD")
      @git_dirty = !Command.capture!("git", "status", "--porcelain").empty?
      runner = Doctor.new(@manifest, @profile).check!
      prepare

      selected_workloads.each do |workload|
        run_workload(workload)
      end

      verify_expected_digest!
      write_and_validate!(build_result("passed", runner, started_at, started))
      puts "wrote #{@output_path}"
    rescue => error
      message = error.message.empty? ? error.class.name : error.message
      warn message
      begin
        if @commit_sha
          status = error.is_a?(InvalidResult) ? "invalid" : "failed"
          failure = build_result(status, runner, started_at, started)
          failure["error"] = message
          write_and_validate!(failure)
        end
      rescue => recording_error
        warn "could not write failure record: #{recording_error.message}"
      end
      raise
    end

    private

    def prepare
      Command.capture!("bin/ci/services")
      Command.capture!("bin/rails", "db:prepare", env: { "RAILS_ENV" => "test" })
      Command.capture!(
        "bin/rails",
        "runner",
        "benchmark/harness/reset_database.rb",
        env: { "RAILS_ENV" => "test" }
      )
      FileUtils.rm_rf(File.join(ROOT, "tmp/bench"))
      FileUtils.mkdir_p(File.join(ROOT, "tmp/bench"))
    end

    def run_workload(workload)
      name = workload.fetch("name")
      output_path = File.join(ROOT, "tmp/bench/#{name}.json")
      FileUtils.rm_f(output_path)
      sampler = Sampler.new(name)
      duration_ms = sampler.run(
        workload.fetch("command"),
        env: {
          "RAILS_ENV" => "test",
          "BENCH_OUTPUT" => output_path,
          "BENCH_PARAMS" => JSON.generate(workload.fetch("parameters")),
          "BENCH_PROFILE" => @profile,
          "BENCH_SEED" => @manifest.fetch("seed").to_s
        },
        timeout_seconds: workload.fetch("timeout_seconds")
      )
      payload = JSON.parse(File.read(output_path))
      unless payload.keys.sort == %w[telemetry verification] &&
          payload.fetch("verification").is_a?(Hash) &&
          payload.fetch("telemetry").is_a?(Hash)
        raise InvalidResult, "#{name} output must contain only verification and telemetry objects"
      end

      verification = payload.fetch("verification")
      telemetry = payload.fetch("telemetry")
      verify_workload!(workload, verification)
      validate_limits!(workload, sampler.samples, telemetry)
      @outputs[name] = verification
      @samples.concat(sampler.samples)
      @workloads << {
        "name" => name,
        "status" => "passed",
        "duration_ms" => duration_ms,
        "verification" => verification,
        "telemetry" => telemetry
      }
      puts format("ok   %-24s %.2fs", name, duration_ms.fdiv(1_000))
    rescue => error
      @samples.concat(sampler&.samples || [])
      message = error.message.empty? ? error.class.name : error.message
      @workloads << {
        "name" => name,
        "status" => "failed",
        "duration_ms" => duration_ms || 0,
        "verification" => verification || {},
        "telemetry" => telemetry || {},
        "error" => message
      }
      raise
    end

    def build_result(status, runner, started_at, started)
      completed_at = Time.now.utc
      canonical_outputs = @outputs.sort.to_h
      {
        "schema_version" => @manifest.fetch("schema_version"),
        "benchmark_version" => @manifest.fetch("benchmark_version"),
        "run_id" => SecureRandom.uuid,
        "commit_sha" => @commit_sha,
        "git_dirty" => @git_dirty,
        "partial" => !@workload_name.nil?,
        "scored" => @workload_name.nil? && @manifest.fetch("profiles").fetch(@profile).fetch("scored"),
        "target" => "local",
        "profile" => @profile,
        "scenario" => @workload_name ? "workload:#{@workload_name}" : "baseline",
        "status" => status,
        "runner" => runner,
        "timeline" => {
          "started_at" => started_at.iso8601(6),
          "completed_at" => completed_at.iso8601(6),
          "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
        },
        "workloads" => @workloads,
        "caches" => [],
        "resources" => { "samples" => @samples },
        "verification" => {
          "digest" => verification_digest(canonical_outputs),
          "outputs" => canonical_outputs
        }
      }
    end

    def verify_expected_digest!
      return if @workload_name

      expected = @manifest.fetch("profiles").fetch(@profile).fetch("expected_verification_digest")
      actual = verification_digest(@outputs)
      return if actual == expected

      raise InvalidResult, "verification digest mismatch: expected #{expected}, got #{actual}"
    end

    def verify_workload!(workload, verification)
      expected = workload.fetch("expected_verification_digest")
      actual = verification_digest(verification)
      return if actual == expected

      raise InvalidResult, "#{workload.fetch("name")} verification mismatch: expected #{expected}, got #{actual}"
    end

    def verification_digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical_verification(value)))
    end

    def canonical_verification(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, canonical_verification(value.fetch(key))] }
      when Array
        value.map { |item| canonical_verification(item) }
      when Float
        raise InvalidResult, "verification values must not contain floating-point numbers"
      else
        value
      end
    end

    def validate_limits!(workload, samples, telemetry)
      limits = workload.fetch("limits")
      peak_rss = ([telemetry["peak_rss_bytes"]] + samples.map { |sample| sample.fetch("rss_bytes") }).compact.max || 0
      peak_disk = ([telemetry["peak_benchmark_disk_bytes"]] + samples.map { |sample| sample.fetch("disk_used_bytes") }).compact.max || 0
      minimum_free_disk = samples.map { |sample| sample.fetch("disk_available_bytes") }.min || Host.disk_available_bytes

      violations = []
      violations << "peak RSS #{peak_rss} > #{limits.fetch("peak_rss_bytes")}" if peak_rss > limits.fetch("peak_rss_bytes")
      violations << "peak benchmark disk #{peak_disk} > #{limits.fetch("peak_benchmark_disk_bytes")}" if peak_disk > limits.fetch("peak_benchmark_disk_bytes")
      violations << "free disk #{minimum_free_disk} < #{limits.fetch("min_free_disk_bytes")}" if minimum_free_disk < limits.fetch("min_free_disk_bytes")
      return if violations.empty?

      raise InvalidResult, "#{workload.fetch("name")} resource limit violation: #{violations.join(", ")}"
    end

    def selected_workloads
      workloads = @manifest.fetch("profiles").fetch(@profile).fetch("workloads")
      return workloads unless @workload_name

      [workloads.find { |workload| workload.fetch("name") == @workload_name }].compact
    end

    def write_and_validate!(result)
      schema = JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH)))
      errors = schema.validate(result).to_a
      raise SchemaError, "result schema errors: #{JSON.pretty_generate(errors)}" unless errors.empty?

      FileUtils.mkdir_p(File.dirname(@output_path))
      File.write(@output_path, JSON.pretty_generate(result) << "\n")
    end
  end

  class CLI
    def self.start(arguments)
      new(arguments).start
    rescue OptionParser::ParseError, KeyError, Error, Fixtures::VerificationError => error
      warn "error: #{error.message}"
      exit 1
    end

    def initialize(arguments)
      @arguments = arguments.dup
      @manifest = YAML.safe_load(File.read(MANIFEST_PATH))
      @profile = "smoke"
      @output_path = nil
      @workload_name = nil
    end

    def start
      command = @arguments.shift
      parse_options!
      ensure_profile!
      ensure_workload!

      case command
      when "doctor"
        Doctor.new(@manifest, @profile).check!
      when "fixtures"
        path = File.join(ROOT, "benchmark/fixtures/checksums.json")
        fixtures = Fixtures.verify_manifest!(path)
        puts "verified #{fixtures.fetch("fixtures").length} deterministic fixtures"
      when "run"
        Runner.new(
          @manifest,
          @profile,
          @output_path || default_output_path,
          workload_name: @workload_name
        ).run!
      else
        raise Error, "usage: bin/bench <doctor|fixtures|run> [--profile PROFILE] [--output PATH]"
      end
    end

    private

    def parse_options!
      OptionParser.new do |options|
        options.on("--profile PROFILE") { |profile| @profile = profile }
        options.on("--workload NAME") { |name| @workload_name = name }
        options.on("--output PATH") { |path| @output_path = File.expand_path(path, ROOT) }
      end.parse!(@arguments)
      raise Error, "unexpected arguments: #{@arguments.join(" ")}" unless @arguments.empty?
    end

    def ensure_profile!
      return if @manifest.fetch("profiles").key?(@profile)

      raise Error, "unknown profile: #{@profile}"
    end

    def ensure_workload!
      return unless @workload_name

      names = @manifest.fetch("profiles").fetch(@profile).fetch("workloads").map { |workload| workload.fetch("name") }
      return if names.include?(@workload_name)

      raise Error, "unknown workload for #{@profile}: #{@workload_name}"
    end

    def default_output_path
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S")
      suffix = [@profile, @workload_name].compact.join("-")
      File.join(ROOT, "results/#{timestamp}-local-#{suffix}.json")
    end
  end
end
