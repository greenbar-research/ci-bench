class ProjectsController < ApplicationController
  def index
    @projects = Project.order(created_at: :desc)
  end

  def create
    Project.create!(project_params)
    redirect_to projects_path
  end

  private

  def project_params
    params.expect(project: [:name])
  end
end
