class Artifact < ApplicationRecord
  belongs_to :build
  has_one_attached :file

  validates :byte_size, numericality: { greater_than_or_equal_to: 0 }
  validates :checksum, :name, presence: true
end
