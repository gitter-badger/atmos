require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList['test/**/*_test.rb']
end

task :console do
  Bundler.require
  require "atmos"
  ARGV.clear
  require "irb"
  IRB.start
end

task :default => :test

task :docker do
  sh "docker build -t simplygenius/atmos ."
end

task :docker_dev do
  sh "docker build -t simplygenius/atmos-dev -f Dockerfile.dev ."
end
