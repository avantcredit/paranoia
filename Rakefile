require 'bundler'
Bundler::GemHelper.install_tasks

task :test do
  Dir['test/*_test.rb'].each do |testfile|
    load testfile
  end
end

task :default => :test

import "./lib/tasks/soft_deletes.rake"