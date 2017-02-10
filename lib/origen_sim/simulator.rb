require 'socket'
module OrigenSim
  # Responsible for managing and communicating with the simulator
  # process, a single instance of this class is instantiated as
  # OrigenSim.simulator
  class Simulator
    include Origen::PersistentCallbacks

    VENDORS = [:icarus, :cadence]

    attr_reader :socket, :failed, :configuration
    alias_method :config, :configuration

    # When set to true the simulator will log all messages it receives, note that
    # this must be run in conjunction with -d supplied to the Origen command to actually
    # see the messages
    def log_messages=(val)
      if val
        put('d^1')
      else
        put('d^0')
      end
    end

    def configure(options)
      fail 'A vendor must be supplied, e.g. OrigenSim::Tester.new(vendor: :icarus)' unless options[:vendor]
      unless VENDORS.include?(options[:vendor])
        fail "Unknown vendor #{options[:vendor]}, valid values are: #{VENDORS.map { |v| ':' + v.to_s }.join(', ')}"
      end
      unless options[:rtl_top]
        fail "The name of the file containing the DUT top-level must be supplied, e.g. OrigenSim::Tester.new(rtl_top: 'my_ip')" unless options[:rtl_top]
      end
      @configuration = options
      @tmp_dir = nil
    end

    # The ID assigned to the current simulation target, falls back to to the
    # Origen target name if an :id option is not supplied when instantiating
    # the tester
    def id
      config[:id] || Origen.target.name
    end

    def tmp_dir
      @tmp_dir ||= begin
        d = "#{Origen.root}/tmp/origen_sim/#{id}/#{config[:vendor]}"
        FileUtils.mkdir_p(d)
        d
      end
    end

    def artifacts_dir
      @artifacts_dir ||= begin
        d = "#{Origen.root}/simulation/#{id}/artifacts"
        FileUtils.mkdir_p(d)
        d
      end
    end

    # Returns the directory where the compiled simulation object lives, this should
    # be checked into your Origen app's repository
    def compiled_dir
      @compiled_dir ||= begin
        d = "#{Origen.root}/simulation/#{id}/#{config[:vendor]}"
        FileUtils.mkdir_p(d)
        d
      end
    end

    def wave_dir
      @wave_dir ||= begin
        d = "#{Origen.root}/waves/#{id}"
        FileUtils.mkdir_p(d)
        d
      end
    end

    def pid_dir
      @pid_dir ||= begin
        d = "#{Origen.root}/tmp/origen_sim/pids"
        FileUtils.mkdir_p(d)
        d
      end
    end

    def wave_config_dir
      @wave_config_dir ||= begin
        d = "#{Origen.root}/config/waves/#{id}"
        FileUtils.mkdir_p(d)
        d
      end
    end

    def wave_config_file
      @wave_config_file ||= begin
        f = "#{wave_config_dir}/#{User.current.id}.svcf"
        unless File.exist?(f)
          # Take a default wave if one has been set up
          d = "#{wave_config_dir}/default.svcf"
          if File.exist?(d)
            FileUtils.cp(d, f)
          else
            # Otherwise seed it with the latest existing setup by someone else
            d = Dir.glob("#{wave_config_dir}/*.svcf").max { |a, b| File.ctime(a) <=> File.ctime(b) }
            if d
              FileUtils.cp(d, f)
            else
              # We tried our best, start from scratch
              d = "#{Origen.root!}/templates/empty.svcf"
              FileUtils.cp(d, f)
            end
          end
        end
        f
      end
    end

    def run_cmd
      case config[:vendor]
      when :icarus
        cmd = configuration[:vvp] || 'vvp'
        cmd += " -M#{compiled_dir} -morigen #{compiled_dir}/dut.vvp +socket+#{socket_id}"

      when :cadence
        input_file = "#{tmp_dir}/#{id}.tcl"
        unless File.exist?(input_file)
          Origen.app.runner.launch action:            :compile,
                                   files:             "#{Origen.root!}/templates/probe.tcl.erb",
                                   output:            tmp_dir,
                                   check_for_changes: false,
                                   quiet:             true,
                                   options:           { dir: wave_dir, force: config[:force], setup: config[:setup] },
                                   output_file_name:  "#{id}.tcl"
          puts 'Had to generate simulator input file, please run again'
          exit 0
        end
        wave_dir  # Ensure this exists since it won't be referenced above if the
        # input file is already generated

        cmd = configuration[:irun] || 'irun'
        cmd += " -r origen -snapshot origen +socket+#{socket_id}"
        cmd += " -input #{input_file}"
        cmd += " -nclibdirpath #{compiled_dir}"
      end
      cmd
    end

    def view_wave_command
      cmd = nil
      case config[:vendor]
      when :cadence
        edir = Pathname.new(wave_config_dir).relative_path_from(Pathname.pwd)
        cmd = "cd #{edir} && "
        cmd += configuration[:simvision] || 'simvision'
        dir = Pathname.new(wave_dir).relative_path_from(edir.expand_path)
        cmd += " #{dir}/#{id}.dsn #{dir}/#{id}.trn"
        f = Pathname.new(wave_config_file).relative_path_from(edir.expand_path)
        cmd += " -input #{f} &"
      end
      cmd
    end

    def run_dir
      case config[:vendor]
      when :icarus
        wave_dir
      else
        tmp_dir
      end
    end

    def link_artifacts
      done = "#{run_dir}/.artifacts_linked"
      unless File.exist?(done)
        Dir.foreach(artifacts_dir) do |item|
          next if item == '.' || item == '..'
          FileUtils.ln_s("#{artifacts_dir}/#{item}", "#{run_dir}/#{item}") unless File.exist?("#{run_dir}/#{item}")
        end
        FileUtils.touch(done)
      end
    end

    # Starts up the simulator process
    def start
      server = UNIXServer.new(socket_id)
      verbose = Origen.debugger_enabled?
      link_artifacts
      cmd = run_cmd + ' & echo \$!'

      launch_simulator = %(
        require 'open3'

        Dir.chdir '#{run_dir}' do
          Open3.popen3('#{cmd}') do |stdin, stdout, stderr, thread|
            pid = stdout.gets.strip
            File.open '#{pid_dir}/#{socket_number}', 'w' do |f|
              f.puts pid
            end
            threads = []
            threads << Thread.new do
              until (line = stdout.gets).nil?
                puts line if #{verbose ? 'true' : 'false'}
              end
            end
            threads << Thread.new do
              until (line = stderr.gets).nil?
                puts line
              end
            end
            threads.each(&:join)
          end
        end
      )

      simulator_parent_process = spawn("ruby -e \"#{launch_simulator}\"")
      Process.detach(simulator_parent_process)

      timeout_connection(config[:startup_timeout] || 15) do
        @socket = server.accept
        @connection_established = true
        if @connection_timed_out
          @failed_to_start = true
          Origen.log.error 'Simulator failed to respond'
          @failed = true
          exit
        end
      end
      data = get
      unless data.strip == 'READY!'
        @failed_to_start = true
        fail "The simulator didn't start properly!"
      end
      @enabled = true
      # Tick the simulation on, this seems to be required since any VPI puts operations before
      # the simulation has started are not applied.
      # Note that this is not setting a tester timeset, so the application will still have to
      # do that before generating any vectors.
      set_period(100)
      cycle(1)
      Origen.listeners_for(:simulation_startup).each(&:simulation_startup)
    end

    # Returns the pid of the simulator process
    def pid
      return @pid if @pid_set
      @pid = File.readlines(pid_file).first.strip.to_i if File.exist?(pid_file)
      @pid ||= 0
      @pid_set = true
      @pid
    end

    def pid_file
      "#{Origen.root}/tmp/origen_sim/pids/#{socket_number}"
    end

    # Returns true if the simulator process is running
    def running?
      return false if pid == 0
      begin
        Process.getpgid(pid)
        true
      rescue Errno::ESRCH
        false
      end
    end

    # Send the given message string to the simulator
    def put(msg)
      socket.write(msg + "\n") if socket
    end

    # Get a message from the simulator, will block until one
    # is received
    def get
      socket.readline
    end

    # This will be called at the end of every pattern, make
    # sure the simulator is not running behind before potentially
    # moving onto another pattern
    def pattern_generated(path)
      sync_up if simulation_tester?
    end

    # Called before every pattern is generated, but we only use it the
    # first time it is called to kick off the simulator process if the
    # current tester is an OrigenSim::Tester
    def before_pattern(name)
      if simulation_tester?
        unless @enabled
          # When running pattern back-to-back, only want to launch the simulator the
          # first time
          unless socket
            start
          end
        end
        # Set the current pattern name in the simulation
        put("a^#{name.sub(/\..*/, '')}")
      end
    end

    def write_comment(comment)
      put("c^#{comment}")
    end

    # Applies the current state of all pins to the simulation
    def put_all_pin_states
      dut.rtl_pins.each do |name, pin|
        pin.reset_simulator_state
        pin.update_simulation
      end
    end

    # This will be called automatically whenever tester.set_timeset
    # has been called
    def on_timeset_changed
      # Important that this is done first, since it is used to clear the pin
      # and wave definitions in the bridge
      set_period(dut.current_timeset_period)
      # Clear pins and waves
      define_pins
      define_waves
      # Apply the pin reset values / re-apply the existing states
      put_all_pin_states
    end

    # Tells the simulator about the pins in the current device so that it can
    # set up internal handles to efficiently access them
    def define_pins
      dut.rtl_pins.each_with_index do |(name, pin), i|
        unless pin.tie_off
          pin.simulation_index = i
          put("0^#{pin.id}^#{i}^#{pin.drive_wave.index}^#{pin.compare_wave.index}")
        end
      end
    end

    def wave_to_str(wave)
      wave.evaluated_events.map do |time, data|
        time = time * (config[:time_factor] || 1)
        if data == :x
          data = 'X'
        elsif data == :data
          data = wave.drive? ? 'D' : 'C'
        end
        if data == 'C'
          "#{time}_#{data}_#{time + 1}_X"
        else
          "#{time}_#{data}"
        end
      end.join('_')
    end

    def define_waves
      dut.timeset.drive_waves.each_with_index do |wave, i|
        put("6^#{i}^0^#{wave_to_str(wave)}")
      end
      dut.timeset.compare_waves.each_with_index do |wave, i|
        put("6^#{i}^1^#{wave_to_str(wave)}")
      end
    end

    def end_simulation
      put('8^')
    end

    def set_period(period_in_ns)
      period_in_ns = period_in_ns * (config[:time_factor] || 1)
      put("1^#{period_in_ns}")
    end

    def cycle(number_of_cycles)
      put("3^#{number_of_cycles}")
    end

    # Blocks the Origen process until the simulator indicates that it has
    # processed all operations up to this point
    def sync_up
      put('7^')
      data = get
      unless data.strip == 'OK!'
        fail 'Origen and the simulator are out of sync!'
      end
    end

    # Returns the current simulation error count
    def error_count
      peek('origen.debug.errors')
    end

    # Returns the current value of the given net, or nil if the given path does not
    # resolve to a valid node
    def peek(net)
      # The Verilog spec does not specify that underlying VPI put method should
      # handle a part select, so some simulators do not handle it. Therefore we
      # deal with it here to ensure cross simulator compatibility.

      # http://rubular.com/r/eTVGzrYmXQ
      if net =~ /(.*)\[(\d+):?(\.\.)?(\d*)\]$/
        net = Regexp.last_match(1)
        msb = Regexp.last_match(2).to_i
        lsb = Regexp.last_match(4)
        lsb = lsb.empty? ? nil : lsb.to_i
      end

      sync_up
      put("9^#{clean(net)}")

      m = get.strip
      if m == 'FAIL'
        return nil
      else
        m = m.to_i
        if msb
          # Setting a range of bits
          if lsb
            m[msb..lsb]
          else
            m[msb]
          end
        else
          m
        end
      end
    end

    # Forces the given value to the given net.
    # Note that no error checking is done and no error will be communicated if an illegal
    # net is supplied. The user should follow up with a peek if they want to verify that
    # the poke was applied.
    def poke(net, value)
      # The Verilog spec does not specify that underlying VPI put method should
      # handle a part select, so some simulators do not handle it. Therefore we
      # deal with it here to ensure cross simulator compatibility.

      # http://rubular.com/r/eTVGzrYmXQ
      if net =~ /(.*)\[(\d+):?(\.\.)?(\d*)\]$/
        path = Regexp.last_match(1)
        msb = Regexp.last_match(2).to_i
        lsb = Regexp.last_match(4)
        lsb = lsb.empty? ? nil : lsb.to_i

        v = peek(path)
        return nil unless v

        # Setting a range of bits
        if lsb
          upper = v >> (msb + 1)
          # Make sure value does not overflow
          value = value[(msb - lsb)..0]
          if lsb == 0
            value = (upper << (msb + 1)) | value
          else
            lower = v[(lsb - 1)..0]
            value = (upper << (msb + 1)) |
                    (value << lsb) | lower
          end

        # Setting a single bit
        else
          if msb == 0
            upper = v >> 1
            value = (upper << 1) | value[0]
          else
            lower = v[(msb - 1)..0]
            upper = v >> (msb + 1)
            value = (upper << (msb + 1)) |
                    (value[0] << msb) | lower
          end
        end
        net = path
      end

      sync_up
      put("b^#{clean(net)}^#{value}")
    end

    def interactive_shutdown
      @interactive_mode = true
    end

    # Stop the simulator
    def stop
      Origen.listeners_for(:simulation_shutdown).each(&:simulation_shutdown)
      ended = Time.now
      end_simulation
      # Give the simulator a few seconds to shut down, otherwise kill it
      sleep 1 while running? && (Time.now - ended) < 5
      Process.kill(15, pid) if running?
      sleep 0.1
      # Leave the pid file around if we couldn't verify the simulator
      # has stopped
      FileUtils.rm_f(pid_file) if File.exist?(pid_file) && !running?
      @socket.close if @socket
      File.unlink(socket_id) if File.exist?(socket_id)
    end

    def on_origen_shutdown
      if @enabled
        unless @interactive_mode
          Origen.log.debug 'Shutting down simulator...'
          unless @failed_to_start
            c = error_count
            if c > 0
              @failed = true
              Origen.log.error "The simulation failed with #{c} errors!"
            end
          end
        end
        stop
        unless @interactive_mode
          if failed
            Origen.app.stats.report_fail
          else
            Origen.app.stats.report_pass
          end
        end
        if view_wave_command
          puts
          puts 'To view the simulation run the following command:'
          puts
          puts "  #{view_wave_command}"
          puts
        end
      end
    ensure
      Process.kill(15, pid) if @enabled && running?
    end

    def socket_id
      @socket_id ||= "/tmp/#{socket_number}.sock"
    end

    def socket_number
      @socket_number ||= (Process.pid.to_s + Time.now.to_f.to_s).sub('.', '')
    end

    def simulation_tester?
      (tester && tester.is_a?(OrigenSim::Tester))
    end

    def timeout_connection(wait_in_s)
      @connection_timed_out = false
      t = Thread.new do
        sleep wait_in_s
        # If the Verilog process has not established a connection yet, then make one to
        # release our process and then exit
        unless @connection_established
          @connection_timed_out = true
          UNIXSocket.new(socket_id).puts(message)
        end
      end
      yield
    end

    private

    def clean(net)
      if net =~ /^dut\./
        "origen.#{net}"
      else
        net
      end
    end
  end
end
