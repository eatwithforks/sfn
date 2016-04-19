require 'sfn'

module Sfn
  module ApiProvider

    module Google

      # Disable remote template storage
      def store_template(*_)
      end

      # No formatting required on stack results
      def format_nested_stack_results(*_)
        {}
      end

      # Extract current parameters from parent template
      #
      # @param stack [SparkleFormation]
      # @param stack_name [String]
      # @return [Hash]
      def extract_current_nested_template_parameters(stack, stack_name)
        if(stack.parent)
          current_parameters = stack.parent.compile.resources.set!(stack_name).properties
          current_parameters.nil? ? Smash.new : current_parameters._dump
        else
          Smash.new
        end
      end

      # Determine if parameter was set via intrinsic function
      #
      # @param val [Object]
      # @return [TrueClass, FalseClass]
      def function_set_parameter?(val)
        if(val)
          val.start_with?('$(') || val.start_with?('{{')
        end
      end

      # Set parameters into parent resource properites
      def populate_parameters!(template, opts={})
        result = super
        result.each_pair do |key, value|
          if(template.parent)
            template.parent.compile.resources.set!(template.name).properties.set!(key, value)
          else
            template.compile.resources.set!(template.name).properties.set!(key, value)
          end
        end
        {}
      end

      # Override requirement of nesting bucket
      def validate_nesting_bucket!
        true
      end

      # Override template content extraction to disable scrub behavior
      #
      # @param thing [SparkleFormation, Hash]
      # @return [Hash]
      def template_content(thing, *_)
        if(thing.is_a?(SparkleFormation))
          config[:sparkle_dump] ? thing.sparkle_dump : thing.dump
        else
          thing
        end
      end

    end

  end
end
