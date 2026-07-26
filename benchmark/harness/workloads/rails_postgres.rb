require "digest"
require "json"

output_path = ENV.fetch("BENCH_OUTPUT")
parameters = JSON.parse(ENV.fetch("BENCH_PARAMS"))
seed = Integer(ENV.fetch("BENCH_SEED"))
fixed_time = Time.utc(2026, 1, 1)
phase_durations = {}

positive_parameters = %w[
  user_count
  project_count
  builds_per_project
  test_cases_per_build
  insert_batch_size
  concurrency_threads
  concurrent_updates_per_thread
  contention_build_count
  report_iterations
]
unless positive_parameters.all? { |name| parameters.fetch(name).positive? } &&
    parameters.fetch("orm_write_count") >= 0
  raise "rails-postgres workload parameters must be positive, except orm_write_count may be zero"
end

measure = lambda do |name, &block|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  block.call
ensure
  phase_durations[name] = (
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
  ).round
end

insert_batches = lambda do |model, rows|
  rows.each_slice(parameters.fetch("insert_batch_size")) { |batch| model.insert_all!(batch) }
end

database_models = [
  User,
  Project,
  Build,
  TestCase,
  Artifact,
  AuditEvent,
  ActiveStorage::Attachment,
  ActiveStorage::Blob
]
unless database_models.all? { |model| model.count.zero? }
  raise "rails-postgres workload requires an empty database"
end

measure.call("fixtures") do
  password_digest = BCrypt::Engine.hash_secret(
    "benchmark-password",
    "$2a$04$abcdefghijklmnopqrstuu"
  )
  users = parameters.fetch("user_count").times.map do |index|
    {
      email: format("runner-%08d@example.test", index),
      name: format("Runner %08d", index),
      password_digest: password_digest,
      created_at: fixed_time,
      updated_at: fixed_time
    }
  end
  insert_batches.call(User, users)

  user_ids = User.order(:id).pluck(:id)
  projects = parameters.fetch("project_count").times.map do |index|
    {
      name: format("project-%08d", index),
      owner_id: user_ids.fetch(index % user_ids.length),
      created_at: fixed_time,
      updated_at: fixed_time
    }
  end
  insert_batches.call(Project, projects)

  project_ids = Project.order(:id).pluck(:id)
  builds = Enumerator.new do |rows|
    project_ids.each_with_index do |project_id, project_index|
      parameters.fetch("builds_per_project").times do |build_index|
        rows << {
          project_id: project_id,
          number: build_index + 1,
          commit_sha: Digest::SHA1.hexdigest("#{seed}:#{project_index}:#{build_index}"),
          state: (project_index + build_index) % 5 == 0 ? "failed" : "passed",
          duration_ms: ((project_index + 1) * (build_index + 7) * 37) % 90_000,
          retry_count: 0,
          created_at: fixed_time,
          updated_at: fixed_time
        }
      end
    end
  end
  insert_batches.call(Build, builds)

  build_index = 0
  Build.in_batches(of: parameters.fetch("insert_batch_size"), order: :asc) do |build_batch|
    test_cases = Enumerator.new do |rows|
      build_batch.order(:id).pluck(:id, :number).each do |build_id, build_number|
        parameters.fetch("test_cases_per_build").times do |test_index|
          state_selector = (build_index + test_index) % 10
          rows << {
            build_id: build_id,
            name: format("spec/%08d/example-%08d", build_index, test_index),
            state: state_selector.zero? ? "failed" : (state_selector == 1 ? "skipped" : "passed"),
            duration_ms: ((build_number + 3) * (test_index + 11) * 13) % 5_000,
            created_at: fixed_time,
            updated_at: fixed_time
          }
        end
        build_index += 1
      end
    end
    insert_batches.call(TestCase, test_cases)
  end

  audit_events = project_ids.map.with_index do |project_id, index|
    {
      project_id: project_id,
      user_id: user_ids.fetch(index % user_ids.length),
      action: "fixture.project_created",
      metadata: { seed: seed },
      created_at: fixed_time,
      updated_at: fixed_time
    }
  end
  insert_batches.call(AuditEvent, audit_events)
