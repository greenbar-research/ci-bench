require "test_helper"

class BuildsControllerTest < ActionDispatch::IntegrationTest
  test "creates a build and audit event atomically" do
    project = Project.create!(name: "runtime")

    assert_difference ["Build.count", "AuditEvent.count"], 1 do
      post project_builds_path(project), params: {
        build: {
          number: 42,
          commit_sha: "a" * 40,
          state: "passed",
          duration_ms: 1_234
        }
      }
    end

    build = project.builds.sole
    assert_redirected_to project
    assert_equal(
      { "build_id" => build.id },
      project.audit_events.find_by!(action: "build.created").metadata
    )
  end

  test "rolls back build creation when its audit event fails" do
    project = Project.create!(name: "rollback-build")

    assert_no_difference ["Build.count", "AuditEvent.count"] do
      with_failing_audit_events do
        post project_builds_path(project), params: {
          build: {
            number: 1,
            commit_sha: "b" * 40,
            state: "passed",
            duration_ms: 10
          }
        }
        assert_response :unprocessable_entity
      end
    end
  end
end
