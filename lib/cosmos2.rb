# Add cosmos2 library path if necessary
cosmos2_lib = File.expand_path("..", __FILE__)
$LOAD_PATH.unshift(cosmos2_lib) unless $LOAD_PATH.include?(cosmos2_lib)

require 'rubygems'
require 'cosmos2/cosmos2'
require 'cosmos2/patches'

