abort("browser setup requires the test environment") unless Rails.env.test?

User.create!(
  email: "browser@example.com",
  name: "Browser Runner",
  password: "benchmark-password"
)
