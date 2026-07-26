require "json"
require "open3"
require "securerandom"

ENV["DOCKER_BUILDKIT"] = "1"

root = File.expand_path("../../..", __dir__)
output_path = ENV.fetch("BENCH_OUTPUT")
parameters = JSON.parse(ENV.fetch("BENCH_PARAMS"))
scope = ENV.fetch("BENCH_SCOPE") { "#{Process.pid}-#{SecureRandom.hex(6)}" }
image = "ci-bench-workload:#{scope}"
container = "ci-bench-workload-#{scope}"
database = "ci_bench_docker_#{scope.tr("-", "_")}"
phase_durations = {}
image_bytes = nil
container_bytes = nil
image_metadata = nil
application_output = nil
health_status = nil
health_body = nil
peak_docker_disk_bytes = 0

unless parameters.fetch("minimum_layer_count").positive? && parameters.fetch("health_timeout_seconds").positive?
  raise "docker workload parameters must be positive"
end

capture = lambda do |*command|
  Open3.capture3(*command, chdir: root)
end
capture_bang = lambda do |*command|
  stdout, stderr, status = capture.call(*command)
  return stdout.strip if status.success?

  raise "#{command.join(" ")} failed: #{stdout}#{stderr}"
end
measure = lambda do |name, &block|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  block.call
ensure
  phase_durations[name] = (
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
  ).round
end
docker_endpoint = JSON.parse(capture_bang.call("docker", "context", "inspect")).fetch(0)
  .dig("Endpoints", "docker", "Host")
unless docker_endpoint&.start_with?("unix://")
  raise "docker workload requires a local Unix-socket Docker context"
end
docker_socket = docker_endpoint.delete_prefix("unix://")
non_negative_integer = lambda do |value, label|
  unless value.is_a?(Integer) && value >= 0
    raise "Docker disk usage #{label} must be a non-negative integer"
  end

  value
end
docker_disk_bytes = lambda do
  payload = JSON.parse(
    capture_bang.call(
      "curl", "--fail", "--silent", "--show-error",
      "--unix-socket", docker_socket,
      "http://localhost/v1.41/system/df"
    )
  )
  payload.fetch("BuildCache")
  volume_bytes = payload.fetch("Volumes", []).sum do |volume|
    non_negative_integer.call(volume.fetch("UsageData").fetch("Size"), "volume Size")
  end
  non_negative_integer.call(payload.fetch("LayersSize"), "LayersSize") +
    non_negative_integer.call(payload.fetch("BuilderSize"), "BuilderSize") +
    payload.fetch("Containers", []).sum do |item|
      # The Engine API omits SizeRw when the writable layer is exactly zero.
      non_negative_integer.call(item.fetch("SizeRw", 0), "container SizeRw")
    end +
    volume_bytes
end

postgres_id = capture_bang.call("docker", "compose", "ps", "--quiet", "postgres")
raise "docker workload requires the Compose PostgreSQL service" if postgres_id.empty?

postgres_metadata = JSON.parse(capture_bang.call("docker", "container", "inspect", postgres_id)).fetch(0)
network = postgres_metadata.dig("NetworkSettings", "Networks").find do |_name, settings|
  settings.fetch("Aliases", []).include?("postgres")
end&.first
raise "could not find the Compose PostgreSQL network" unless network
baseline_docker_disk_bytes = docker_disk_bytes.call
disk_monitor_stop = false
disk_monitor_error = nil
disk_monitor_lock = Mutex.new
disk_monitor = Thread.new do
  loop do
    current = docker_disk_bytes.call - baseline_docker_disk_bytes
    disk_monitor_lock.synchronize do
      peak_docker_disk_bytes = [peak_docker_disk_bytes, current].max
    end
    break if disk_monitor_stop

    sleep 1
  end
rescue => error
  disk_monitor_error = error
end

