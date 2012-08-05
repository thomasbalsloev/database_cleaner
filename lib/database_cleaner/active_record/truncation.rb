require 'active_record/base'

require 'active_record/connection_adapters/abstract_adapter'

require 'active_record/connection_adapters/abstract_mysql_adapter' rescue LoadError

require "database_cleaner/generic/truncation"
require 'database_cleaner/active_record/base'

module DatabaseCleaner
  module ActiveRecord
      
    module AbstractAdapter
      # used to be called views but that can clash with gems like schema_plus
      # this gem is not meant to be exposing such an extra interface any way
      def database_cleaner_view_cache
        @views ||= select_values("select table_name from information_schema.views where table_schema = '#{current_database}'") rescue []
      end

      def database_cleaner_table_cache
        # the adapters don't do caching (#130) but we make the assumption that the list stays the same in tests
        @database_cleaner_tables ||= tables
      end

      def truncate_table(table_name)
        raise NotImplementedError
      end

      def truncate_tables(tables)
        tables.each do |table_name|
          self.truncate_table(table_name)
        end
      end
    end

    module MysqlAdapter
      
      def truncate_table(table_name)
        execute("TRUNCATE TABLE #{quote_table_name(table_name)};")
      end

      def fast_truncate_tables(*tables_and_opts)
        opts = tables_and_opts.last.is_a?(::Hash) ? tables_and_opts.pop : {}
        reset_ids = opts[:reset_ids] != false

        _tables = tables_and_opts.flatten

        _tables.each do |table_name|
          if reset_ids
            truncate_table_with_id_reset(table_name)
          else
            truncate_table_no_id_reset(table_name)
          end
        end
      end

      def truncate_table_with_id_reset(table_name)
        row_count = select_value("SELECT EXISTS(SELECT 1 FROM #{quote_table_name(table_name)} LIMIT 1)")

        if row_count.zero?
          auto_inc = select_value(<<-SQL) > 1
              SELECT Auto_increment 
              FROM information_schema.tables 
              WHERE table_name='#{table_name}';
          SQL

          truncate_table(table_name) if auto_inc
        else
          truncate_table(table_name)
        end
      end

      def truncate_table_no_id_reset(table_name)
        row_count = select_value("SELECT EXISTS (SELECT 1 FROM #{quote_table_name(table_name)} LIMIT 1)")
        truncate_table(table_name) unless row_count.zero?
      end
    end

    
    module IBM_DBAdapter
      def truncate_table(table_name)
        execute("TRUNCATE #{quote_table_name(table_name)} IMMEDIATE")
      end
    end

    
    module SQLiteAdapter
      def delete_table(table_name)
        execute("DELETE FROM #{quote_table_name(table_name)};")
        execute("DELETE FROM sqlite_sequence where name = '#{table_name}';")
      end
      alias truncate_table delete_table
    end

    module TruncateOrDelete
      def truncate_table(table_name)
        begin
          execute("TRUNCATE TABLE #{quote_table_name(table_name)};")
        rescue ActiveRecord::StatementInvalid
          execute("DELETE FROM #{quote_table_name(table_name)};")
        end
      end
    end

    module PostgreSQLAdapter
      def db_version
        @db_version ||= postgresql_version
      end

      def cascade
        @cascade ||= db_version >=  80200 ? 'CASCADE' : ''
      end

      def restart_identity
        @restart_identity ||= db_version >=  80400 ? 'RESTART IDENTITY' : ''
      end

      def truncate_table(table_name)
        truncate_tables([table_name])
      end

      def truncate_tables(table_names)
        return if table_names.nil? || table_names.empty?
        execute("TRUNCATE TABLE #{table_names.map{|name| quote_table_name(name)}.join(', ')} #{restart_identity} #{cascade};")
      end

      def fast_truncate_tables(tables, options = {:reset_ids => true})
        if options[:reset_ids]
          truncate_tables_with_id_reset(tables)
        else
          truncate_tables_no_id_reset(tables)
        end
      end

      def truncate_tables_with_id_reset(tables)
        to_truncate = tables.select do |table|
          cur_val = select_value("SELECT currval('#{table}_id_seq');").to_i rescue ActiveRecord::StatementInvalid
          cur_val && cur_val > 0
        end
        
        truncate_tables(to_truncate)
      end

      def truncate_tables_no_id_reset(tables)
        to_truncate = tables.select { |t| select_value("SELECT true FROM #{t} LIMIT 1;")}
        truncate_tables(to_truncate)
      end
    end

    module OracleEnhancedAdapter
      def truncate_table(table_name)
        execute("TRUNCATE TABLE #{quote_table_name(table_name)}")
      end
    end

  end
