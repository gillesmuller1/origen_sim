# This file should be used to extend the origen with application specific commands

# Map any command aliases here, for example to allow 'origen ex' to refer to a 
# command called execute you would add a reference as shown below: 
aliases ={
#  "ex" => "execute",
}

# The requested command is passed in here as @command, this checks it against
# the above alias table and should not be removed.
@command = aliases[@command] || @command

# Now branch to the specific task code
case @command

# Here is an example of how to implement a command, the logic can go straight
# in here or you can require an external file if preferred.
when "sim:build_example"
  Dir.chdir(Origen.root) do
    output = `origen sim:build  #{Origen.app.remotes_dir}/example_rtl/dut1/dut1.v`
    puts output
    Origen.load_target
    dir = "simulation/default/#{tester.simulator.config[:vendor]}"
    FileUtils.rm_rf(dir) if File.exist?(dir)
    FileUtils.mkdir_p(dir)
    case tester.simulator.config[:vendor]
    when :icarus
      output =~ /  (cd .*)\n/
      system $1
      FileUtils.mv "#{Origen.config.output_directory}/origen.vpi", "simulation/default/icarus"
      output =~ /\n(.*iverilog .*)\n/
      system $1
      FileUtils.mv "origen.vvp", "simulation/default/icarus"

    when :cadence
      output =~ /\n(.*irun .*)\n/
      system $1
      FileUtils.mv "INCA_libs", "simulation/default/cadence"

    when :synopsys
      output =~ /\n(.*vcs .*)\n/
      system $1
      FileUtils.mv "simv", "simulation/default/synopsys"
      FileUtils.mv "simv.daidir", "simulation/default/synopsys"
      FileUtils.rm_rf "csrc"

    end

    puts
    puts "Done, run this command to run a test simulation using #{tester.simulator.config[:vendor]}:"
    puts
    puts "  origen g test"
    puts
  end
  exit 0

## Example of how to make a command to run unit tests, this simply invokes RSpec on
## the spec directory
#when "specs"
#  require "rspec"
#  exit RSpec::Core::Runner.run(['spec'])

## Example of how to make a command to run diff-based tests
#when "examples", "test"
#  Origen.load_application
#  status = 0
#
#  # Compiler tests
#  ARGV = %w(templates/example.txt.erb -t debug -r approved)
#  load "origen/commands/compile.rb"
#  # Pattern generator tests
#  #ARGV = %w(some_pattern -t debug -r approved)
#  #load "#{Origen.top}/lib/origen/commands/generate.rb"
#
#  if Origen.app.stats.changed_files == 0 &&
#     Origen.app.stats.new_files == 0 &&
#     Origen.app.stats.changed_patterns == 0 &&
#     Origen.app.stats.new_patterns == 0
#
#    Origen.app.stats.report_pass
#  else
#    Origen.app.stats.report_fail
#    status = 1
#  end
#  puts
#  if @command == "test"
#    Origen.app.unload_target!
#    require "rspec"
#    result = RSpec::Core::Runner.run(['spec'])
#    status = status == 1 ? 1 : result
#  end
#  exit status  # Exit with a 1 on the event of a failure per std unix result codes

# Always leave an else clause to allow control to fall back through to the
# Origen command handler.
else
  # You probably want to also add the your commands to the help shown via
  # origen -h, you can do this be assigning the required text to @application_commands
  # before handing control back to Origen. Un-comment the example below to get started.
  @application_commands = <<-EOT
 sim:build_example        Build the example simulation object for the current environment setting
  EOT

end 
