
require 'netaddr'

require 'terrafying/components/subnet'
require 'terrafying/components/zone'
require 'terrafying/generator'

module Terrafying

  module Components
    DEFAULT_SSH_GROUP = 'cloud-team'
    DEFAULT_ZONE = "vpc.usw.co"

    class VPC < Terrafying::Context

      attr_reader :id, :name, :cidr, :zone, :azs, :subnets, :internal_ssh_security_group, :ssh_group

      def self.find(name)
        VPC.new.find name
      end

      def self.create(name, cidr, options={})
        VPC.new.create name, cidr, options
      end

      def initialize()
        super
      end


      def find(name)
        vpc = aws.vpc(name)

        subnets = aws.subnets_for_vpc(vpc.vpc_id).map { |subnet|
          Subnet.find(subnet.subnet_id)
        }.sort { |s1, s2| s2.id <=> s1.id }

        @name = name
        @id = vpc.vpc_id
        @cidr = vpc.cidr_block
        @zone = Terrafying::Components::Zone.find_by_tag({vpc: @id})
        if @zone.nil?
          raise "Failed to find zone"
        end
        @public_subnets = subnets.select { |s| s.public }
        @private_subnets = subnets.select { |s| !s.public }
        tags = vpc.tags.select { |tag| tag.key == "ssh_group"}
        if tags.count > 0
          @ssh_group = tags[0].value
        else
          @ssh_group = DEFAULT_SSH_GROUP
        end
        @internal_ssh_security_group = aws.security_group("#{name.gsub(/[\s\.]/,"-")}-internal-ssh")
        self
      end

      def create(name, raw_cidr, options={})
        options = {
          subnet_size: 24,
          internet_access: true,
          nat_eips: [],
          azs: aws.availability_zones,
          tags: {},
          ssh_group: DEFAULT_SSH_GROUP,
        }.merge(options)

        if options[:parent_zone].nil?
          options[:parent_zone] = Zone.find(DEFAULT_ZONE)
        end

        if options[:subnets].nil?
          if options[:internet_access]
            options[:subnets] = {
              public: { public: true },
              private: { internet: true },
            }
          else
            options[:subnets] = {
              private: { },
            }
          end
        end

        @name = name
        @cidr = raw_cidr
        @azs = options[:azs]
        @tags = options[:tags]
        @ssh_group = options[:ssh_group]

        cidr = NetAddr::CIDR.create(raw_cidr)

        @remaining_ip_space = NetAddr::Tree.new
        @remaining_ip_space.add! cidr
        @subnet_size = options[:subnet_size]
        @subnets = {}

        per_az_subnet_size = options[:subnets].values.reduce(0) { |memo, s|
          memo + (1 << (32 - s.fetch(:bit_size, @subnet_size)))
        }
        total_subnet_size = per_az_subnet_size * @azs.count

        if total_subnet_size > cidr.size
          raise "Not enough space for subnets in CIDR"
        end

        @id = resource :aws_vpc, name, {
                         cidr_block: cidr.to_s,
                         enable_dns_hostnames: true,
                         tags: { Name: name, ssh_group: @ssh_group }.merge(@tags),
                       }

        @zone = add! Terrafying::Components::Zone.create("#{name}.#{options[:parent_zone].fqdn}", {
                                                           parent_zone: options[:parent_zone],
                                                           tags: { vpc: @id }.merge(@tags),
                                                         })

        dhcp = resource :aws_vpc_dhcp_options, name, {
                          domain_name: @zone.fqdn,
                          domain_name_servers: ["AmazonProvidedDNS"],
                          tags: { Name: name }.merge(@tags),
                        }

        resource :aws_vpc_dhcp_options_association, name, {
                   vpc_id: @id,
                   dhcp_options_id: dhcp,
                 }


        if options[:internet_access]

          if options[:nat_eips].size == 0
            options[:nat_eips] = @azs.map{ |az| resource :aws_eip, "#{name}-nat-gateway-#{az}", { vpc: true } }
          elsif options[:nat_eips].size != @azs.count
            raise "The nubmer of nat eips has to match the number of AZs"
          end

          @internet_gateway = resource :aws_internet_gateway, name, {
                                         vpc_id: @id,
                                         tags: {
                                           Name: name,
                                         }.merge(@tags)
                                       }
          allocate_subnets!(:nat_gateway, { bit_size: 28, public: true })

          @nat_gateways = @azs.zip(@subnets[:nat_gateway], options[:nat_eips]).map { |az, subnet, eip|
            resource :aws_nat_gateway, "#{name}-#{az}", {
                       allocation_id: eip,
                       subnet_id: subnet.id,
                     }
          }

        end

        options[:subnets].each { |key, config| allocate_subnets! key, config }

        @internal_ssh_security_group = resource :aws_security_group, "#{name}-internal-ssh", {
                                                  name: "#{name}-internal-ssh",
                                                  description: "Allows SSH between machines inside the VPC CIDR",
                                                  tags: @tags,
                                                  vpc_id: @id,
                                                  ingress: [
                                                    {
                                                      from_port: 22,
                                                      to_port: 22,
                                                      protocol: "tcp",
                                                      cidr_blocks: [@cidr],
                                                    },
                                                  ],
                                                  egress: [
                                                    {
                                                      from_port: 22,
                                                      to_port: 22,
                                                      protocol: "tcp",
                                                      cidr_blocks: [@cidr],
                                                    },
                                                  ],
                                                }
        self
      end


      def peer_with(other_vpc, options={})
        options = {
          our_subnets: @subnets.values.flatten,
          their_subnets: other_vpc.subnets.values.flatten,
        }.merge(options)

        other_vpc_ident = other_vpc.name.gsub(/[\s\.]/, "-")

        our_cidr = NetAddr::CIDR.create(@cidr)
        other_cidr = NetAddr::CIDR.create(other_vpc.cidr)

        if our_cidr.contains? other_cidr[0] or our_cidr.contains? other_cidr.last
          raise "VPCs to be peered have overlapping CIDRs"
        end

        peering_connection = resource :aws_vpc_peering_connection, "#{@name}-to-#{other_vpc_ident}", {
                                        peer_vpc_id: other_vpc.id,
                                        vpc_id: @id,
                                        auto_accept: true,
                                        tags: { Name: "#{@name} to #{other_vpc.name}" }.merge(@tags),
                                      }

        our_route_tables = options[:our_subnets].map(&:route_table).sort.uniq
        their_route_tables = options[:their_subnets].map(&:route_table).sort.uniq

        our_route_tables.each.with_index { |route_table, i|
          resource :aws_route, "#{@name}-#{other_vpc_ident}-peer-#{i}", {
                     route_table_id: route_table,
                     destination_cidr_block: other_vpc.cidr,
                     vpc_peering_connection_id: peering_connection,
                   }
        }

        their_route_tables.each.with_index { |route_table, i|
          resource :aws_route, "#{other_vpc_ident}-#{@name}-peer-#{i}", {
                     route_table_id: route_table,
                     destination_cidr_block: @cidr,
                     vpc_peering_connection_id: peering_connection,
                   }
        }
      end

      def extract_subnet!(bit_size)
        if bit_size > 28  # aws can't have smaller
          bit_size = 28
        end

        targets = @remaining_ip_space.find_space({ Subnet: bit_size })

        if targets.count == 0
          raise "Run out of ip space to allocate a /#{bit_size}"
        end

        target = targets[0]

        @remaining_ip_space.delete!(target)

        if target.bits == bit_size
          new_subnet = target
        else
          new_subnet = target.subnet({ Bits: bit_size, Objectify: true })[0]

          target.remainder(new_subnet).each { |rem|
            @remaining_ip_space.add!(rem)
          }
        end

        return new_subnet.to_s
      end

      def allocate_subnets!(name, options = {})
        options = {
          public: false,
          bit_size: @subnet_size,
          internet: true,
        }.merge(options)

        if options[:public]
          gateways = [@internet_gateway] * @azs.count
        elsif options[:internet] && @nat_gateways != nil
          gateways = @nat_gateways
        else
          gateways = [nil] * @azs.count
        end

        @subnets[name] = @azs.zip(gateways).map { |az, gateway|
          subnet_options = { tags: { subnet_name: name }.merge(@tags) }
          if gateway != nil
            if options[:public]
              subnet_options[:gateway] = gateway
            elsif options[:internet]
              subnet_options[:nat_gateway] = gateway
            end
          end

          add! Terrafying::Components::Subnet.create_in(
                 self, name, az, extract_subnet!(options[:bit_size]), subnet_options
               )
        }
      end

    end

  end

end
