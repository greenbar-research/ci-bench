require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "signs in with a normalized email and signs out" do
    User.create!(
      email: "runner@example.com",
      name: "Runner",
      password: "benchmark-password"
    )

    post session_path, params: {
      email: "runner@example.com",
      password: "benchmark-password"
    }

    assert_redirected_to projects_path
    follow_redirect!
    assert_select "nav", text: /Signed in as runner@example.com/

    delete session_path
    follow_redirect!
    assert_select "a", "Sign in"
  end

  test "rejects invalid credentials" do
    post session_path, params: {
      email: "missing@example.com",
      password: "wrong-password"
    }

    assert_response :unprocessable_entity
    assert_select "[role=alert]", "Invalid email or password"
  end
end
