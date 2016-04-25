module Paranoia
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
end