abort("refusing to reset the #{Rails.env} database") unless Rails.env.test?

connection = ActiveRecord::Base.connection
tables = connection.tables - %w[ar_internal_metadata schema_migrations]
quoted_tables = tables.sort.map { |table| connection.quote_table_name(table) }

connection.execute("TRUNCATE TABLE #{quoted_tables.join(", ")} RESTART IDENTITY CASCADE") if quoted_tables.any?
