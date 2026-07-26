class Project < ApplicationRecord
  has_many :builds, dependent: :delete_all

  validates :name, presence: true, uniqueness: true
end
