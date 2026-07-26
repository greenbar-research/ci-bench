require "test_helper"

class BuildTest < ActiveSupport::TestCase
  test "accepts the benchmark build states" do
    project = Project.create!(name: "state-validation")

    Build::STATES.each do |state|
      assert project.builds.new(
        number: 1,
        commit_sha: "f" * 40,
        state: state,
        duration_ms: 0
      ).valid?
    end

    assert_not project.builds.new(
      number: 1,
      commit_sha: "f" * 40,
      state: "running",
      duration_ms: 0
    ).valid?
  end

  test "requires a unique project build number and a full commit SHA" do
    project = Project.create!(name: "build-identity")
    project.builds.create!(
      number: 1,
      commit_sha: "a" * 40,
      state: "passed",
      duration_ms: 0
    )

    duplicate = project.builds.new(
      number: 1,
      commit_sha: "short",
      state: "passed",
      duration_ms: 0
    )

    assert_not duplicate.valid?
    assert duplicate.errors.added?(:number, :taken, value: 1)
    assert duplicate.errors.added?(:commit_sha, :invalid, value: "short")
  end
end
