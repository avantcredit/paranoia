require 'active_record' unless defined? ActiveRecord

module Paranoia

  def self.included(klazz)
    klazz.extend Query
    klazz.extend Callbacks
  end

  module Query
    def with_deleted
      if ActiveRecord::VERSION::STRING >= "4.1"
        return unscope where: paranoia_column
      end
      all.tap { |x| x.default_scoped = false }
    end

    def only_deleted
      if paranoia_sentinel_value.nil?
        return with_deleted.where.not(paranoia_column => paranoia_sentinel_value)
      end
      # if paranoia_sentinel_value is not null, then it is possible that
      # some deleted rows will hold a null value in the paranoia column
      # these will not match != sentinel value because "NULL != value" is
      # NULL under the sql standard
      quoted_paranoia_column = connection.quote_column_name(paranoia_column)
      with_deleted.where("#{quoted_paranoia_column} IS NULL OR #{quoted_paranoia_column} != ?", paranoia_sentinel_value)
    end
    alias_method :deleted, :only_deleted

    def restore(id_or_ids, opts = {})
      ids = Array(id_or_ids).flatten
      any_object_instead_of_id = ids.any? { |id| ActiveRecord::Base === id }
      if any_object_instead_of_id
        ids.map! { |id| ActiveRecord::Base === id ? id.id : id }
        ActiveSupport::Deprecation.warn("You are passing an instance of ActiveRecord::Base to `restore`. " \
                                        "Please pass the id of the object by calling `.id`")
      end
      ids.map { |id| only_deleted.find(id).restore!(opts) }
    end
  end

  module Callbacks
    def self.add_callbacks_to(klazz)
      [:restore, :real_destroy].each do |callback_name|
        klazz.define_callbacks callback_name

        klazz.define_singleton_method("before_#{callback_name}") do |*args, &block|
          set_callback(callback_name, :before, *args, &block)
        end

        klazz.define_singleton_method("around_#{callback_name}") do |*args, &block|
          set_callback(callback_name, :around, *args, &block)
        end

        klazz.define_singleton_method("after_#{callback_name}") do |*args, &block|
          set_callback(callback_name, :after, *args, &block)
        end
      end
    end
  end

  def destroy
    transaction do
      run_callbacks(:destroy) do
        result = delete
        next result unless result && ActiveRecord::VERSION::STRING >= '4.2'
        each_counter_cached_associations do |association|
          foreign_key = association.reflection.foreign_key.to_sym
          next if destroyed_by_association && destroyed_by_association.foreign_key.to_sym == foreign_key
          next unless send(association.reflection.name)
          association.decrement_counters
        end
        result
      end
    end
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord, "#{self.class} is marked as readonly" if readonly?
    if persisted?
      # if a transaction exists, add the record so that after_commit
      # callbacks can be run
      add_to_transaction
      update_columns(paranoia_destroy_attributes)
    elsif !frozen?
      assign_attributes(paranoia_destroy_attributes)
    end
    self
  end

  def restore!(opts = {})
    self.class.transaction do
      run_callbacks(:restore) do
        # Fixes a bug where the build would error because attributes were frozen.
        # This only happened on Rails versions earlier than 4.1.
        noop_if_frozen = ActiveRecord.version < Gem::Version.new("4.1")
        if (noop_if_frozen && !@attributes.frozen?) || !noop_if_frozen
          write_attribute paranoia_column, paranoia_sentinel_value
          write_attribute paranoia_timestamp_column, nil

          update_columns(paranoia_restore_attributes)
          touch
        end
        restore_associated_records if opts[:recursive]
      end
    end

    self
  end
  alias :restore :restore!

  def paranoia_destroyed?
    send(paranoia_column) != paranoia_sentinel_value
  end
  alias :deleted? :paranoia_destroyed?

  def really_destroy!
    transaction do
      run_callbacks(:real_destroy) do
        dependent_reflections = self.class.reflections.select do |name, reflection|
          reflection.options[:dependent] == :destroy
        end
        if dependent_reflections.any?
          dependent_reflections.each do |name, reflection|
            association_data = self.send(name)
            # has_one association can return nil
            # .paranoid? will work for both instances and classes
            next unless association_data && association_data.paranoid?
            if reflection.collection?
              next association_data.with_deleted.each(&:really_destroy!)
            end
            association_data.really_destroy!
          end
        end
        write_attribute(paranoia_timestamp_column, current_time_from_proper_timezone)
        write_attribute(paranoia_column, !paranoia_sentinel_value)

        destroy_without_paranoia
      end
    end
  end

  private

  def paranoia_restore_attributes
    {
      paranoia_column => paranoia_sentinel_value,
      paranoia_timestamp_column => nil
    }
  end

  def paranoia_destroy_attributes
    {
      paranoia_column => !paranoia_sentinel_value,
      paranoia_timestamp_column => current_time_from_proper_timezone
    }
  end

  # restore associated records that have been soft deleted when
  # we called #destroy
  def restore_associated_records
    destroyed_associations = self.class.reflect_on_all_associations.select do |association|
      association.options[:dependent] == :destroy
    end

    destroyed_associations.each do |association|
      association_data = send(association.name)

      unless association_data.nil?
        if association_data.paranoid?
          if association.collection?
            association_data.only_deleted.each { |record| record.restore(:recursive => true) }
          else
            association_data.restore(:recursive => true)
          end
        end
      end

      if association_data.nil? && association.macro.to_s == "has_one"
        association_class_name = association.klass.name
        association_foreign_key = association.foreign_key

        if association.type
          association_polymorphic_type = association.type
          association_find_conditions = { association_polymorphic_type => self.class.name.to_s, association_foreign_key => self.id }
        else
          association_find_conditions = { association_foreign_key => self.id }
        end

        association_class = association_class_name.constantize
        if association_class.paranoid?
          association_class.only_deleted.where(association_find_conditions).first.try!(:restore, recursive: true)
        end
      end
    end

    clear_association_cache if destroyed_associations.present?
  end
