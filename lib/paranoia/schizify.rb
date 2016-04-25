module Paranoia
  module Schizify

    def self.add(tables = nil)
      con = ActiveRecord::Base.connection

      postfix = "_v"

      if tables.present?
        tables = tables.split(",")
        extra = "and t.table_name in ('#{tables.join("','")}')"
      else
        extra = ""
      end

      tables_and_keys = con.execute(%Q{
        select tc.table_schema, tc.table_name, kc.column_name
        from 
            information_schema.table_constraints tc
            join information_schema.key_column_usage kc 
                on kc.table_name = tc.table_name and kc.table_schema = tc.table_schema
            join information_schema.tables t 
                on t.table_name = kc.table_name and t.table_schema = kc.table_schema
        where 
            tc.constraint_type = 'PRIMARY KEY'
            and kc.position_in_unique_constraint is null
            and t.table_schema = 'public' and (select exists(select 1 from information_schema.columns where table_name = t.table_name and column_name = 'deleted')) = false
            and (t.table_type = 'BASE_TABLE' or t.table_type = 'BASE TABLE')
            #{extra}
        order by tc.table_schema,
                 tc.table_name,
                 kc.position_in_unique_constraint;
      })

      tables_and_keys.each do |row|
        t = row["table_name"]

        next if ENV['PARANOIA_BLACKLIST'].try(:split, ",").try(:include?, t) # Special tables we cant viewify

        key = row["column_name"]

        # Execute in a single transaction
        con.execute(%Q{
          BEGIN;

          -- Rename table and add relevant columns

          ALTER TABLE #{t} ADD COLUMN deleted BOOLEAN NOT NULL DEFAULT FALSE;
          ALTER TABLE #{t} ADD COLUMN deleted_at TIMESTAMP DEFAULT NULL;
          CREATE INDEX #{t}_deleted ON #{t} (deleted);
          
          -- Create view to represent table

          CREATE OR REPLACE VIEW #{t}#{postfix} AS SELECT * FROM #{t} where deleted = false;

          CREATE OR REPLACE RULE set_deleted_on_#{t} AS  ON DELETE TO #{t}
          DO INSTEAD 
          UPDATE #{t} SET deleted = true, deleted_at = NOW() WHERE #{key} = OLD.#{key};

          END;
        })
      end
    end

    def self.revert(tables = nil)
      postfix = "_v"

      con = ActiveRecord::Base.connection

      if tables.present?
        tables = tables.split(",")
      else
        # All
        tables = con.execute(%Q{
          SELECT table_name FROM information_schema.tables t
          WHERE t.table_schema = 'public' and 
          (select exists(select 1 from information_schema.columns where table_name = t.table_name and column_name = 'deleted')) = true
          AND (t.table_type = 'BASE_TABLE' OR t.table_type = 'BASE TABLE')
        }).map { |t| t["table_name"] }
      end

      tables.each do |t|
        # Execute in a single transaction
        con.execute(%Q{
          BEGIN;

          DROP VIEW #{t}#{postfix};

          ALTER TABLE #{t} DROP COLUMN deleted CASCADE;
          ALTER TABLE #{t} DROP COLUMN deleted_at;

          END;
        })
      end
    end
  end
end