require 'json'
require 'base64'
require 'erb'
require 'ostruct'
require 'deep_merge'
require 'terrafying/aws'

module Terrafying

  class Ref

    def initialize(var)
      @var = var
    end

    def downcase
      Ref.new("lower(#{@var})")
    end

    def strip
      Ref.new("trimspace(#{@var})")
    end

    def to_s
      "${#{@var}}"
    end

    def to_str
      self.to_s
    end

    def <=>(other)
      self.to_s <=> other.to_s
    end

    def ==(other)
      self.to_s == other.to_s
    end

  end

  class Context

    REGION = ENV.fetch("AWS_REGION", "eu-west-1")

    PROVIDER_DEFAULTS = {
      aws: { region: REGION }
    }

    attr_reader :output

    def initialize
      @output = {
        "resource" => {}
      }
      @children = []
    end

    def aws
      @@aws ||= Terrafying::Aws::Ops.new REGION
    end

    def provider(name, spec)
      key = [name, spec[:alias]].compact.join('.')
      @providers ||= {}
      raise "Duplicate provider configuration detected for #{key}" if key_exists_spec_differs(key, name, spec)
      @providers[key] = { name.to_s => spec }
      @output['provider'] = @providers.values
      key
    end

    def key_exists_spec_differs(key, name, spec)
      @providers.key?(key) && spec != @providers[key][name.to_s]
    end

    def data(type, name, spec)
      @output["data"] ||= {}
      @output["data"][type.to_s] ||= {}

      raise "Data already exists #{type.to_s}.#{name.to_s}" if @output["data"][type.to_s].has_key? name.to_s
      @output["data"][type.to_s][name.to_s] = spec
      id_of(type, name)
    end

    def resource(type, name, attributes)
      @output["resource"][type.to_s] ||= {}

      raise "Resource already exists #{type.to_s}.#{name.to_s}" if @output["resource"][type.to_s].has_key? name.to_s
      @output["resource"][type.to_s][name.to_s] = attributes
      id_of(type, name)
    end

    def output_variable(name, attributes)
      @output["output"] ||= {}

      raise "Output already exists #{name.to_s}" if @output["output"].has_key? name.to_s
      @output["output"][name.to_s] = attributes
    end

    def template(relative_path, params = {})
      dir = caller_locations[0].path
      filename = File.join(File.dirname(dir), relative_path)
      erb = ERB.new(IO.read(filename))
      erb.filename = filename
      erb.result(OpenStruct.new(params).instance_eval { binding })
    end

    def output_with_children
      @children.inject(@output) { |out, c| out.deep_merge(c.output_with_children) }
    end

    def id_of(type,name)
      output_of(type, name, "id")
    end

    def output_of(type, name, value)
      Ref.new("#{type}.#{name}.#{value}")
    end

    def pretty_generate
      JSON.pretty_generate(output_with_children)
    end

    def resource_names
      out = output_with_children
      ret = []
      for type in out["resource"].keys
        for id in out["resource"][type].keys
          ret << "#{type}.#{id}"
        end
      end
      ret
    end

    def resources
      out = output_with_children
      ret = []
      for type in out["resource"].keys
        for id in out["resource"][type].keys
          ret << "${#{type}.#{id}.id}"
        end
      end
      ret
    end

    def add!(*c)
      @children.push(*c)
      c[0]
    end

    def tf_safe(str)
      str.gsub(/[\.\s\/\?]/, "-")
    end

  end

  class RootContext < Context

    def initialize
      super

      PROVIDER_DEFAULTS.each { |name, spec| provider(name, spec) }
    end

    def backend(name, spec)
      @output["terraform"] = {
        backend: {
          name => spec,
        },
      }
    end

    def generate(&block)
      instance_eval(&block)
    end

    def method_missing(fn, *args)
      resource(fn, args.shift.to_s, args.first)
    end

  end

  Generator = RootContext.new

end
