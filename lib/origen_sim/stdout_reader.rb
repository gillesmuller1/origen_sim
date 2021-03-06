require 'thread'
require 'io/wait'
module OrigenSim
  class StdoutReader < Thread
    attr_reader :socket, :logged_errors

    def initialize(socket)
      @socket = socket
      @continue = true
      @logged_errors = false
      super do
        while @continue
          while @socket.ready?
            line = @socket.gets.chomp
            if OrigenSim.error_strings.any? { |s| line =~ /#{s}/ } &&
               !OrigenSim.error_string_exceptions.any? { |s| line =~ /#{s}/ }
              @logged_errors = true
              Origen.log.error "(STDOUT): #{line}"
            elsif OrigenSim.warning_strings.any? { |s| line =~ /#{s}/ } &&
                  !OrigenSim.warning_string_exceptions.any? { |s| line =~ /#{s}/ }
              Origen.log.warn line
            else
              if OrigenSim.verbose? ||
                 OrigenSim.log_strings.any? { |s| line =~ /#{s}/ }
                Origen.log.info line
              else
                Origen.log.debug line
              end
            end
          end
        end
      end
    end

    def stop
      @continue = false
    end
  end
end
