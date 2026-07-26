class TestCasesController < ApplicationController
  def create
    project = Project.find(params[:project_id])
    build = project.builds.find(params[:build_id])
    build.test_cases.create!(test_case_params)
    redirect_to project
  end

  private

  def test_case_params
    params.expect(test_case: %i[name state duration_ms])
  end
end
