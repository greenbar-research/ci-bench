require "test_helper"

class TestCasesControllerTest < ActionDispatch::IntegrationTest
  test "creates a test result for a project build" do
    project = Project.create!(name: "test-results")
    build = project.builds.create!(
      number: 1,
      commit_sha: "a" * 40,
      state: "failed",
      duration_ms: 100
    )

    assert_difference "TestCase.count", 1 do
      post project_build_test_cases_path(project, build), params: {
        test_case: { name: "reports failure", state: "failed", duration_ms: 42 }
      }
    end

    assert_redirected_to project
    assert_equal "reports failure", build.test_cases.sole.name
  end
end
