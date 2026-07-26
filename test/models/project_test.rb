require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "requires a unique name" do
    Project.create!(name: "same-name")

    duplicate = Project.new(name: "same-name")

    assert_not duplicate.valid?
    assert duplicate.errors.added?(:name, :taken, value: "same-name")
  end
end
