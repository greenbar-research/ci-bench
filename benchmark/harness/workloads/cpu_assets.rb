require "digest"
require "erb"
require "fileutils"
require "json"
require "pathname"
require "zlib"

output_path = ENV.fetch("BENCH_OUTPUT")
parameters = JSON.parse(ENV.fetch("BENCH_PARAMS"))
seed = Integer(ENV.fetch("BENCH_SEED"))
root = Rails.root.join("tmp/bench/cpu-assets")
assets_path = root.join("assets")
workers_path = root.join("workers")
phase_durations = {}

positive_parameters = %w[
  worker_count
  iterations_per_worker
  payload_bytes
  records_per_iteration
  renders_per_iteration
]
unless positive_parameters.all? { |name| parameters.fetch(name).positive? }
  raise "cpu-assets workload parameters must be positive"
end

measure = lambda do |name, &block|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  block.call
ensure
  phase_durations[name] = (
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
  ).round
end

FileUtils.rm_rf(root)
FileUtils.mkdir_p(workers_path)

asset_manifest = nil
measure.call("compile_assets") do
  # Propshaft builds its processor lazily, so these scoped paths must be set
  # before the first call to #processor.
  Rails.application.config.assets.output_path = assets_path
  Rails.application.config.assets.manifest_path = assets_path.join(".manifest.json")
  Rails.application.assets.processor.process
  asset_manifest = JSON.parse(File.read(assets_path.join(".manifest.json")))
end

asset_source = Dir.glob(assets_path.join("**/*")).select do |path|
  File.file?(path) && File.basename(path) != ".manifest.json"
end.sort.map { |path| File.binread(path) }.join
raise "compiled assets are empty" if asset_source.empty?

payload_bytes = parameters.fetch("payload_bytes")
asset_payload = (asset_source * ((payload_bytes + asset_source.bytesize - 1) / asset_source.bytesize))
  .byteslice(0, payload_bytes)

worker = lambda do |worker_index|
  template = ERB.new(
    "<article data-worker=\"<%= worker %>\"><h1><%= title %></h1>" \
      "<p><%= body %></p></article>"
  )
  result = Digest::SHA256.new

  parameters.fetch("iterations_per_worker").times do |iteration|
    compressed = Zlib::Deflate.deflate(asset_payload, Zlib::BEST_COMPRESSION)
    raise "compressed asset round trip failed" unless Zlib::Inflate.inflate(compressed) == asset_payload

    result << Digest::SHA256.digest(asset_payload)

    records = parameters.fetch("records_per_iteration").times.map do |record_index|
      {
        "id" => record_index,
        "worker" => worker_index,
        "iteration" => iteration,
        "duration_ms" => ((record_index + 1) * 17 + seed + worker_index) % 10_000
      }
    end
    result << Digest::SHA256.digest(JSON.generate(records))

    parameters.fetch("renders_per_iteration").times do |render_index|
      result << template.result_with_hash(
        worker: worker_index,
        title: "Build #{iteration}-#{render_index}",
        body: Digest::SHA256.hexdigest("#{seed}:#{worker_index}:#{iteration}:#{render_index}")
      )
    end
  end

  File.write(
    workers_path.join("#{worker_index}.json"),
    JSON.generate(
      "worker" => worker_index,
      "digest" => result.hexdigest,
      "payload_bytes" => asset_payload.bytesize
    ) << "\n"
  )
end

measure.call("parallel_cpu") do
  workers = parameters.fetch("worker_count").times.to_h do |worker_index|
    pid = Process.fork do
      worker.call(worker_index)
      exit! 0
    rescue => error
      warn "cpu-assets worker #{worker_index} failed: #{error.full_message}"
      exit! 1
    end
    [worker_index, pid]
  end

  failed_workers = workers.filter_map do |worker_index, pid|
    _, status = Process.wait2(pid)
    worker_index unless status.success?
  end
  raise "cpu-assets workers failed: #{failed_workers.join(", ")}" if failed_workers.any?
end

worker_results = Dir.glob(workers_path.join("*.json")).sort_by do |path|
  Integer(File.basename(path, ".json"))
end.map do |path|
  JSON.parse(File.read(path))
end
expected_workers = (0...parameters.fetch("worker_count")).to_a
unless worker_results.map { |result| result.fetch("worker") } == expected_workers
  raise "cpu-assets worker results are incomplete"
end
unless worker_results.all? { |result| result.fetch("payload_bytes") == parameters.fetch("payload_bytes") }
  raise "cpu-assets worker payload size mismatch"
end

verification = {
  asset_count: asset_manifest.length,
  asset_manifest_digest: Digest::SHA256.hexdigest(
    JSON.generate(asset_manifest.sort.to_h)
  ),
  worker_count: worker_results.length,
  worker_digest: Digest::SHA256.hexdigest(JSON.generate(worker_results)),
  iterations: parameters.fetch("iterations_per_worker") * worker_results.length,
  compression_operations: parameters.fetch("iterations_per_worker") * worker_results.length,
  records_serialized: (
    parameters.fetch("records_per_iteration") *
    parameters.fetch("iterations_per_worker") *
    worker_results.length
  ),
  templates_rendered: (
    parameters.fetch("renders_per_iteration") *
    parameters.fetch("iterations_per_worker") *
    worker_results.length
  )
}
peak_disk_bytes = Dir.glob(root.join("**/*"), File::FNM_DOTMATCH).sum do |path|
  File.file?(path) ? File.size(path) : 0
end

File.write(
  output_path,
  JSON.generate(
    "verification" => verification,
    "telemetry" => {
      "phase_duration_ms" => phase_durations,
      "peak_benchmark_disk_bytes" => peak_disk_bytes
    }
  ) << "\n"
)
FileUtils.rm_rf(root)
