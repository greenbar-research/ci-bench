require "test_helper"
require "tempfile"

class ArtifactsControllerTest < ActionDispatch::IntegrationTest
  test "uploads an artifact with verified metadata" do
    project = Project.create!(name: "artifact-upload")
    build = project.builds.create!(
      number: 1,
      commit_sha: "b" * 40,
      state: "passed",
      duration_ms: 100
    )
    contents = "deterministic browser artifact"
    upload = Tempfile.create(["report", ".txt"]) do |file|
      file.write(contents)
      file.rewind
      Rack::Test::UploadedFile.new(file.path, "text/plain", original_filename: "report.txt")
    end

    assert_difference ["Artifact.count", "ActiveStorage::Blob.count"], 1 do
      post project_build_artifacts_path(project, build), params: { artifact: { file: upload } }
    end

    artifact = build.artifacts.sole
    assert_redirected_to project
    assert_equal "report.txt", artifact.name
    assert_equal contents.bytesize, artifact.byte_size
    assert_equal Digest::SHA256.hexdigest(contents), artifact.checksum
    assert_equal contents, artifact.file.download
  ensure
    upload&.close
  end
end
