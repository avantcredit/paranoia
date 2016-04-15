namespace :soft_deletes do
  desc 'Turn a table into one that can be paranoid and record deletions instead of enabling them, with a view for optional scoping.'
  task :add, [:tables] => :environment do |t, args|
    Paranoia::Schizify.revert(args[:tables])
  end

  desc 'Revert table back to primordial form'
  task :revert, [:tables] => :environment do |t, args|
    Paranoia::Schizify.revert(args[:tables])
  end
end