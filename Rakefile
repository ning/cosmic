require 'rubygems'
require 'rake'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "cosmic"
    gem.summary = %Q{Library/tool for automating deployments}
    gem.description = %Q{Library/tool for automating deployments}
    gem.email = "thomas@ning.com"
    gem.homepage = "https://github.com/ning/cosmic"
    gem.authors = ["Thomas Dudziak"]
    gem.license = 'ASL2'
    gem.required_ruby_version = '>= 1.8.7'
    gem.files = FileList['lib/**/*.rb', 'bin/*', '[A-Z]*'].to_a
    gem.add_development_dependency 'yard', '~> 0.6.1'
    gem.add_dependency 'highline', '~> 1.6.9'
    gem.add_dependency 'net-ldap', '~> 0.2.2'
  end
  # Uncomment this to make rake release push to rubygems
  #Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: gem install jeweler"
end

task :default => :build

begin
  require 'yard'

  YARD::Rake::YardocTask.new
rescue LoadError
  puts "Yard (or a dependency) not available. Install it with: gem install yard redcarpet"
end

namespace :docs do

  desc "build docs, into doc/build by default, or override with [<dir>]"
  task :build, [:dir] do |t, args|
    args.with_defaults(:dir => File.join("doc", "build"))
    sh <<-EOS
      mkdir -p #{args.dir}
      sphinx-build -b html doc/source #{args.dir}
    EOS
    Rake::Task["yard"].invoke
  end

  desc "generate documenation and check it into gh-pages branch"
  task :github do
    require 'tmpdir'

    Rake::Task["docs:build"].invoke
    Dir.mktmpdir do |tmp|
      sh <<-EOS
        git fetch origin gh-pages
        if [ -z $(git branch | grep gh-pages) ]
          then
            git branch --track gh-pages origin/gh-pages
        fi
        git clone -b gh-pages . #{tmp}
        cp -r doc/build/* #{tmp}
        cd #{tmp}
        git add -A
        git commit -am 'updating documentation'
        git push origin gh-pages
      EOS
    end
  end
end
