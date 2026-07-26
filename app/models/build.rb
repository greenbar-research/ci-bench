class Build < ApplicationRecord
  STATES = %w[passed failed].freeze

  belongs_to :project
  has_many :test_cases, dependent: :delete_all
  has_many :artifacts, dependent: :destroy

  validates :duration_ms, numericality: { greater_than_or_equal_to: 0 }
  validates :number,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 },
    uniqueness: { scope: :project_id }
  validates :commit_sha, format: { with: /\A\h{40}\z/ }
  validates :retry_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :state, inclusion: { in: STATES }
end
