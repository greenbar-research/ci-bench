require "digest"
require "json"

output_path = ENV.fetch("BENCH_OUTPUT")
parameters = JSON.parse(ENV.fetch("BENCH_PARAMS"))
seed = Integer(ENV.fetch("BENCH_SEED"))
now = Time.utc(2026, 1, 1)

ActiveStorage::Attachment.delete_all
ActiveStorage::Blob.delete_all
Artifact.delete_all
TestCase.delete_all
AuditEvent.delete_all
Build.delete_all
Project.delete_all

projects = parameters.fetch("project_count").times.map do |index|
  { name: format("project-%03d", index), created_at: now, updated_at: now }
end
Project.insert_all!(projects)

builds = Project.order(:name).flat_map.with_index do |project, project_index|
  parameters.fetch("builds_per_project").times.map do |build_index|
    {
      project_id: project.id,
      number: build_index + 1,
      commit_sha: Digest::SHA1.hexdigest("#{seed}:#{project_index}:#{build_index}"),
      state: build_index == 3 ? "failed" : "passed",
      duration_ms: ((project_index + 1) * (build_index + 3)) % 90_000,
      created_at: now,
      updated_at: now
    }
  end
end
Build.insert_all!(builds)

summary = {
  project_count: Project.count,
  build_count: Build.count,
  passed_count: Build.where(state: "passed").count,
  failed_count: Build.where(state: "failed").count,
  duration_ms: Build.sum(:duration_ms)
}
File.write(
  output_path,
  JSON.generate("verification" => summary, "telemetry" => {}) << "\n"
)
