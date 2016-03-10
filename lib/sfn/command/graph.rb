require 'sfn'
require 'graph'

module Sfn
  class Command
    # Graph command
    class Graph < Command

      include Sfn::CommandModule::Base
      include Sfn::CommandModule::Template
      include Sfn::CommandModule::Stack

      # Generate graph
      def execute!
        config[:print_only] = true
        file = load_template_file
        file.delete('sfn_nested_stack')
        file = Sfn::Utils::StackParameterScrubber.scrub!(file)
        file = translate_template(file)
        @outputs = Smash.new
        file = file.to_smash
        ui.info 'Template resource graph generation'
        if(config[:file])
          ui.puts "  -> path: #{config[:file]}"
        end
        run_action 'Pre-processing template for graphing' do
          output_discovery(file, @outputs, nil, nil)
          nil
        end
        graph = nil
        run_action 'Generating resource graph' do
          graph = generate_graph(file.to_smash)
          nil
        end
        run_action 'Writing graph result' do
          FileUtils.mkdir_p(File.dirname(config[:output_file]))
          if(config[:output_type] == 'dot')
            File.open("#{config[:output_file]}.dot", 'w') do |file|
              file.puts graph.to_s
            end
          else
            graph.save config[:output_file], config[:output_type]
          end
          nil
        end
      end

      def generate_graph(template, args={})
        graph = ::Graph.new
        @root_graph = graph unless @root_graph
        graph.graph_attribs << ::Graph::Attribute.new('overlap = false')
        graph.graph_attribs << ::Graph::Attribute.new('splines = true')
        graph.graph_attribs << ::Graph::Attribute.new('pack = true')
        graph.graph_attribs << ::Graph::Attribute.new('start = "random"')
        if(args[:name])
          graph.name = "cluster_#{args[:name]}"
          labelnode_key = "cluster_#{args[:name]}"
          graph.plaintext << graph.node(labelnode_key)
          graph.node(labelnode_key).label args[:name]
        else
          graph.name = 'root'
        end
        edge_detection(template, graph, args[:name].to_s.sub('cluster_', ''), args.fetch(:resource_names, []))
        graph
      end

      def output_discovery(template, outputs, resource_name, parent_template, name='')
        if(template['Resources'])
          template['Resources'].each_pair do |r_name, r_info|
            if(r_info['Type'] == 'AWS::CloudFormation::Stack')
              output_discovery(r_info['Properties']['Stack'], outputs, r_name, template, r_name)
            end
          end
        end
        if(parent_template)
          substack_parameters = Smash[
            parent_template.fetch('Resources', resource_name, 'Properties', 'Parameters', {}).map do |key, value|
              result = [key, value]
              if(value.is_a?(Hash))
                v_key = value.keys.first
                v_value = value.values.first
                if(v_key == 'Fn::GetAtt' && parent_template.fetch('Resources', {}).keys.include?(v_value.first) && v_value.last.start_with?('Outputs.'))
                  output_key = v_value.first << '__' << v_value.last.split('.', 2).last
                  if(outputs.key?(output_key))
                    new_value = outputs[output_key]
                    result = [key, new_value]
                  end
                end
              end
              result
            end
          ]
          processor = GraphProcessor.new({},
            :parameters => substack_parameters
          )
          template['Resources'] = processor.dereference_processor(
            template['Resources'], ['Ref']
          )
          template['Outputs'] = processor.dereference_processor(
            template['Outputs'], ['Ref']
          )
          rename_processor = GraphProcessor.new({},
            :parameters => Smash[
              template.fetch('Resources', {}).keys.map do |r_key|
                [r_key, {'Ref' => [name, r_key].join}]
              end
            ]
          )
          derefed_outs = rename_processor.dereference_processor(
            template.fetch('Outputs', {})
          ) || {}

          derefed_outs.each do |o_name, o_data|
            o_key = [name, o_name].join('__')
            outputs[o_key] = o_data['Value']
          end
        end
        outputs.dup.each do |key, value|
          if(value.is_a?(Hash))
            v_key = value.keys.first
            v_value = value.values.first
            if(v_key == 'Fn::GetAtt' && v_value.last.start_with?('Outputs.'))
              output_key = v_value.first << '__' << v_value.last.split('.', 2).last
              if(outputs.key?(output_key))
                outputs[key] = outputs[output_key]
              end
            end
          end
        end
      end

      def edge_detection(template, graph, name = '', resource_names = [])
        resources = template.fetch('Resources', {})
        node_prefix = name
        resources.each do |resource_name, resource_data|
          node_name = [node_prefix, resource_name].join
          if(resource_data['Type'] == 'AWS::CloudFormation::Stack')
            graph.subgraph << generate_graph(
              resource_data['Properties'].delete('Stack'),
              :name => resource_name,
              :type => resource_data['Type'],
              :resource_names => resource_names
            )
            next
          else
            graph.node(node_name).attributes << graph.fillcolor(colorize(node_prefix).inspect)
            graph.box3d << graph.node(node_name)
          end
          graph.filled << graph.node(node_name)
          graph.node(node_name).label "#{resource_name}\n<#{resource_data['Type']}>\n#{name}"
          resource_dependencies(resource_data, resource_names + resources.keys).each do |dep_name|
            if(resources.keys.include?(dep_name))
              dep_name = [node_prefix, dep_name].join
            end
            @root_graph.edge(dep_name, node_name)
          end
        end
        resource_names.concat resources.keys.map{|r_name| [node_prefix, r_name].join}
      end

      def resource_dependencies(data, names)
        case data
        when Hash
          data.map do |key, value|
            if(key == 'Ref' && names.include?(value))
              value
            elsif(key == 'Fn::GetAtt' && names.include?(res = [value].flatten.compact.first))
              res
            else
              resource_dependencies(key, names) +
                resource_dependencies(value, names)
            end
          end.flatten.compact.uniq
        when Array
          data.map do |item|
            resource_dependencies(item, names)
          end.flatten.compact.uniq
        else
          []
        end
      end

      def colorize(string)
        hash = string.chars.inject(0) do |memo, chr|
          chr.ord + ((memo << 5) - memo)
        end
        color = '#'
        6.times do |count|
          color << ('00' + ((hash >> count * 8) & 0xFF).to_s(16)).slice(-2)
        end
        color
      end

      class GraphProcessor < SparkleFormation::Translation
        MAP = {}
        REF_MAPPING = {}
        FN_MAPPING = {}

        attr_accessor :name

        def initialize(template, args={})
          super
          @name = args[:name]
        end

        def apply_function(hash, funcs=[])
          k, v = hash.first
          if(hash.size == 1)
            case k
            when 'Ref'
              parameters.key?(v) ? parameters[v] : hash
            when 'Fn::Join'
              v.last
            when 'Fn::Select'
              v.last[v.first.to_i]
            else
              hash
            end
          else
            hash
          end
        end

      end

    end
  end
end
