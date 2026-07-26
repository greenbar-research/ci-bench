require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "normalizes email before authentication" do
    user = User.create!(
      email: "  Runner@Example.COM ",
      name: "Runner",
      password: "benchmark-password"
    )

    assert_equal "runner@example.com", user.email
    assert_equal user, User.authenticate_by(
      email: "runner@example.com",
      password: "benchmark-password"
    )
  end
end
