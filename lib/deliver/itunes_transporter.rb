require 'pty'
require 'shellwords'
require 'deliver/password_manager'


module Deliver
  # The TransporterInputError occurs when you passed wrong inputs to the {Deliver::ItunesTransporter}
  class TransporterInputError < StandardError 
  end
  # The TransporterTransferError occurs when some error happens
  # while uploading or downloading something from/to iTC
  class TransporterTransferError < StandardError
  end

  class ItunesTransporter
    ERROR_REGEX = />\s*ERROR:\s+(.+)/  
    WARNING_REGEX = />\s*WARN:\s+(.+)/
    OUTPUT_REGEX = />\s+(.+)/

    private_constant :ERROR_REGEX, :WARNING_REGEX, :OUTPUT_REGEX

    # This will be called from the Deliverfile, and disables the logging of the transpoter output
    def self.hide_transporter_output
      @@hide_transporter_output = true
    end
    
    # Returns a new instance of the iTunesTranspoter.
    # If no username or password given, it will be taken from
    # the #{Deliver::PasswordManager}
    def initialize(user = nil, password = nil)
      @user = (user || PasswordManager.shared_manager.username)
      @password = (password || PasswordManager.shared_manager.password)
    end

    # Downloads the latest version of the app metadata package from iTC.
    # @param app [Deliver::App] The app you want to download the data for
    # @param dir [String] the path to the package file
    # @return (Bool) True if everything worked fine
    # @raise [Deliver::TransporterTransferError] when something went wrong
    #   when transfering
    # @raise [Deliver::TransporterInputError] when passing wrong inputs
    def download(app, dir = nil)
      dir ||= "/tmp"
      raise TransporterInputError.new("No valid Deliver::App given") unless app.kind_of?Deliver::App

      Helper.log.info "Going to download app metadata from iTunesConnect"
      dir ||= app.get_metadata_directory
      command = build_download_command(@user, @password, app.apple_id, dir)

      result = execute_transporter(command)

      itmsp_path = [dir, "#{app.apple_id}.itmsp"].join('/')
      if result and File.directory?itmsp_path
        Helper.log.info "Successfully downloaded the latest package from iTunesConnect.".green
      else
        Helper.log.fatal "Could not download metadata from iTunes Connect. Do you have special characters in your password (Like ' or \")?"
      end

      result
    end

    # Uploads the modified package back to iTunesConnect
    # @param app [Deliver::App] The app you want to download the data for
    # @param dir [String] the path in which the package file is located
    # @return (Bool) True if everything worked fine
    # @raise [Deliver::TransporterTransferError] when something went wrong
    #   when transfering
    # @raise [Deliver::TransporterInputError] when passing wrong inputs
    def upload(app, dir)
      raise TransporterInputError.new("No valid Deliver::App given") unless app.kind_of?Deliver::App

      dir ||= app.get_metadata_directory
      dir += "/#{app.apple_id}.itmsp"

      Helper.log.info "Going to upload updated app to iTunesConnect"
      
      command = build_upload_command(@user, @password, dir)
      result = execute_transporter(command)

      if result
        Helper.log.info "Successfully uploaded package to iTunesConnect. It might take a few minutes until it's visible online.".green
      end

      result
    end

    private
      def execute_transporter(command)
        @errors = []
        @warnings = []

        if defined?@@hide_transporter_output
          # Show a one time message instead
          Helper.log.info "Waiting for iTunes Connect transpoter to be finished.".green
          Helper.log.info "If you want upload/download logs to be enabled, remove 'hide_transporter_output' from your Deliverfile."
          Helper.log.info "iTunes Transporter progress...".green
        end

        begin
          PTY.spawn(command) do |stdin, stdout, pid|
            stdin.each do |line|
              parse_line(line) # this is where the parsing happens
            end
          end
        rescue Exception => ex
          Helper.log.fatal(ex.to_s)
          @errors << ex.to_s
        end

        if @errors.count > 0
          raise TransporterTransferError.new(@errors.join("\n"))
        end

        if @warnings.count > 0
          Helper.log.warn(@warnings.join("\n"))
        end

        true
      end

      def parse_line(line)
        # Taken from https://github.com/sshaw/itunes_store_transporter/blob/master/lib/itunes/store/transporter/output_parser.rb

        if line =~ ERROR_REGEX
          @errors << $1

          # Check if it's a login error
          if $1.include?"Your Apple ID or password was entered incorrectly" or
             $1.include?"This Apple ID has been locked for security reasons"

            Deliver::PasswordManager.shared_manager.password_seems_wrong
          end

        elsif line =~ WARNING_REGEX
          @warnings << $1
        end

        if not defined?@@hide_transporter_output and line =~ OUTPUT_REGEX
          # General logging for debug purposes
          Helper.log.debug "[Transpoter Output]: #{$1}"
        end
      end

      def build_download_command(username, password, apple_id, destination = "/tmp")
        [
          Helper.transporter_path,
          "-m lookupMetadata",
          "-u \"#{username}\"",
          "-p '#{escaped_password(password)}'",
          "-apple_id #{apple_id}",
          "-destination '#{destination}'"
        ].join(' ')
      end

      def build_upload_command(username, password, source = "/tmp")
        [
          Helper.transporter_path,
          "-m upload",
          "-u \"#{username}\"",
          "-p '#{escaped_password(password)}'",
          "-f '#{source}'"
        ].join(' ')
      end

      def escaped_password(password)
        Shellwords.escape(password)
      end

  end
end