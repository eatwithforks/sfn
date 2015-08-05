require 'sfn'

module Sfn
  # Interface for injecting custom functionality
  class Callback

    # @return [Bogo::Ui]
    attr_reader :ui
    # @return [Smash]
    attr_reader :config

    # Create a new callback instance
    #
    # @param [Bogo::Ui]
    # @param [Smash] configuration hash
    # @param [Array<String>] arguments from the CLI
    # @param [Miasma::Models::Orchestration] API connection
    #
    # @return [self]
    def initialize(ui, config, arguments, api)
      @ui = ui
      @config = config
      @arguments = arguments
      @api = api
    end

  end
end
