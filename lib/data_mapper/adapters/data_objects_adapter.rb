require __DIR__ + 'abstract_adapter'

module DataMapper

  module Adapters

    # You must inherit from the DoAdapter, and implement the
    # required methods to adapt a database library for use with the DataMapper.
    #
    # NOTE: By inheriting from DataObjectsAdapter, you get a copy of all the
    # standard sub-modules (Quoting, Coersion and Queries) in your own Adapter.
    # You can extend and overwrite these copies without affecting the originals.
    class DataObjectsAdapter < AbstractAdapter

      def self.inherited(target)
        target.const_set('TYPES', TYPES.dup)
      end
      
      TYPES = {
        Fixnum  => 'int'.freeze,
        String   => 'varchar'.freeze,
        Text     => 'text'.freeze,
        Class    => 'varchar'.freeze,
        BigDecimal  => 'decimal'.freeze,
        Float    => 'float'.freeze,
        DateTime => 'datetime'.freeze,
        Date     => 'date'.freeze,
        TrueClass  => 'boolean'.freeze,
        Object   => 'text'.freeze
      }
      
      def transaction(&block)
        raise NotImplementedError.new
      end
      
      # all of our CRUD
      # Methods dealing with a single instance object
      def create(repository, instance)
        dirty_attributes = instance.dirty_attributes
        properties = instance.class.properties(name).select { |property| dirty_attributes.key?(property.name) }
        
        connection = create_connection
        command = connection.create_command(create_statement(instance.class, properties))
        
        values = properties.map { |property| dirty_attributes[property.name] }
        result = command.execute_non_query(*values)

        connection.close
        
        if result.to_i == 1
          key = instance.class.key(name)
          if key.size == 1 && key.first.serial?
            instance.instance_variable_set(key.first.instance_variable_name, result.insert_id)
          end
          true
        else
          false
        end
      end
      
      def read(repository, resource, key)
        properties = resource.properties(repository.name).select { |property| !property.lazy? }
        properties_with_indexes = Hash[*properties.zip((0...properties.size).to_a).flatten]

        set = LoadedSet.new(repository, resource, properties_with_indexes)
        
        connection = create_connection
        command = connection.create_command(read_statement(resource, key))
        command.set_types(properties.map { |property| property.type })
        reader = command.execute_reader(*key)
        while(reader.next!)
          set.materialize!(reader.values)
        end
        
        reader.close
        connection.close
        
        set.to_a.first
      end
      
      def update(repository, instance)
        dirty_attributes = instance.dirty_attributes
        properties = instance.class.properties(name).select { |property| dirty_attributes.key?(property.name) }
        
        connection = create_connection
        command = connection.create_command(update_statement(instance.class, properties))
        
        values = properties.map { |property| dirty_attributes[property.name] }
        result = command.execute_non_query(*values)

        connection.close

        result.to_i == 1
      end
      
      def delete(repository, instance)
        connection = create_connection
        command = connection.create_command(delete_statement(instance.class))
        
        key = instance.class.key(name).map { |property| instance.instance_variable_get(property.instance_variable_name) }
        result = command.execute_non_query(*key)

        connection.close

        result.to_i == 1
      end

      # Methods dealing with locating a single object, by keys
      def read_one(repository, klass, *keys)
        raise NotImplementedError.new
      end

      def delete_one(repository, klass, *keys)
        raise NotImplementedError.new
      end

      # Methods dealing with finding stuff by some query parameters
      def read_set(repository, klass, query = {})
        raise NotImplementedError.new
      end

      def delete_set(repository, klass, query = {})
        raise NotImplementedError.new
      end

      # Database-specific method
      def execute(*args)
        db = create_connection
        command = db.create_command(args.shift)
        return command.execute_non_query(*args)
      rescue => e
        DataMapper.logger.error { e } if DataMapper.logger
        raise e
      ensure
        db.close if db
      end

      def query(*args)
        db = create_connection

        command = db.create_command(args.shift)

        reader = command.execute_reader(*args)
        results = []

        if (fields = reader.fields).size > 1
          fields = fields.map { |field| Inflector.underscore(field).to_sym }
          struct = Struct.new(*fields)

          while(reader.next!) do
            results << struct.new(*reader.values)
          end
        else
          while(reader.next!) do
            results << reader.values[0]
          end
        end

        return results
      rescue => e
        DataMapper.logger.error { e } if DataMapper.logger
        raise e
      ensure
        reader.close if reader
        db.close if db
      end

      # def delete(database_context, instance)
      #   table = self.table(instance)
      # 
      #   if instance.is_a?(Class)
      #     table.delete_all!
      #   else
      #     callback(instance, :before_destroy)
      # 
      #     table.associations.each do |association|
      #       instance.send(association.name).deactivate unless association.is_a?(::DataMapper::Associations::BelongsToAssociation)
      #     end
      # 
      #     if table.paranoid?
      #       instance.instance_variable_set(table.paranoid_column.instance_variable_name, Time::now)
      #       instance.save
      #     else
      #       if connection do |db|
      #           command = db.create_command("DELETE FROM #{table.to_sql} WHERE #{table.key.to_sql} = ?")
      #           command.execute_non_query(instance.key).to_i > 0
      #         end # connection do...end # if continued below:
      #         instance.instance_variable_set(:@new_record, true)
      #         instance.database_context = database_context
      #         instance.original_values.clear
      #         database_context.identity_map.delete(instance)
      #         callback(instance, :after_destroy)
      #       end
      #     end
      #   end
      # end

      def empty_insert_sql
        "DEFAULT VALUES"
      end

      # This model is just for organization. The methods are included into the Adapter below.
      module SQL
        def create_statement(resource, properties)
          <<-EOS.compress_lines
            INSERT INTO #{quote_table_name(resource.resource_name(name))}
            (#{properties.map { |property| quote_column_name(property.field) }.join(', ')})
            VALUES
            (#{(['?'] * properties.size).join(', ')})
          EOS
        end

        def create_statement_with_returning(resource, properties)
          <<-EOS.compress_lines
            INSERT INTO #{quote_table_name(resource.resource_name(name))}
            (#{properties.map { |property| quote_column_name(property.field) }.join(', ')})
            VALUES
            (#{(['?'] * properties.size).join(', ')})
            RETURNING #{quote_column_name(resource.key(name).first.field)}
          EOS
        end
        
        def read_statement(resource, key)
          properties = resource.properties(name).select { |property| !property.lazy? }
          <<-EOS.compress_lines
            SELECT #{properties.map { |property| quote_column_name(property.field) }.join(', ')} 
            FROM #{quote_table_name(resource.resource_name(name))} 
            WHERE #{resource.key(name).map { |key| "#{quote_column_name(key.field)} = ?" }.join(' AND ')}
          EOS
        end
        
        def update_statement(resource, properties)
          <<-EOS.compress_lines
            UPDATE #{quote_table_name(resource.resource_name(name))} 
            SET #{properties.map {|attribute| "#{quote_column_name(attribute.field)} = ?" }.join(', ')}
            WHERE #{resource.key(name).map { |key| "#{quote_column_name(key.field)} = ?" }.join(' AND ')}
          EOS
        end
        
        def delete_statement(resource)
          <<-EOS.compress_lines
            DELETE FROM #{quote_table_name(resource.resource_name(name))} 
            WHERE #{resource.key(name).map { |key| "#{quote_column_name(key.field)} = ?" }.join(' AND ')}
          EOS
        end
        
      end #module SQL
      
      include SQL
      
      # Adapters requiring a RETURNING syntax for create statements
      # should overwrite this to return true.
      def syntax_returning?
        false
      end

      def quote_table_name(table_name)
        table_name.ensure_wrapped_with('"')
      end

      def quote_column_name(column_name)
        column_name.ensure_wrapped_with('"')
      end
      
    end # class DoAdapter

  end # module Adapters
end # module DataMapper
