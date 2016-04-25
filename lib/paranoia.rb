require 'active_record' unless defined? ActiveRecord

require 'paranoia/acts_as_paranoid'
require 'paranoia/paranoiable'
require 'paranoia/uniqueness_paranoia_validator'
require 'paranoia/schizify'

module Paranoia
  def self.included(klazz)
    klazz.include Paranoiable
  end
end

class ActiveRecord::Base
  include Paranoia
end

require 'paranoia/rspec' if defined? RSpec

module ActiveRecord
  module Validations
    class UniquenessValidator < ActiveModel::EachValidator
      prepend Paranoia::UniquenessParanoiaValidator
    end
  end
end
