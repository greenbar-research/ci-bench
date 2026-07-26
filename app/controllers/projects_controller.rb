class ProjectsController < ApplicationController
  def index
    @projects = Project.order(created_at: :desc, id: :desc)
  end

  def show
    @project = Project.find(params[:id])
    @builds = @project.builds.order(number: :desc, id: :desc)
    @builds = @builds.where(state: params[:state]) if Build::STATES.include?(params[:state])
    @test_cases = TestCase.joins(:build)
      .where(builds: { project_id: @project.id })
      .order(:name, :id)
    if TestCase::STATES.include?(params[:test_state])
      @test_cases = @test_cases.where(state: params[:test_state])
    end
  end

  def create
    project = Project.transaction do
      created_project = Project.create!(project_params.merge(owner: current_user))
      AuditEvent.create!(project: created_project, user: current_user, action: "project.created")
      created_project
    end
    redirect_to project
  end

  private

  def project_params
    params.expect(project: [:name])
  end
end
