# Add cosmic library path if necessary
cosmic_lib = File.expand_path("..", __FILE__)
$LOAD_PATH.unshift(cosmic_lib) unless $LOAD_PATH.include?(cosmic_lib)

require 'rubygems'
require 'cosmic/cosmic'
require 'cosmic/patches'

