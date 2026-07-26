require "digest"

class ArtifactsController < ApplicationController
  def create
    project = Project.find(params[:project_id])
    build = project.builds.find(params[:build_id])
    upload = params.expect(artifact: [:file]).fetch(:file)
    contents = upload.read

    build.transaction do
      artifact = build.artifacts.new(
        name: upload.original_filename,
        byte_size: contents.bytesize,
        checksum: Digest::SHA256.hexdigest(contents)
      )
      artifact.file.attach(
        io: StringIO.new(contents),
        filename: upload.original_filename,
        content_type: upload.content_type
      )
      artifact.save!
    end
    redirect_to project
  end
end
