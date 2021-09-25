# Aliases
Pry.commands.alias_command 'e', 'exit'
Pry.commands.alias_command 'q', 'exit-program'
Pry.commands.alias_command 'w', 'whereami'

if defined?(PryByebug)
  Pry.commands.alias_command 'c', 'continue'
  Pry.commands.alias_command 's', 'step'
  Pry.commands.alias_command 'n', 'next'
  Pry.commands.alias_command 'f', 'finish'
  Pry.commands.alias_command 'whereis', 'show-source'
  Pry.commands.alias_command 'source', 'show-source'
end

# Load all of the configs
def require_rb_files_from(dir)
  Dir.glob(File.join(dir, '*.rb')) do |file|
    require file
  end
end

require_rb_files_from(File.join(ENV['HOME'], '.pryrc.d'))

# Style
Pry.config.editor = 'nvim'

# Grab the clipboard
def pbcopy(str)
  IO.popen('pbcopy', 'r+') { |io| io.puts str }
  output.puts '-- Copy to clipboard --\n#{str}'
end

Pry.config.commands.command 'hiscopy', 'History copy to clipboard' do |n|
  pbcopy _pry_.input_ring[n ? n.to_i : -1]
end

Pry.config.commands.command 'copy', 'Copy to clipboard' do |str|
  unless str
    str = "#{_pry_.input_ring[-1]}#=> #{_pry_.last_result}\n"
  end
  pbcopy str
end

Pry.config.commands.command 'lastcopy', 'Last result copy to clipboard' do
  pbcopy _pry_.last_result.chomp
end

# vim:ft=ruby ts=2 sw=2 sts=2
