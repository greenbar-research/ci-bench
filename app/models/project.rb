class Project < ApplicationRecord
  belongs_to :owner, class_name: "User", optional: true
  has_many :builds, dependent: :destroy
  has_many :audit_events, dependent: :delete_all

  validates :name, presence: true, uniqueness: true
end
