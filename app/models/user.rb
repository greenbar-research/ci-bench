class User < ApplicationRecord
  has_secure_password

  has_many :projects, foreign_key: :owner_id, inverse_of: :owner, dependent: :nullify
  has_many :audit_events, dependent: :nullify

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: true
  validates :name, presence: true
end
