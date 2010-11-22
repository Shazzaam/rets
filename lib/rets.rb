# Add lib/rets as a default load path.
dir = File.join File.dirname(__FILE__), 'rets'
$:.unshift(dir) unless $:.include?(dir) || $:.include?(File.expand_path(dir))

require 'auth'
require 'client'