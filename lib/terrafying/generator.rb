require 'json'
require 'base64'
require 'erb'
require 'ostruct'
require 'deep_merge'
require 'terrafying/aws'

module Terrafying

  class Context

    PROVIDER_DEFAULTS = {
      aws: { region: 'eu-west-1' }
    }

    attr_reader :output

    def initialize
      @output = {
        "provider" => PROVIDER_DEFAULTS,
        "resource" => {}
      }
      @children = []
    end

    def aws
      @aws ||= Terrafying::Aws::Ops.new
    end

    def provider(name, spec)
      @output["provider"][name] = spec
    end

    def data(type, name, spec)
      @output["data"] ||= {}
      @output["data"][type.to_s] ||= {}
      @output["data"][type.to_s][name.to_s] = spec
      id_of(type, name)
    end

    def resource(type, name, attributes)
      @output["resource"][type.to_s] ||= {}
      @output["resource"][type.to_s][name.to_s] = attributes
      id_of(type, name)
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
      "${#{type}.#{name}.id}"
    end

    def output_of(type, name, value)
      "${#{type}.#{name}.#{value}}"
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

  end

  class DSLContext < Context

    def generate(&block)
      instance_eval(&block)
    end

    def method_missing(fn, *args)
      resource(fn, args.shift.to_s, args.first)
    end

  end

  Generator = DSLContext.new

end
