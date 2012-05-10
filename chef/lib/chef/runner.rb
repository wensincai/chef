#--
# Author:: Adam Jacob (<adam@opscode.com>)
# Author:: Christopher Walters (<cw@opscode.com>)
# Author:: Tim Hinderliter (<tim@opscode.com>)
# Copyright:: Copyright (c) 2008, 2010 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/mixin/params_validate'
require 'chef/node'
require 'chef/resource_collection'
require 'chef/platform'

class Chef
  # == Chef::Runner
  # This class is responsible for executing the steps in a Chef run.
  class Runner

    attr_reader :run_context

    attr_reader :delayed_actions

    include Chef::Mixin::ParamsValidate

    def initialize(run_context)
      @run_context      = run_context
      @delayed_actions  = []
    end

    def events
      @run_context.events
    end

    # Determine the appropriate provider for the given resource, then
    # execute it.
    def run_action(resource, action, notification_type=nil, notifying_resource=nil)
      # Try to resolve lazy/forward references in notifications again to handle
      # the case where the resource was defined lazily (ie. in a ruby_block)
      resource.resolve_notification_references

      begin
        events.resource_action_start(resource, action, notification_type, notifying_resource)
        Chef::Log.debug("Processing #{resource} on #{run_context.node.name}")
        resource.run_action(action)
      rescue Exception => e
        Chef::Log.error("#{resource} (#{resource.source_line}) had an error:\n#{e}\n#{e.backtrace.join("\n")}")
        if resource.retries > 0
          events.resource_failed_retriable(resource, action, resource.retries, e)
          resource.retries -= 1
          Chef::Log.info("Retrying execution of #{resource}, #{resource.retries} attempt(s) left")
          sleep resource.retry_delay
          retry
        else
          events.resource_failed(resource, action, e)
        end
        raise e unless resource.ignore_failure
      end

      # Execute any immediate and queue up any delayed notifications
      # associated with the resource, but only if it was updated *this time*
      # we ran an action on it.
      if resource.updated_by_last_action?
        resource.immediate_notifications.each do |notification|
          Chef::Log.info("#{resource} sending #{notification.action} action to #{notification.resource} (immediate)")
          run_action(notification.resource, notification.action, :immediate, resource)
        end

        resource.delayed_notifications.each do |notification|
          if delayed_actions.any? { |existing_notification| existing_notification.duplicates?(notification) }
            Chef::Log.info( "#{resource} not queuing delayed action #{notification.action} on #{notification.resource}"\
                            " (delayed), as it's already been queued")
          else
            delayed_actions << notification
          end
        end
      end
    end

    # Iterates over the +resource_collection+ in the +run_context+ calling
    # +run_action+ for each resource in turn.
    def converge
      # Resolve all lazy/forward references in notifications
      run_context.resource_collection.each do |resource|
        resource.resolve_notification_references
      end

      # Execute each resource.
      run_context.resource_collection.execute_each_resource do |resource|
        Array(resource.action).each {|action| run_action(resource, action)}
      end

      # Run all our :delayed actions
      delayed_actions.each do |notification|
        Chef::Log.info( "#{notification.notifying_resource} sending #{notification.action}"\
                        " action to #{notification.resource} (delayed)")
        # Struct of resource/action to call
        run_action(notification.resource, notification.action, :delayed)
      end

      true
    end
  end
end
