class AuditEvent < ApplicationRecord
  belongs_to :project
  belongs_to :user, optional: true

  validates :action, presence: true
end
