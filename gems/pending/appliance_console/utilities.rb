# TODO: add appropriate requires instead of depending on appliance_console.rb.
# TODO: Further refactor these unrelated methods.
require "util/postgres_admin"
require "awesome_spawn"
require "appliance_console/logging"

module ApplianceConsole
  module Utilities
    def self.rake(task, params)
      rake_run(task, params).success?
    end

    def self.rake_run(task, params)
      result = AwesomeSpawn.run("rake #{task}", :chdir => RAILS_ROOT, :params => params)
      ApplianceConsole::Logging.logger.error(result.error) if result.failure?
      result
    end

    def self.db_connections
      result = AwesomeSpawn.run("bin/rails runner",
                                :params => ["exit EvmDatabaseOps.database_connections"],
                                :chdir  => RAILS_ROOT
                               )
      Integer(result.exit_status)
    end

    def self.bail_if_db_connections(message)
      say("Checking for connections to the database...\n\n")
      if (conns = ApplianceConsole::Utilities.db_connections - 1) > 0
        say("Warning: There are #{conns} existing connections to the database #{message}.\n\n")
        press_any_key
        raise MiqSignalError
      end
    end

    def self.db_host_database_region
      result = AwesomeSpawn.run(
        "bin/rails runner",
        :params => ["puts Rails.configuration.database_configuration[Rails.env].values_at('host', 'database'), ApplicationRecord.my_region_number"],
        :chdir  => RAILS_ROOT
      )

      host, database, region = result.output.split("\n").last(3)

      if database.blank?
        logger = ApplianceConsole::Logging.logger
        logger.error "db_host_type_database: Failed to detect some/all DB configuration"
        logger.error "Output: #{result.output.inspect}" unless result.output.blank?
        logger.error "Error:  #{result.error.inspect}"  unless result.error.blank?
      end

      return host.presence, database, region
    end

    def self.pg_status
      LinuxAdmin::Service.new(PostgresAdmin.service_name).running? ? "running" : "not running"
    end

    def self.test_network
      require 'net/ping'
      say("Test Network Configuration\n\n")
      while (h = ask_for_ip_or_hostname_or_none("hostname, ip address, or none to continue").presence)
        say("  " + h + ': ' + (Net::Ping::External.new(h).ping ? 'Success!' : 'Failure, Check network settings and IP address or hostname provided.'))
      end
    end
  end
end
