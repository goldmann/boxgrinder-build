#
# Copyright 2010 Red Hat, Inc.
#
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 3 of
# the License, or (at your option) any later version.
#
# This software is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this software; if not, write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301 USA, or see the FSF site: http://www.fsf.org.

require 'rubygems'
require 'hashery/opencascade'
require 'boxgrinder-core/helpers/log-helper'
require 'boxgrinder-core/models/appliance-config'
require 'boxgrinder-core/models/config'
require 'boxgrinder-core/helpers/appliance-definition-helper'
require 'boxgrinder-core/helpers/appliance-config-helper'
require 'boxgrinder-build/helpers/plugin-helper'
require 'boxgrinder-build/managers/plugin-manager'

module BoxGrinder
  class Appliance
    def initialize(appliance_definition, config = Config.new, options = {})
      @appliance_definition = appliance_definition
      @config = config
      @log = options[:log] || LogHelper.new(:level => @config.log_level)
    end

    def read_definition
      # first try to read as appliance definition file
      appliance_helper = ApplianceDefinitionHelper.new(:log => @log)
      appliance_helper.read_definitions(@appliance_definition)

      appliance_configs = appliance_helper.appliance_configs
      appliance_config = appliance_configs.first

      if appliance_config.nil?
        # Still nothing? Then try to read OS plugin specific format...
        PluginManager.instance.plugins[:os].each_value do |info|
          plugin = info[:class].new
          appliance_config = plugin.read_file(@appliance_definition) if plugin.respond_to?(:read_file)
          break unless appliance_config.nil?
        end
        appliance_configs = [appliance_config]

        raise ValidationError, "Couldn't read appliance definition file: #{File.basename(@appliance_definition)}." if appliance_config.nil?
      end

      appliance_config_helper = ApplianceConfigHelper.new(appliance_configs)
      @appliance_config = appliance_config_helper.merge(appliance_config.clone.init_arch).initialize_paths
    end

    def validate_definition
      raise "No operating system plugins installed. Install one or more operating system plugin. See http://boxgrinder.org/tutorials/boxgrinder-build-plugins/#Operating_system_plugins for more info." if PluginManager.instance.plugins[:os].empty?

      os_plugin = PluginManager.instance.plugins[:os][@appliance_config.os.name.to_sym]

      raise "Not supported operating system selected: #{@appliance_config.os.name}. Make sure you have installed right operating system plugin, see http://boxgrinder.org/tutorials/boxgrinder-build-plugins/#Operating_system_plugins. Supported OSes are: #{PluginManager.instance.plugins[:os].keys.join(", ")}" if os_plugin.nil?
      raise "Not supported operating system version selected: #{@appliance_config.os.version}. Supported versions are: #{os_plugin[:versions].join(", ")}" unless @appliance_config.os.version.nil? or os_plugin[:versions].include?(@appliance_config.os.version)
    end

    def remove_old_builds
      @log.info "Removing previous builds for #{@appliance_config.name} appliance..."
      FileUtils.rm_rf(@appliance_config.path.build)
      @log.debug "Previous builds removed."
    end

    def execute_plugin_chain
      @log.info "Building '#{@appliance_config.name}' appliance for #{@appliance_config.hardware.arch} architecture."

      execute_delivery_plugin(execute_platform_plugin(execute_os_plugin))
    end

    def create
      @log.debug "Launching new BoxGrinder build..."
      @log.trace "Used configuration: #{@config.to_yaml.gsub(/(\S*(key|account|cert|username|host|password)\S*).*:(.*)/, '\1' + ": <REDACTED>")}"

      PluginHelper.new(@config, :log => @log).load_plugins
      read_definition
      validate_definition
      remove_old_builds if @config.force
      execute_plugin_chain
    end

    def execute_os_plugin
      raise "No operating system plugins installed. Install one or more operating system plugin. See http://boxgrinder.org/tutorials/boxgrinder-build-plugins/#Operating_system_plugins for more info." if PluginManager.instance.plugins[:os].empty?

      os_plugin, os_plugin_info = PluginManager.instance.initialize_plugin(:os, @appliance_config.os.name.to_sym)
      os_plugin.init(@config, @appliance_config, :log => @log, :plugin_info => os_plugin_info)

      if os_plugin.deliverables_exists?
        @log.info "Deliverables for #{os_plugin_info[:name]} operating system plugin exists, skipping."
        return {:deliverables => os_plugin.deliverables, :plugin_info => os_plugin_info}
      end

      @log.debug "Executing operating system plugin for #{@appliance_config.os.name}..."
      os_plugin.run(@appliance_definition)
      @log.debug "Operating system plugin executed."

      {:deliverables => os_plugin.deliverables, :plugin_info => os_plugin_info}
    end

    def execute_platform_plugin(previous_plugin_output)
      if @config.platform == :none or @config.platform.to_s.empty? == nil
        @log.debug "No platform selected, skipping platform conversion."
        return previous_plugin_output
      end

      raise "No platform plugins installed. Install one or more platform plugin. See http://boxgrinder.org/tutorials/boxgrinder-build-plugins/#Platform_plugins for more info." if PluginManager.instance.plugins[:platform].empty?

      platform_plugin, platform_plugin_info = PluginManager.instance.initialize_plugin(:platform, @config.platform)
      platform_plugin.init(@config, @appliance_config, :log => @log, :plugin_info => platform_plugin_info, :previous_plugin_info => previous_plugin_output[:plugin_info], :previous_deliverables => previous_plugin_output[:deliverables])

      if platform_plugin.deliverables_exists?
        @log.info "Deliverables for #{platform_plugin_info[:name]} platform plugin exists, skipping."
        return {:deliverables => platform_plugin.deliverables, :plugin_info => platform_plugin_info}
      end

      @log.debug "Executing platform plugin for #{@config.platform}..."
      platform_plugin.run
      @log.debug "Platform plugin executed."

      {:deliverables => platform_plugin.deliverables, :plugin_info => platform_plugin_info}
    end

    def execute_delivery_plugin(previous_plugin_output)
      if @config.delivery == :none or @config.delivery.to_s.empty? == nil
        @log.debug "No delivery method selected, skipping delivering."
        return
      end

      raise "No delivery plugins installed. Install one or more delivery plugin. See http://boxgrinder.org/tutorials/boxgrinder-build-plugins/#Delivery_plugins for more info" if PluginManager.instance.plugins[:delivery].empty?

      delivery_plugin, delivery_plugin_info = PluginManager.instance.initialize_plugin(:delivery, @config.delivery)
      delivery_plugin.init(@config, @appliance_config, :log => @log, :plugin_info => delivery_plugin_info, :previous_plugin_info => previous_plugin_output[:plugin_info], :previous_deliverables => previous_plugin_output[:deliverables])
      delivery_plugin.run(@config.delivery)
    end
  end
end
