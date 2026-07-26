require "csv"
require "digest"
require "fileutils"
require "json"
require "openssl"

output_path = ENV.fetch("BENCH_OUTPUT")
parameters = JSON.parse(ENV.fetch("BENCH_PARAMS"))
seed = Integer(ENV.fetch("BENCH_SEED"))
root = File.expand_path("../../../tmp/bench/memory-import", __dir__)
csv_path = File.join(root, "results.csv")
json_path = File.join(root, "results.ndjson")
phase_durations = {}

positive_parameters = %w[row_count project_count retained_bytes allocation_chunk_bytes]
unless positive_parameters.all? { |name| parameters.fetch(name).positive? }
  raise "memory-import workload parameters must be positive"
end

measure = lambda do |name, &block|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  block.call
ensure
  phase_durations[name] = (
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
  ).round
end

row_for = lambda do |index|
  selector = (index + seed) % 10
  {
    "id" => index,
    "project" => index % parameters.fetch("project_count"),
    "state" => selector.zero? ? "failed" : (selector == 1 ? "skipped" : "passed"),
    "duration_ms" => ((index + 1) * 17 + seed) % 10_000
  }
end

FileUtils.rm_rf(root)
FileUtils.mkdir_p(root)

measure.call("generate_inputs") do
  CSV.open(csv_path, "wb") do |csv|
    csv << %w[id project state duration_ms]
    parameters.fetch("row_count").times do |index|
      row = row_for.call(index)
      csv << row.values_at("id", "project", "state", "duration_ms")
    end
  end

  File.open(json_path, "wb") do |file|
    parameters.fetch("row_count").times do |index|
      file.write(JSON.generate(row_for.call(index)) << "\n")
    end
  end
end

empty_aggregate = -> { { "passed" => [0, 0], "failed" => [0, 0], "skipped" => [0, 0] } }
csv_aggregate = empty_aggregate.call
json_aggregate = empty_aggregate.call
csv_rows = Digest::SHA256.new
json_rows = Digest::SHA256.new
digest_row = lambda do |digest, row|
  digest << JSON.generate(
    "id" => Integer(row.fetch("id")),
    "project" => Integer(row.fetch("project")),
    "state" => row.fetch("state"),
    "duration_ms" => Integer(row.fetch("duration_ms"))
  )
  digest << "\n"
end

measure.call("parse_csv") do
  CSV.foreach(csv_path, headers: true) do |row|
    values = csv_aggregate.fetch(row.fetch("state"))
    values[0] += 1
    values[1] += Integer(row.fetch("duration_ms"))
    digest_row.call(csv_rows, row)
  end
end

measure.call("parse_json") do
  File.foreach(json_path) do |line|
    row = JSON.parse(line)
    values = json_aggregate.fetch(row.fetch("state"))
    values[0] += 1
    values[1] += row.fetch("duration_ms")
    digest_row.call(json_rows, row)
  end
end
raise "CSV and JSON aggregates differ" unless csv_aggregate == json_aggregate
raise "CSV and JSON rows differ" unless csv_rows.digest == json_rows.digest

retained = []
retained_probe = Digest::SHA256.new
chunk_index = 0
plaintext = "\0".b * parameters.fetch("allocation_chunk_bytes")
measure.call("retain_memory") do
  remaining = parameters.fetch("retained_bytes")
  while remaining.positive?
    bytes = [remaining, parameters.fetch("allocation_chunk_bytes")].min
    cipher = OpenSSL::Cipher.new("aes-256-ctr")
    cipher.encrypt
    cipher.key = Digest::SHA256.digest("#{seed}:memory:#{chunk_index}:key")
    cipher.iv = Digest::SHA256.digest("#{seed}:memory:#{chunk_index}:iv").byteslice(0, 16)
    chunk = cipher.update(bytes == plaintext.bytesize ? plaintext : plaintext.byteslice(0, bytes))
    chunk << cipher.final
    retained << chunk
    retained_probe << chunk.byteslice(0, [64, chunk.bytesize].min)
    retained_probe << chunk.byteslice(-[64, chunk.bytesize].min, [64, chunk.bytesize].min)
    remaining -= bytes
    chunk_index += 1
  end
end
retained_bytes = retained.sum(&:bytesize)
raise "retained byte count mismatch" unless retained_bytes == parameters.fetch("retained_bytes")

vmhwm_kib = if File.exist?("/proc/self/status")
  File.read("/proc/self/status")[/^VmHWM:\s+(\d+)/, 1]
end
if vmhwm_kib
  peak_rss_bytes = Integer(vmhwm_kib) * 1_024
  peak_rss_source = "vmhwm"
else
  current_rss_kib = IO.popen(["ps", "-o", "rss=", "-p", Process.pid.to_s], &:read).strip
  raise "could not measure process RSS" if current_rss_kib.empty?

  peak_rss_bytes = Integer(current_rss_kib) * 1_024
  peak_rss_source = "current_rss"
end
raise "retained memory is not resident" if peak_rss_bytes < retained_bytes

measure.call("release_memory") do
  retained.clear
  GC.start
end

verification = {
  row_count_per_format: parameters.fetch("row_count"),
  total_records_parsed: parameters.fetch("row_count") * 2,
  aggregate: csv_aggregate,
  aggregate_digest: Digest::SHA256.hexdigest(JSON.generate(csv_aggregate)),
  parsed_rows_digest: csv_rows.hexdigest,
  retained_bytes: retained_bytes,
  retained_chunks: chunk_index,
  retained_probe_digest: retained_probe.hexdigest
}

File.write(
  output_path,
  JSON.generate(
    "verification" => verification,
    "telemetry" => {
      "phase_duration_ms" => phase_durations,
      "peak_rss_bytes" => peak_rss_bytes,
      "peak_rss_source" => peak_rss_source,
      "peak_benchmark_disk_bytes" => File.size(csv_path) + File.size(json_path)
    }
  ) << "\n"
)
FileUtils.rm_rf(root)
