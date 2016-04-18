# Module grants AR models the ability to determine if they are paranoid
# and to become paranoid if they fit the necessary requirements.

module Paranoia
  module Paranoiable

    def self.included(klazz)
      class << klazz
        attr_accessor :already_checked_for_paranoid_eligibility, :paranoid
        prepend ClassMethods # To get access to super() methods in connection/remove_connection
      end  

      # Define callbacks that may be used with paranoia,
      # need to do this even if model turns out not to be paranoid,
      # as they may still try to define these callbacks, but we won't know if they
      # are eligible for paranoia until after the callbacks havebeen evaluated and a connection
      # has been opened so that we can check for needed columns. So these callbacks must exist
      # in advance of true acts_as_paranoid.
      [:restore].each do |callback_name|
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

    def paranoid? ; self.class.paranoid? ; end

    module ClassMethods
      def acts_as_not_paranoid
        self.paranoid = false
      end

      def paranoid?
        !!paranoid
      end

      def connection(*args)
        self.setup_paranoid if has_a_right_to_be_paranoid?

        self.already_checked_for_paranoid_eligibility = true
        super(*args)
      end

      def remove_connection(*args)
        # New connection may have necessary columns.
        self.already_checked_for_paranoid_eligibility = false
        super(*args)
      end

      def has_a_right_to_be_paranoid?
        conn = method(:connection).super_method.call

        !already_checked_for_paranoid_eligibility and # Havent already checked
          paranoid != false and # I haven't explicitly said at top of my class I want to ignore paranoia
          ENV['PARANOIA_ENABLED'] == 'true' and # System has paranoia enabled
          (ancestors - [self]).include?(ActiveRecord::Base) and # I am an AR Model
          ENV['PARANOIA_BLACKLIST'].try(:match, /(^|,)#{table_name}(,|\z)/).nil? and # I am not part of ENV blacklist (loans,loan_tasks,...)
          conn.table_exists?(table_name) and # Table exists
          conn.column_exists?(table_name, :deleted_at) and # I have deleted_at 
          conn.column_exists?(table_name, :deleted) # I have deleted column
      end

      def setup_paranoid
        include Paranoia::ActsAsParanoid
      end
    end
  end
end