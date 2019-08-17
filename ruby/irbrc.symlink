require 'irb/completion'

IRB.conf[:AUTO_INDENT] = true
IRB.conf[:PROMPT_MODE] = :SIMPLE

begin
  require 'pry'
  Pry.start
  exit
rescue LoadError => e
  warn "=> Unable to load pry"
end

# vim:ft=ruby ts=2 sw=2 sts=2
