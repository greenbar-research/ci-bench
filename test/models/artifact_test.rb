require "test_helper"

class ArtifactTest < ActiveSupport::TestCase
  test "purges its attached blob synchronously when destroyed" do
    project = Project.create!(name: "artifact-cleanup")
    build = project.builds.create!(
      number: 1,
      commit_sha: "c" * 40,
      state: "passed",
      duration_ms: 0
    )
    artifact = build.artifacts.create!(
      name: "results.json",
      byte_size: 2,
      checksum: "2689367b205c16ce32ed4200942b8b1e"
    )
    artifact.file.attach(
      io: StringIO.new("{}"),
      filename: "results.json",
      content_type: "application/json"
    )

    assert_difference ["Artifact.count", "ActiveStorage::Attachment.count", "ActiveStorage::Blob.count"], -1 do
      artifact.destroy!
    end
  end
end