end

#TODO: Remove monkeypatching and decorate the connection instead!

module ActiveRecord
  module ConnectionAdapters
    # Activerecord-jdbc-adapter defines class dependencies a bit differently - if it is present, confirm to ArJdbc hierarchy to avoid 'superclass mismatch' errors.
    USE_ARJDBC_WORKAROUND = defined?(ArJdbc)

    class AbstractAdapter
      include ::DatabaseCleaner::ActiveRecord::AbstractAdapter
    end

    unless USE_ARJDBC_WORKAROUND
      class SQLiteAdapter < AbstractAdapter
      end
    end

    # ActiveRecord 3.1 support
    if defined?(AbstractMysqlAdapter)
      MYSQL_ADAPTER_PARENT = USE_ARJDBC_WORKAROUND ? JdbcAdapter : AbstractMysqlAdapter
      MYSQL2_ADAPTER_PARENT = AbstractMysqlAdapter
    else
      MYSQL_ADAPTER_PARENT = USE_ARJDBC_WORKAROUND ? JdbcAdapter : AbstractAdapter
      MYSQL2_ADAPTER_PARENT = AbstractAdapter
    end
    
    SQLITE_ADAPTER_PARENT = USE_ARJDBC_WORKAROUND ? JdbcAdapter : SQLiteAdapter
    POSTGRE_ADAPTER_PARENT = USE_ARJDBC_WORKAROUND ? JdbcAdapter : AbstractAdapter

    class MysqlAdapter < MYSQL_ADAPTER_PARENT
      include ::DatabaseCleaner::ActiveRecord::MysqlAdapter
    end

    class Mysql2Adapter < MYSQL2_ADAPTER_PARENT
      include ::DatabaseCleaner::ActiveRecord::MysqlAdapter
    end

    class IBM_DBAdapter < AbstractAdapter
      include ::DatabaseCleaner::ActiveRecord::IBM_DBAdapter
    end

    class SQLite3Adapter < SQLITE_ADAPTER_PARENT
      include ::DatabaseCleaner::ActiveRecord::SQLiteAdapter
    end

    class JdbcAdapter < AbstractAdapter
      include ::DatabaseCleaner::ActiveRecord::TruncateOrDelete
    end

    class PostgreSQLAdapter < POSTGRE_ADAPTER_PARENT
      include ::DatabaseCleaner::ActiveRecord::PostgreSQLAdapter
    end

    class SQLServerAdapter < AbstractAdapter
      include ::DatabaseCleaner::ActiveRecord::TruncateOrDelete
    end

    class OracleEnhancedAdapter < AbstractAdapter
      include ::DatabaseCleaner::ActiveRecord::OracleEnhancedAdapter
    end

  end
end


module DatabaseCleaner::ActiveRecord
  class Truncation
    include ::DatabaseCleaner::ActiveRecord::Base
    include ::DatabaseCleaner::Generic::Truncation

    def clean
      connection = connection_klass.connection
      connection.disable_referential_integrity do
        if fast? && connection.respond_to?(:fast_truncate_tables)
          connection.fast_truncate_tables(tables_to_truncate(connection), {:reset_ids => reset_ids?})
        else
          connection.truncate_tables(tables_to_truncate(connection))
        end
      end
    end

    private

    def tables_to_truncate(connection)
      (@only || connection.database_cleaner_table_cache) - @tables_to_exclude - connection.database_cleaner_view_cache
    end

    # overwritten
    def migration_storage_name
      'schema_migrations'
    end

    def fast?
      @fast == true
    end

    def reset_ids?
      @reset_ids != false
    end
  end
end