cleanup_errors = []
begin
  measure.call("build") do
    # BuildKit cache is intentionally retained for repeat-build calibration;
    # its exact daemon bytes are included in the sampled delta below.
    capture_bang.call(
      "docker", "build",
      "--label", "ci-bench.workload=docker",
      "--label", "ci-bench.scope=#{scope}",
      "--tag", image,
      "."
    )
  end

  measure.call("inspect_image") do
    image_metadata = JSON.parse(
      capture_bang.call("docker", "image", "inspect", image)
    ).fetch(0)
    image_bytes = Integer(image_metadata.fetch("Size"))
    layers = image_metadata.dig("RootFS", "Layers")
    unless layers.is_a?(Array) &&
        layers.length >= parameters.fetch("minimum_layer_count") &&
        layers.all? { |layer| layer.match?(/\Asha256:[0-9a-f]{64}\z/) }
      raise "application image layer contract failed"
    end

    config = image_metadata.fetch("Config")
    expected_metadata = {
      "Cmd" => ["./bin/rails", "server"],
      "Entrypoint" => ["/rails/bin/docker-entrypoint"],
      "ExposedPorts" => { "3000/tcp" => {} },
      "User" => "1000:1000",
      "WorkingDir" => "/rails"
    }
    expected_metadata.each do |key, expected|
      actual = config.fetch(key)
      raise "application image #{key} mismatch: #{actual.inspect}" unless actual == expected
    end
  end

  measure.call("boot") do
    capture_bang.call(
      "docker", "run", "--detach",
      "--name", container,
      "--label", "ci-bench.workload=docker",
      "--label", "ci-bench.scope=#{scope}",
      "--network", network,
      "--env", "DATABASE_URL=postgresql://ci_bench:ci_bench@postgres:5432/#{database}",
      "--env", "SECRET_KEY_BASE=#{"0" * 64}",
      image
    )
  end

  measure.call("health") do
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + parameters.fetch("health_timeout_seconds")
    loop do
      stdout, _stderr, status = capture.call(
        "docker", "exec", container,
        "curl", "--silent", "--show-error",
        "--header", "X-Forwarded-Proto: https",
        "--write-out", "\n%{http_code}",
        "http://127.0.0.1:3000/up"
      )
      if status.success?
        candidate_body, status_line = stdout.rpartition("\n").values_at(0, 2)
        candidate_status = Integer(status_line)
        if candidate_status == 200 && candidate_body.include?("background-color: green")
          health_body = candidate_body
          health_status = candidate_status
          break
        end
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        logs = capture.call("docker", "logs", container).values_at(0, 1).join
        raise "application container did not become healthy: #{logs}"
      end

      sleep 0.25
    end
  end
  unless health_status == 200 && health_body.include?("background-color: green")
    raise "application health endpoint verification failed"
  end

  measure.call("verify_application") do
    runner = <<~RUBY
      require "json"
      route = Rails.application.routes.recognize_path("/up", method: :get)
      output = {
        "database_connected" => ActiveRecord::Base.connection.select_value("SELECT 1").to_i == 1,
        "health_controller" => route.fetch(:controller),
        "rails_version" => Rails.version
      }
      puts "CI_BENCH_VERIFY=" + JSON.generate(output)
    RUBY
    stdout = capture_bang.call("docker", "exec", container, "./bin/rails", "runner", runner)
    line = stdout.lines.find { |candidate| candidate.start_with?("CI_BENCH_VERIFY=") }
    raise "application verification output is missing" unless line

    application_output = JSON.parse(line.delete_prefix("CI_BENCH_VERIFY="))
    expected_output = {
      "database_connected" => true,
      "health_controller" => "rails/health",
      "rails_version" => parameters.fetch("rails_version")
    }
    raise "application verification output mismatch" unless application_output == expected_output

    sized_container = JSON.parse(
      capture_bang.call("docker", "container", "inspect", "--size", container)
    ).fetch(0)
    container_bytes = Integer(sized_container.fetch("SizeRw"))
    disk_monitor_lock.synchronize do
      peak_docker_disk_bytes = [peak_docker_disk_bytes, image_bytes + container_bytes].max
    end
  end
