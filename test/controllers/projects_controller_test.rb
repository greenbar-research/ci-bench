require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  test "creates a project and audit event for the signed-in user" do
    user = User.create!(
      email: "OWNER@example.com",
      name: "Owner",
      password: "benchmark-password"
    )
    post session_path, params: { email: "owner@example.com", password: "benchmark-password" }

    assert_difference ["Project.count", "AuditEvent.count"], 1 do
      post projects_path, params: { project: { name: "compiler" } }
    end

    project = Project.find_by!(name: "compiler")
    assert_redirected_to project
    assert_equal user, project.owner
    assert_equal "project.created", project.audit_events.sole.action
  end

  test "filters a project report by build state" do
    project = Project.create!(name: "filter-demo")
    project.builds.create!(
      number: 1,
      commit_sha: "1" * 40,
      state: "passed",
      duration_ms: 100
    )
    project.builds.create!(
      number: 2,
      commit_sha: "2" * 40,
      state: "failed",
      duration_ms: 200
    )

    get project_path(project, state: "failed")

    assert_response :success
    assert_select "tbody tr", count: 1
    assert_select "tbody", text: /failed/
    assert_select "tbody", text: /#{Regexp.escape("2" * 40)}/
  end

  test "filters test results and preserves report totals" do
    project = Project.create!(name: "test-filter-demo")
    build = project.builds.create!(
      number: 1,
      commit_sha: "3" * 40,
      state: "failed",
      duration_ms: 300
    )
    build.test_cases.create!(name: "passes", state: "passed", duration_ms: 10)
    build.test_cases.create!(name: "fails", state: "failed", duration_ms: 20)

    get project_path(project, test_state: "failed")

    assert_response :success
    assert_select "table[aria-label='Test results'] tbody tr", count: 1
    assert_select "table[aria-label='Test results'] tbody", text: /fails/
    assert_select "section[aria-label='Test report']", text: /Total\s*2/
  end

  test "rolls back project creation when its audit event fails" do
    assert_no_difference ["Project.count", "AuditEvent.count"] do
      with_failing_audit_events do
        post projects_path, params: { project: { name: "rollback-project" } }
        assert_response :unprocessable_entity
      end
    end
  end
end
