class Build < ApplicationRecord
  belongs_to :project

  validates :duration_ms, numericality: { greater_than_or_equal_to: 0 }
  validates :state, inclusion: { in: %w[passed failed] }
end
