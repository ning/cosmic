require 'rubygems'
require 'rake'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "cosmos2"
    gem.summary = %Q{Library/tool for automating deployments}
    gem.description = %Q{Library/tool for automating deployments}
    gem.email = "thomas@ning.com"
    gem.homepage = "https://github.com/ning/cosmos2"
    gem.authors = ["Thomas Dudziak"]
    gem.license = 'ASL2'
    gem.required_ruby_version = '>= 1.8.7'
    gem.files = FileList['lib/**/*.rb', 'bin/*', '[A-Z]*'].to_a
    gem.add_development_dependency 'yard', '~> 0.6.1'
    gem.add_dependency 'highline', '~> 1.6.2'
    gem.add_dependency 'net-ldap', '~> 0.2.2'
  end
  Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: gem install jeweler"
end

task :default => :build

begin
  require 'yard'

  YARD::Rake::YardocTask.new
rescue LoadError
  puts "Yard (or a dependency) not available. Install it with: gem install yard"
end

