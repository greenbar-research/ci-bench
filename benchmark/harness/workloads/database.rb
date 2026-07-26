require "digest"
require "json"

output_path = ENV.fetch("BENCH_OUTPUT")
now = Time.utc(2026, 1, 1)

Build.delete_all
Project.delete_all

projects = 120.times.map do |index|
  { name: format("project-%03d", index), created_at: now, updated_at: now }
end
Project.insert_all!(projects)

builds = Project.order(:name).flat_map.with_index do |project, project_index|
  4.times.map do |build_index|
    {
      project_id: project.id,
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
summary[:digest] = Digest::SHA256.hexdigest(JSON.generate(summary))

File.write(output_path, JSON.generate(summary) << "\n")
