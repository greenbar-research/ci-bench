class TestCase < ApplicationRecord
  STATES = %w[passed failed skipped].freeze

  belongs_to :build

  validates :duration_ms, numericality: { greater_than_or_equal_to: 0 }
  validates :name, presence: true
  validates :state, inclusion: { in: STATES }
end
