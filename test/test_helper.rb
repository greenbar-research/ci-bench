ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
    def with_failing_audit_events
      original_create = AuditEvent.method(:create!)
      AuditEvent.define_singleton_method(:create!) { |*| raise ActiveRecord::RecordInvalid }
      yield
    ensure
      AuditEvent.define_singleton_method(:create!, original_create)
    end
  end
end
