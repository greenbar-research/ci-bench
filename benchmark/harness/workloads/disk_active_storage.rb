require "digest"
require "fileutils"
require "image_processing/mini_magick"
require "json"
require "mini_magick"
require "openssl"
require "open3"

output_path = ENV.fetch("BENCH_OUTPUT")
parameters = JSON.parse(ENV.fetch("BENCH_PARAMS"))
seed = Integer(ENV.fetch("BENCH_SEED"))
root = Rails.root.join("tmp/bench/disk-active-storage")
source_directory = root.join("source")
extract_directory = root.join("extracted")
copy_directory = root.join("copied")
download_directory = root.join("downloaded")
archive_path = root.join("artifacts.tar")
transformed_path = root.join("transformed.png")
phase_durations = {}
peak_disk_bytes = 0

positive_parameters = %w[artifact_count bytes_per_artifact image_dimension transformed_dimension]
unless positive_parameters.all? { |name| parameters.fetch(name).positive? }
  raise "disk-active-storage workload parameters must be positive"
end

measure = lambda do |name, &block|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  block.call
ensure
  phase_durations[name] = (
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
  ).round
end

tree_bytes = lambda do
  Dir.glob(Rails.root.join("tmp/bench/**/*"), File::FNM_DOTMATCH)
    .select { |path| File.file?(path) }
    .sum { |path| File.size(path) }
end
record_peak = -> { peak_disk_bytes = [peak_disk_bytes, tree_bytes.call].max }
fsync_tree = lambda do |directory|
  Dir.glob(File.join(directory, "**/*")).select { |path| File.file?(path) }.each do |path|
    File.open(path, "rb", &:fsync)
  end
end

manifest_for = lambda do |directory|
  Dir.glob(File.join(directory, "*.bin")).sort.map do |path|
    [File.basename(path), File.size(path), Digest::SHA256.file(path).hexdigest]
  end
end

storage_models = [
  Artifact,
  ActiveStorage::Attachment,
  ActiveStorage::Blob,
  ActiveStorage::VariantRecord
]
unless storage_models.all? { |model| model.count.zero? }
  raise "disk-active-storage workload requires empty artifact storage tables"
end
stale_storage_files = Dir.glob(Rails.root.join("tmp/bench/storage/**/*"))
  .count { |path| File.file?(path) }
raise "disk-active-storage workload requires empty artifact storage" unless stale_storage_files.zero?

FileUtils.rm_rf(root)
FileUtils.mkdir_p(source_directory)

measure.call("generate") do
  parameters.fetch("artifact_count").times do |index|
    path = source_directory.join(format("artifact-%05d.bin", index))
    cipher = OpenSSL::Cipher.new("aes-256-ctr")
    cipher.encrypt
    cipher.key = Digest::SHA256.digest("#{seed}:disk-active-storage:#{index}:key")
    cipher.iv = Digest::SHA256.digest("#{seed}:disk-active-storage:#{index}:iv").byteslice(0, 16)
    remaining = parameters.fetch("bytes_per_artifact")
    zeroes = "\0".b * 1_048_576
    File.open(path, "wb") do |file|
      while remaining.positive?
        bytes = [remaining, zeroes.bytesize].min
        file.write(cipher.update(zeroes.byteslice(0, bytes)))
        remaining -= bytes
      end
      file.write(cipher.final)
      file.flush
      file.fsync
    end
  end
end
source_manifest = nil
measure.call("verify_source") { source_manifest = manifest_for.call(source_directory) }
record_peak.call

workload_project = nil
workload_build = nil
measure.call("active_storage") do
  workload_project = Project.create!(name: "disk-active-storage")
  workload_build = workload_project.builds.create!(
    number: 1,
    commit_sha: Digest::SHA1.hexdigest("#{seed}:disk-active-storage"),
    state: "passed",
    duration_ms: 0
  )

  source_manifest.each do |name, bytes, checksum|
    artifact = workload_build.artifacts.create!(name: name, byte_size: bytes, checksum: checksum)
    File.open(source_directory.join(name), "rb") do |file|
      artifact.file.attach(io: file, filename: name, content_type: "application/octet-stream")
    end
  end

  FileUtils.mkdir_p(download_directory)
  workload_build.artifacts.order(:name).each do |artifact|
    File.open(download_directory.join(artifact.name), "wb") do |file|
      artifact.file.download { |chunk| file.write(chunk) }
      file.flush
      file.fsync
    end
  end
  fsync_tree.call(Rails.root.join("tmp/bench/storage"))
