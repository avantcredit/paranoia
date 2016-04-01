require 'active_record' unless defined? ActiveRecord

require 'paranoia/acts_as_paranoid'
require 'paranoia/paranoiable'

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
    module UniquenessParanoiaValidator
      def build_relation(klass, table, attribute, value)
        relation = super(klass, table, attribute, value)

        return relation unless klass.paranoid?

        arel_paranoia_scope = klass.arel_table[klass.paranoia_column].eq(klass.paranoia_sentinel_value)
        if ActiveRecord::VERSION::STRING >= "5.0"
          relation.where(arel_paranoia_scope)
        else
          relation.and(arel_paranoia_scope)
        end
      end
    end

    class UniquenessValidator < ActiveModel::EachValidator
      prepend UniquenessParanoiaValidator
    end
  end
end