ensure
  disk_monitor_stop = true
  disk_monitor.join
  measure.call("cleanup") do
    label = "ci-bench.scope=#{scope}"
    container_ids = capture.call(
      "docker", "container", "ls", "--all", "--quiet", "--filter", "label=#{label}"
    ).then do |stdout, stderr, status|
      cleanup_errors << "container discovery failed: #{stderr}" unless status.success?
      stdout.lines.map(&:strip).reject(&:empty?)
    end
    if container_ids.any?
      stdout, stderr, status = capture.call("docker", "container", "rm", "--force", *container_ids)
      cleanup_errors << "container removal failed: #{stdout}#{stderr}" unless status.success?
    end

    stdout, stderr, status = capture.call(
      "docker", "exec", postgres_id,
      "dropdb", "--if-exists", "--force", "--username", "ci_bench", database
    )
    cleanup_errors << "database cleanup failed: #{stdout}#{stderr}" unless status.success?

    image_ids = capture.call(
      "docker", "image", "ls", "--quiet", "--filter", "label=#{label}"
    ).then do |stdout, stderr, status|
      cleanup_errors << "image discovery failed: #{stderr}" unless status.success?
      stdout.lines.map(&:strip).reject(&:empty?).uniq
    end
    if image_ids.any?
      stdout, stderr, status = capture.call("docker", "image", "rm", "--force", *image_ids)
      cleanup_errors << "image removal failed: #{stdout}#{stderr}" unless status.success?
    end

    stdout, stderr, status = capture.call(
      "docker", "container", "ls", "--all", "--quiet", "--filter", "label=#{label}"
    )
    cleanup_errors << "container cleanup verification failed: #{stderr}" unless status.success? && stdout.strip.empty?
    stdout, stderr, status = capture.call("docker", "image", "ls", "--quiet", "--filter", "label=#{label}")
    cleanup_errors << "image cleanup verification failed: #{stderr}" unless status.success? && stdout.strip.empty?
  end
end
raise "Docker disk sampling failed: #{disk_monitor_error.message}" if disk_monitor_error
raise cleanup_errors.join("; ") if cleanup_errors.any?

required_environment = %w[
  BUNDLE_DEPLOYMENT=1
  BUNDLE_PATH=/usr/local/bundle
  BUNDLE_WITHOUT=development
  LD_PRELOAD=/usr/local/lib/libjemalloc.so
  RAILS_ENV=production
]
unless required_environment.all? { |value| image_metadata.dig("Config", "Env").include?(value) }
  raise "application image environment contract failed"
end

verification = {
  "application_output" => application_output,
  "health_endpoint" => {
    "body_verified" => true,
    "status_code" => health_status
  },
  "image_contract" => {
    "command" => image_metadata.dig("Config", "Cmd"),
    "entrypoint" => image_metadata.dig("Config", "Entrypoint"),
    "environment" => required_environment,
    "exposed_ports" => image_metadata.dig("Config", "ExposedPorts").keys.sort,
    "layer_contract_verified" => true,
    "user" => image_metadata.dig("Config", "User"),
    "working_directory" => image_metadata.dig("Config", "WorkingDir")
  },
  "resources_cleaned" => true
}

File.write(
  output_path,
  JSON.generate(
    "verification" => verification,
    "telemetry" => {
      "architecture" => image_metadata.fetch("Architecture"),
      "container_writable_bytes" => container_bytes,
      "docker_disk_delta_bytes" => peak_docker_disk_bytes,
      "image_bytes" => image_bytes,
      "image_id" => image_metadata.fetch("Id"),
      "layer_count" => image_metadata.dig("RootFS", "Layers").length,
      "peak_benchmark_disk_bytes" => peak_docker_disk_bytes,
      "phase_duration_ms" => phase_durations
    }
  ) << "\n"
)
