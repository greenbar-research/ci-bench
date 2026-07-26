class BuildsController < ApplicationController
  def create
    project = Project.find(params[:project_id])
    project.transaction do
      build = project.builds.create!(build_params)
      AuditEvent.create!(
        project: project,
        user: current_user,
        action: "build.created",
        metadata: { build_id: build.id }
      )
    end
    redirect_to project
  end

  private

  def build_params
    params.expect(build: %i[number commit_sha state duration_ms])
  end
end