end

measure.call("orm_transactions") do
  if parameters.fetch("orm_write_count") > Build.count
    raise "orm_write_count exceeds the generated build count"
  end

  Build.limit(parameters.fetch("orm_write_count")).find_each do |build|
    build.transaction do
      build.increment!(:retry_count)
      AuditEvent.create!(
        project_id: build.project_id,
        action: "fixture.build_retried",
        metadata: { build_id: build.id },
        created_at: fixed_time,
        updated_at: fixed_time
      )
    end
  end
end

build_ids = nil
measure.call("concurrent_updates") do
  thread_count = parameters.fetch("concurrency_threads")
  if ActiveRecord::Base.connection_pool.size < thread_count + 1
    raise "database pool must provide one connection per worker plus the main thread"
  end

  build_count = Build.count
  contention_count = parameters.fetch("contention_build_count")
  raise "contention_build_count exceeds the generated build count" if contention_count > build_count

  first_build_id = Build.minimum(:id)
  build_ids = contention_count.times.map do |index|
    offset = contention_count == 1 ? 0 : (index * (build_count - 1)) / (contention_count - 1)
    first_build_id + offset
  end
  threads = parameters.fetch("concurrency_threads").times.map do |thread_index|
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        parameters.fetch("concurrent_updates_per_thread").times do |operation|
          build_id = build_ids.fetch((thread_index + operation) % build_ids.length)
          Build.where(id: build_id).update_all("retry_count = retry_count + 1")
        end
      end
    end
  end
  threads.each(&:value)
end

project_report = nil
test_report = nil
measure.call("reports") do
  parameters.fetch("report_iterations").times do
    current_project_report = Project
      .joins(:builds)
      .group(:id, :name)
      .order(:id)
      .pluck(
        :name,
        Arel.sql("COUNT(builds.id)"),
        Arel.sql("SUM(builds.duration_ms)"),
        Arel.sql("SUM(builds.retry_count)")
      )
    current_test_report = TestCase
      .group(:state)
      .order(:state)
      .pluck(:state, Arel.sql("COUNT(*)"), Arel.sql("SUM(duration_ms)"))

    project_report ||= current_project_report
    test_report ||= current_test_report
    raise "project report changed between iterations" unless current_project_report == project_report
    raise "test report changed between iterations" unless current_test_report == test_report
  end
end

verification = {
  users: User.count,
  projects: Project.count,
  builds: Build.count,
  test_cases: TestCase.count,
  audit_events: AuditEvent.count,
  passed_builds: Build.where(state: "passed").count,
  failed_builds: Build.where(state: "failed").count,
  passed_tests: TestCase.where(state: "passed").count,
  failed_tests: TestCase.where(state: "failed").count,
  skipped_tests: TestCase.where(state: "skipped").count,
  build_duration_ms: Build.sum(:duration_ms),
  test_duration_ms: TestCase.sum(:duration_ms),
  retry_count_sum: Build.sum(:retry_count),
  report_iterations: parameters.fetch("report_iterations"),
  commit_sha_digest: Digest::SHA256.hexdigest(JSON.generate(Build.order(:id).pluck(:commit_sha))),
  retry_distribution_digest: Digest::SHA256.hexdigest(
    JSON.generate(Build.where(id: build_ids).order(:id).pluck(:id, :retry_count))
  ),
  project_report_digest: Digest::SHA256.hexdigest(JSON.generate(project_report)),
  test_report_digest: Digest::SHA256.hexdigest(JSON.generate(test_report))
}

postgres_database_bytes = ActiveRecord::Base.connection.select_value(
  "SELECT pg_database_size(current_database())"
).to_i
File.write(
  output_path,
  JSON.generate(
    "verification" => verification,
    "telemetry" => {
      "phase_duration_ms" => phase_durations,
      "postgres_database_bytes" => postgres_database_bytes,
      "peak_benchmark_disk_bytes" => postgres_database_bytes
    }
  ) << "\n"
)
