module Paranoia
  module ActsAsParanoid

    def self.included(klazz)
      klazz.class_eval do
        extend ClassMethods

        class_attribute :paranoia_column, :paranoia_sentinel_value, :paranoia_timestamp_column

        self.paranoia_column = :deleted
        self.paranoia_timestamp_column = :deleted_at
        self.paranoia_sentinel_value = false
        self.paranoid = true

        before_restore {
          self.class.notify_observers(:before_restore, self) if self.class.respond_to?(:notify_observers)
        }

        after_restore {
          self.class.notify_observers(:after_restore, self) if self.class.respond_to?(:notify_observers)
        }

        default_scope { paranoia_scope }
      end

      # hack to allow mass assignment of these fields when necessary
      klazz.attr_accessible(:deleted, :deleted_at) if klazz.respond_to?(:attr_accessible)

      class << klazz
        alias_method :without_deleted, :paranoia_scope 
      end
    end

    module ClassMethods
      def paranoia_scope
        where(paranoia_column => paranoia_sentinel_value)
      end

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

    def destroy
      transaction do
        run_callbacks(:destroy) do
          each_counter_cached_associations do |association|
            foreign_key = association.reflection.foreign_key.to_sym
            next if destroyed_by_association && destroyed_by_association.foreign_key.to_sym == foreign_key
            next unless send(association.reflection.name)
            association.decrement_counters
          end
          delete
        end
      end
    end

    def delete
      raise ActiveRecord::ReadOnlyRecord, "#{self.class} is marked as readonly" if readonly?
      if persisted?
        # if a transaction exists, add the record so that after_commit
        # callbacks can be run
        add_to_transaction

        # When actual delete is called, deleted will be set to true and deleted_at set to now()
        # by the DB. Instead of reloading to get that info, we're going to set it to true/Time.now
        # here so that the deleted flag is true for the object in memory and it has a (close, practically same) timestamp
        # as what is on DB.
        assign_attributes(paranoia_destroy_attributes)
      elsif !frozen?
        assign_attributes(paranoia_destroy_attributes)
      end
      super
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