end

class Class
  def extend?(klass)
    not superclass.nil? and ( superclass == klass or superclass.extend? klass )
  end
end

class ActiveRecord::Base
  class << self
    alias_method :original_connection, :connection
    alias_method :original_remove_connection, :remove_connection
    alias_method :original_inherited, :inherited
    attr_accessor :already_checked_for_paranoid_eligibility, :paranoid
  end

  def self.acts_as_not_paranoid
    self.paranoid = false
  end

  def self.paranoid? ; !!paranoid ; end
  def paranoid? ; self.class.paranoid? ; end

  def self.connection(opts = {})
    self.setup_paranoid if has_a_right_to_be_paranoid?
    
    self.already_checked_for_paranoid_eligibility = true
    original_connection
  end

  def self.has_a_right_to_be_paranoid?
      !already_checked_for_paranoid_eligibility and # Havent already checked
        paranoid != false and # I haven't explicitly said at top of my class I want to ignore paranoia
        ENV['PARANOIA_ENABLED'] == 'true' and # System has paranoia enabled
        extend?(ActiveRecord::Base) and # I am an AR Model
        ENV['PARANOIA_BLACKLIST'].try(:match, /(^|,)#{table_name}(,|\z)/).nil? and # I am not part of ENV blacklist (loans,loan_tasks,...)
        original_connection.table_exists?(table_name) and # Table exists
        original_connection.column_exists?(table_name, :deleted_at) and # I have deleted_at 
        original_connection.column_exists?(table_name, :deleted) # I have deleted column
  end

  def self.remove_connection(*args)
    # New connection may have necessary columns.
    self.already_checked_for_paranoid_eligibility = false
    original_remove_connection(*args)
  end

  def self.inherited(subclass)
    # To setup the restore/real_destroy callbacks in advance of connecting but before classes get defined,
    # only get used if subclass is eligible after columnar check in self.connection.
    Paranoia::Callbacks.add_callbacks_to(subclass)

    original_inherited(subclass)
  end

  def self.setup_paranoid
    class_attribute :paranoia_column, :paranoia_sentinel_value, :paranoia_timestamp_column

    alias_method :really_destroyed?, :destroyed?
    alias_method :really_delete, :delete
    alias_method :destroy_without_paranoia, :destroy

    include Paranoia

    self.paranoia_column = :deleted
    self.paranoia_timestamp_column = :deleted_at
    self.paranoia_sentinel_value = false
    self.paranoid = true

    def self.paranoia_scope
      where(paranoia_column => paranoia_sentinel_value)
    end

    default_scope { paranoia_scope }

    class << self; alias_method :without_deleted, :paranoia_scope end

    before_restore {
      self.class.notify_observers(:before_restore, self) if self.class.respond_to?(:notify_observers)
    }

    after_restore {
      self.class.notify_observers(:after_restore, self) if self.class.respond_to?(:notify_observers)
    }

    private

    def paranoia_column
      self.class.paranoia_column
    end

    def paranoia_timestamp_column
      self.class.paranoia_timestamp_column
    end

    def paranoia_sentinel_value
      self.class.paranoia_sentinel_value
    end
  end
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
