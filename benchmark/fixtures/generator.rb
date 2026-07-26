require "digest"
require "json"

module CiBench
  module Fixtures
    class VerificationError < StandardError; end

    class Generator
      def initialize(seed)
        @seed = Integer(seed)
      end

      def write_binary(io, bytes:, stream:)
        bytes = valid_bytes(bytes)
        write_exact(io, bytes) do |index|
          Digest::SHA256.digest("#{@seed}:#{stream}:binary:#{index}")
        end
      end

      def write_text(io, bytes:, stream:)
        bytes = valid_bytes(bytes)
        write_exact(io, bytes) do |index|
          token = Digest::SHA256.hexdigest("#{@seed}:#{stream}:text:#{index}")
          format("%08d,%s,%s\n", index, stream, token)
        end
      end

      def checksum(kind:, bytes:, stream:)
        digest = Digest::SHA256.new
        public_send(
          :"write_#{kind}",
          DigestWriter.new(digest),
          bytes: bytes,
          stream: stream
        )
        digest.hexdigest
      end

      private

      def valid_bytes(value)
        bytes = Integer(value)
        raise ArgumentError, "bytes must be non-negative" if bytes.negative?

        bytes
      end

      def write_exact(io, bytes)
        written = 0
        index = 0

        while written < bytes
          value = yield(index)
          remaining = bytes - written
          chunk = value.bytesize <= remaining ? value : value.byteslice(0, remaining)
          io.write(chunk)
          written += chunk.bytesize
          index += 1
        end

        written
      end
    end

    class DigestWriter
      def initialize(digest)
        @digest = digest
      end

      def write(value)
        @digest << value
        value.bytesize
      end
    end

    class << self
      def verify_manifest!(path)
        manifest = JSON.parse(File.read(path))
        generator = Generator.new(manifest.fetch("seed"))

        manifest.fetch("fixtures").each do |fixture|
          actual = generator.checksum(
            kind: fixture.fetch("kind"),
            bytes: fixture.fetch("bytes"),
            stream: fixture.fetch("stream")
          )
          expected = fixture.fetch("sha256")
          unless actual == expected
            raise VerificationError,
              "fixture #{fixture.fetch("name")} checksum mismatch: expected #{expected}, got #{actual}"
          end
        end

        manifest
      end
    end
  end
end
