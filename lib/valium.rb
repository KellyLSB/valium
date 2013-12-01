 require "valium/version"
require 'active_record'

module Valium
  if ActiveRecord::VERSION::MAJOR >= 3

    if ActiveRecord::VERSION::MAJOR == 3 && ActiveRecord::VERSION::MINOR == 0 # We need to use the old deserialize code

      CollectionProxy = ActiveRecord::Associations::AssociationProxy

      CollectionProxy.class_eval do
        delegate :scoping, :klass, :to => :scoped
      end

      def valium_deserialize(value, klass)
        if value.is_a?(String) && value =~ /^---/
          result = YAML::load(value) rescue value
          if result.nil? || result.is_a?(klass)
            result
          else
            raise SerializationTypeMismatch,
              "Expected a #{klass}, but was a #{result.class}"
          end
        else
          value
        end
      end

    else # we're on 3.1+, yay for coder.load!

      CollectionProxy = ActiveRecord::Associations::CollectionProxy

      def valium_deserialize(value, coder)
        coder.load(value)
      end

    end # Minor version check

    def value_of(*attr_names)
      # If not a column assume array indexer
      columns = column_names.map(&:to_sym)
      compare = columns.include?("#{attr_names.first}".to_sym)
      if attr_names.first.is_a?(Range) || ! compare
        return to_a[*attr_names]
      end

      attr_names.map! do |attr_name|
        attr_name = attr_name.to_s
        attr_name == 'id' ? primary_key : attr_name
      end

      if attr_names.size > 1
        valium_select_multiple(attr_names)
      else
        valium_select_one(attr_names.first)
      end
    end

    alias :values_of :value_of
    alias :[] :value_of

    if ActiveRecord::VERSION::MAJOR < 4

      def valium_select_rows(relation)
        connection.select_rows(relation.to_sql)
      end

    else

      def valium_select_rows(relation)
        connection.select_all(
          relation.to_sql,
          "Valium Read",
          relation.bind_values
        ).rows
      end

    end

    def valium_select_multiple(attr_names)
      columns = attr_names.map {|n| columns_hash[n]}
      coders  = attr_names.map {|n| serialized_attributes[n]}

      relation = except(:select).select(attr_names.map {|n| arel_table[n]})

      valium_select_rows(relation).map! do |values|
        values.each_with_index do |value, index|
          values[index] = valium_cast(value, columns[index], coders[index])
        end
      end
    end

    def valium_select_one(attr_name)
      column = columns_hash[attr_name]
      coder  = serialized_attributes[attr_name]

      relation = except(:select).select(arel_table[attr_name])

      valium_select_rows(relation).map! do |values|
        valium_cast(values[0], column, coder)
      end
    end

    def valium_cast(value, column, coder_or_klass)
      if value.nil? || !column
        value
      elsif coder_or_klass
        valium_deserialize(value, coder_or_klass)
      else
        column.type_cast(value)
      end
    end

    module ValueOf
      def value_of(*args)
        # If not a column assume array indexer
        columns = klass.column_names.map(&:to_sym)
        compare = columns.include?("#{args.first}".to_sym)
        if args.first.is_a?(Range) || ! compare
          return to_a[*args]
        end

        args.map! do |attr_name|
          attr_name = attr_name.to_s
          attr_name == 'id' ? klass.primary_key : attr_name
        end

        if loaded? && (empty? || args.all? {|a| first.attributes.has_key? a})
          if args.size > 1
            to_a.map {|record| args.map {|a| record[a]}}
          else
            to_a.map {|record| record[args[0]]}
          end
        else
          scoping { klass.value_of(*args) }
        end
      end

      alias :values_of :value_of
      alias :[] :value_of
    end
  end # Major version check
end

ActiveRecord::Base.extend Valium
ActiveRecord::Relation.send :include, Valium::ValueOf
Valium::CollectionProxy.send :include, Valium::ValueOf
