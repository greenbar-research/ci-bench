require "digest"
require "fileutils"
require "json"

output_path = ENV.fetch("BENCH_OUTPUT")
directory = File.expand_path("../../../tmp/bench/file-io", __dir__)
source = File.join(directory, "source.bin")
copy = File.join(directory, "copy.bin")
block = (0...16_384).map { |index| (index * 31) % 256 }.pack("C*")

FileUtils.rm_rf(directory)
FileUtils.mkdir_p(directory)

File.open(source, "wb") do |file|
  1_024.times { file.write(block) }
  file.flush
  file.fsync
end
IO.copy_stream(source, copy)

source_digest = Digest::SHA256.file(source).hexdigest
copy_digest = Digest::SHA256.file(copy).hexdigest
raise "copy checksum mismatch" unless source_digest == copy_digest

result = {
  bytes: File.size(source),
  copies: 1,
  digest: source_digest
}
File.write(output_path, JSON.generate(result) << "\n")
FileUtils.rm_rf(directory)
