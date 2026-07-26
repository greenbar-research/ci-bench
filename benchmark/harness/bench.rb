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

module CiBench
  ROOT = File.expand_path("../..", __dir__)
  MANIFEST_PATH = File.join(ROOT, "benchmark/manifest.yml")
  SCHEMA_PATH = File.join(ROOT, "benchmark/schema/result-v1.json")

  class Error < StandardError; end
  class InvalidResult < Error; end

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

    def initialize(workload)
      @workload = workload
      @samples = []
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
      @samples << {
        "elapsed_ms" => elapsed_ms(started),
        "workload" => @workload,
        "cpu_percent" => selected.sum { |process| process.fetch(:cpu) }.round(2),
        "rss_bytes" => selected.sum { |process| process.fetch(:rss_kib) } * 1_024,
        "disk_used_bytes" => benchmark_disk_bytes,
        "disk_available_bytes" => Host.disk_available_bytes
      }
    end

    def process_table
      Command.capture!("ps", "-axo", "pid=,ppid=,rss=,%cpu=").lines.to_h do |line|
        pid, ppid, rss_kib, cpu = line.split
        [pid.to_i, { ppid: ppid.to_i, rss_kib: rss_kib.to_i, cpu: cpu.to_f }]
      end
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
    def initialize(manifest, profile, output_path)
      @manifest = manifest
      @profile = profile
      @output_path = output_path
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

      @manifest.fetch("profiles").fetch(@profile).fetch("workloads").each do |workload|
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
      FileUtils.mkdir_p(File.join(ROOT, "tmp/bench"))
    end

    def run_workload(workload)
      name = workload.fetch("name")
      output_path = File.join(ROOT, "tmp/bench/#{name}.json")
      FileUtils.rm_f(output_path)
      sampler = Sampler.new(name)
      duration_ms = sampler.run(
        workload.fetch("command"),
        env: { "RAILS_ENV" => "test", "BENCH_OUTPUT" => output_path },
        timeout_seconds: @manifest.fetch("profiles").fetch(@profile).fetch("timeout_seconds")
      )
      verification = JSON.parse(File.read(output_path))
      @outputs[name] = verification
      @samples.concat(sampler.samples)
      @workloads << {
        "name" => name,
        "status" => "passed",
        "duration_ms" => duration_ms,
        "verification" => verification
      }
      puts format("ok   %-24s %.2fs", name, duration_ms.fdiv(1_000))
    rescue => error
      @samples.concat(sampler&.samples || [])
      message = error.message.empty? ? error.class.name : error.message
      @workloads << {
        "name" => name,
        "status" => "failed",
        "duration_ms" => 0,
        "verification" => {},
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
        "target" => "local",
        "profile" => @profile,
        "scenario" => "baseline",
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
          "digest" => Digest::SHA256.hexdigest(JSON.generate(canonical_outputs)),
          "outputs" => canonical_outputs
        }
      }
    end

    def verify_expected_digest!
      expected = @manifest.fetch("profiles").fetch(@profile).fetch("expected_verification_digest")
      actual = Digest::SHA256.hexdigest(JSON.generate(@outputs.sort.to_h))
      return if actual == expected

      raise InvalidResult, "verification digest mismatch: expected #{expected}, got #{actual}"
    end

    def write_and_validate!(result)
      schema = JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH)))
      errors = schema.validate(result).to_a
      raise Error, "result schema errors: #{JSON.pretty_generate(errors)}" unless errors.empty?

      FileUtils.mkdir_p(File.dirname(@output_path))
      File.write(@output_path, JSON.pretty_generate(result) << "\n")
    end
  end

  class CLI
    def self.start(arguments)
      new(arguments).start
    rescue OptionParser::ParseError, KeyError, Error => error
      warn "error: #{error.message}"
      exit 1
    end

    def initialize(arguments)
      @arguments = arguments.dup
      @manifest = YAML.safe_load(File.read(MANIFEST_PATH))
      @profile = "smoke"
      @output_path = nil
    end

    def start
      command = @arguments.shift
      parse_options!
      ensure_profile!

      case command
      when "doctor"
        Doctor.new(@manifest, @profile).check!
      when "run"
        Runner.new(@manifest, @profile, @output_path || default_output_path).run!
      else
        raise Error, "usage: bin/bench <doctor|run> [--profile PROFILE] [--output PATH]"
      end
    end

    private

    def parse_options!
      OptionParser.new do |options|
        options.on("--profile PROFILE") { |profile| @profile = profile }
        options.on("--output PATH") { |path| @output_path = File.expand_path(path, ROOT) }
      end.parse!(@arguments)
      raise Error, "unexpected arguments: #{@arguments.join(" ")}" unless @arguments.empty?
    end

    def ensure_profile!
      return if @manifest.fetch("profiles").key?(@profile)

      raise Error, "unknown profile: #{@profile}"
    end

    def default_output_path
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S")
      File.join(ROOT, "results/#{timestamp}-local-#{@profile}.json")
    end
  end
end