end
download_manifest = nil
measure.call("verify_active_storage") do
  download_manifest = manifest_for.call(download_directory)
  raise "Active Storage download mismatch" unless download_manifest == source_manifest
end
record_peak.call

measure.call("archive_extract_copy") do
  FileUtils.mkdir_p(extract_directory)
  stdout, stderr, status = Open3.capture3(
    "tar",
    "-cf",
    archive_path.to_s,
    "-C",
    source_directory.to_s,
    "."
  )
  raise "tar creation failed: #{stdout}#{stderr}" unless status.success?

  stdout, stderr, status = Open3.capture3(
    "tar",
    "-xf",
    archive_path.to_s,
    "-C",
    extract_directory.to_s
  )
  raise "tar extraction failed: #{stdout}#{stderr}" unless status.success?

  FileUtils.cp_r(extract_directory, copy_directory)
  fsync_tree.call(root)
end
extracted_manifest = nil
copied_manifest = nil
measure.call("verify_archive_copy") do
  extracted_manifest = manifest_for.call(extract_directory)
  copied_manifest = manifest_for.call(copy_directory)
  raise "archive extraction mismatch" unless extracted_manifest == source_manifest
  raise "recursive copy mismatch" unless copied_manifest == source_manifest
end
record_peak.call

measure.call("transform") do
  dimension = parameters.fetch("image_dimension")
  image_path = root.join("fixture.ppm")
  File.open(image_path, "wb") do |file|
    file.write("P6\n#{dimension} #{dimension}\n255\n")
    dimension.times do |y|
      row = dimension.times.flat_map do |x|
        [x % 256, y % 256, (x + y + seed) % 256]
      end.pack("C*")
      file.write(row)
    end
  end

  image_artifact = workload_build.artifacts.create!(
    name: "fixture.ppm",
    byte_size: File.size(image_path),
    checksum: Digest::SHA256.file(image_path).hexdigest
  )
  File.open(image_path, "rb") do |file|
    image_artifact.file.attach(
      io: file,
      filename: "fixture.ppm",
      content_type: "image/x-portable-pixmap",
      identify: false
    )
  end
  variant = image_artifact.file.variant(
    resize_to_limit: [parameters.fetch("transformed_dimension")] * 2
  ).processed
  File.binwrite(transformed_path, variant.download)
end
transformed = MiniMagick::Image.open(transformed_path)
transformed_dimensions = [transformed.width, transformed.height]
expected_dimensions = [parameters.fetch("transformed_dimension")] * 2
raise "image transform dimensions mismatch" unless transformed_dimensions == expected_dimensions
record_peak.call

measure.call("delete") do
  workload_build.artifacts.find_each(&:destroy!)
  workload_project.destroy!
end
remaining_storage_records = {
  artifacts: Artifact.count,
  attachments: ActiveStorage::Attachment.count,
  blobs: ActiveStorage::Blob.count,
  variants: ActiveStorage::VariantRecord.count
}
raise "Active Storage records remain after delete" unless remaining_storage_records.values.all?(&:zero?)
remaining_storage_files = Dir.glob(Rails.root.join("tmp/bench/storage/**/*"))
  .count { |path| File.file?(path) }
raise "Active Storage files remain after delete" unless remaining_storage_files.zero?

verification = {
  artifact_count: parameters.fetch("artifact_count"),
  source_bytes: source_manifest.sum { |_, bytes, _| bytes },
  source_manifest_digest: Digest::SHA256.hexdigest(JSON.generate(source_manifest)),
  active_storage_manifest_digest: Digest::SHA256.hexdigest(JSON.generate(download_manifest)),
  extracted_manifest_digest: Digest::SHA256.hexdigest(JSON.generate(extracted_manifest)),
  copied_manifest_digest: Digest::SHA256.hexdigest(JSON.generate(copied_manifest)),
  transformed_dimensions: transformed_dimensions,
  remaining_storage_records: remaining_storage_records,
  remaining_storage_files: remaining_storage_files
}

File.write(
  output_path,
  JSON.generate(
    "verification" => verification,
    "telemetry" => {
      "phase_duration_ms" => phase_durations,
      "peak_benchmark_disk_bytes" => peak_disk_bytes,
      "archive_bytes" => File.size(archive_path)
    }
  ) << "\n"
)
FileUtils.rm_rf(root)
