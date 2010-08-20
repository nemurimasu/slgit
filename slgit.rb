#!/usr/bin/env ruby

require 'rubygems'
require 'fssm'
require 'rbconfig'
require 'tmpdir'
require 'grit'

Repositories = ARGV.map { |path| Grit::Repo.new(path) }
SlToRepo = {}
RepoToSl = {}

module Grit
  class Tree
    def recursive_search( file )
      results = trees.map do |t|
        t.recursive_search(file) # search subdirectories
      end.flatten + blobs.select do |b|
        b.name == file # search our directory
      end.map do |b| 
        {:path => "#{b.name}", :blob => b} # wrap blobs in hashes for paths
      end
      # prepend our path to results
      results.each { |m| m[:path] = "#{self.name}/#{m[:path]}" } if self.name
      results
    end
  end
end

# search all working copies to see if the file is new and not checked out
# matches name and contents
def working_copy_search( file, sl_file )
  Repositories.map do |r|
    {:repo => r, :commit => r.head.commit}
  end.each do |m|
    m[:blobs] = Dir.glob("#{m[:repo].working_dir}/**/#{file}").select do |f|
      File.read(f) == sl_file
    end.map do |f|
      {:path => f.partition("#{m[:repo].working_dir}/")[2]}
    end
  end.reject do |m|
    m[:blobs].empty?
  end
end

# find all blobs with matching commit id and file name
# does not check file contents!
def search_repositories( file, version )
  Repositories.map do |r|
    {:repo => r, :commit => r.commit(version)} # select all matching commits across all repositories
  end.reject do |c|
    c[:commit] == nil # remove repos that don't contain a matching commit
  end.each do |c|
    c[:blobs] = c[:repo].tree(c[:commit].id).recursive_search(file) # search for file name
  end.reject do |c|
    c[:blobs].empty? # remove repos that don't contain a matching file
  end
end

# given a file name, a list of matches for name and version, and the contents of
# the file, search all commits after the matches for a file content match
# returns the oldest match for each repository
def future_search( name_matches, file, sl_file )
  matched_repos = []
  name_matches.map do |m|
    m[:repo].commits_between(m[:commit].id, m[:repo].head.commit.id).map do |c|
      {:repo => m[:repo], :commit => c}
    end
  end.flatten.map do |m|
    next if matched_repos.include? m[:repo]
    m[:blobs] = m[:repo].tree(m[:commit].id).recursive_search(file).select do |b|
      b[:blob].data == sl_file
    end
    matched_repos << m[:repo] unless m[:blobs].empty?
    m
  end.reject { |m| m[:blobs].empty? }
end

# returns the directory SL uses for the external editor feature
def external_script_dir
  case Config::CONFIG['target_os']
  when /darwin/i then File.expand_path("#{Dir.tmpdir}/../TemporaryItems/SecondLife")
  else raise 'I don\'t know how to find SL\'s script directory on this platform'
  end
end

# make sure the file in SL has the same version information and contents
def fastforward(name, file, repo_path, sl_file, old_version, new_version)
  working_file = File.read(repo_path)
  if new_version != old_version or working_file != sl_file
    puts "Fastforwarding to working copy"
    File.open(file, 'w') do |w|
      w.puts "//#{name} - #{new_version}"
      w.write working_file
    end
  end
end

def recognize_file( file )
  name = version = dirty = sl_file = nil
  File.open(file) do |f|
    first_line = f.gets
    # this regular expression does not match lines with \ufeff in Ruby 1.8!
    match = first_line.match(/^[\ufeff]?\s*\/\/\s*(.+) -\s?(.*)/u)
    unless match
      puts "Unable to recognize #{file}(no header?)"
      return nil
    end
    name = match[1]
    version = match[2]
    dirty = version.chomp!('+') != nil or version == ''
    puts "Recognized #{name} version #{version} dirty #{dirty}"
    sl_file = f.read
    return {:name => name, :version => version, :dirty => dirty, :content => sl_file}
  end
end

# handle a new or changed file in the external scripts directory
def process_file( file )
  rec = recognize_file(file)
  return unless rec
  name = rec[:name]
  version = rec[:version]
  dirty = rec[:dirty]
  sl_file = rec[:content]
  if SlToRepo[file]
    return if File.read(SlToRepo[file]) == sl_file
    File.open(SlToRepo[file], 'w') do |w|
      w.write(sl_file)
    end
    return
  end
  name_matches = search_repositories("#{name}.lsl", version)
  p name_matches
  # filter out content mismatches
  content_matches = name_matches.map do |m|
    n = m.clone
    n[:blobs] = n[:blobs].select { |b| b[:blob].data == sl_file }
    n
  end.reject { |m| m[:blobs].empty? }
  p content_matches
  # if the file was dirty, then maybe it was commited later
  content_matches = future_search(name_matches, file, sl_file) if content_matches.empty? and dirty
  p content_matches
  # if the file was dirty, maybe it's still in the working directory?
  content_matches = working_copy_search("#{name}.lsl", sl_file) if content_matches.empty? and dirty
  p content_matches
  if content_matches.empty?
    puts "No matches found"
    return
  end
  if content_matches.length > 1
    puts "Multiple repositories matched(did you check the same repository twice?)"
    return
  end
  match = content_matches.first
  blobs = match[:blobs]
  if blobs.length > 1
    puts "Multiple files matched in #{match[:repo]}"
    return
  end
  blob = blobs.first
  # TODO: we should follow renames through history here?
  repo_path = "#{match[:repo].working_dir}/#{blob[:path]}"
  repo_is_head = match[:commit].id == match[:repo].head.commit.id
  SlToRepo[file] = repo_path
  SlToRepo.delete(RepoToSl[repo_path]) if RepoToSl[repo_path]
  RepoToSl[repo_path] = file
  puts "File contents matched commit. SL and repo linked."
  old_version = version
  old_version += '+' if dirty
  new_version = match[:repo].head.commit.id
  new_version += '+' if match[:repo].status[blob[:path]].type != nil
  fastforward(name, file, repo_path, sl_file, old_version, new_version)
end

FSSM.monitor do
  path external_script_dir do
    glob '*_Xed.lsl'

    update do |base, relative|
      sleep 1
      p base, relative
      begin
        process_file("#{base}/#{relative}")
      rescue Exception => e
        puts e.message
        puts e.backtrace
      end
    end

    delete do |base, relative|
      p base, relative
      path = "#{base}/#{relative}"
      if SlToRepo[path]
        RepoToSl.delete(SlToRepo[path])
        SlToRepo.delete(path)
      end
    end

    create do |base, relative|
      sleep 1
      p base, relative
      begin
        process_file("#{base}/#{relative}")
      rescue Exception => e
        puts e.message
        puts e.backtrace
      end
    end
  end
  Repositories.each do |r|
    path r.working_dir do
      glob '**/*.lsl'

      update do |base, relative|
        sleep 1
        # TODO: detect head commit changing and update headings?
        # file content changes would do this already
        p base, relative
        begin
          path = "#{base}/#{relative}"
          if RepoToSl[path]
            repo = Repositories.find { |r| path.start_with? r.working_dir }
            repo_path = path[(repo.working_dir.length + 1)..path.length]
            # we need to update the index manually here because Grit won't
            # not updating the status can cause clean files to show as dirty
            Dir.chdir(repo.working_dir) do
              repo.git.update_index({}, '--refresh', '--', repo_path)
            end
            rec = recognize_file(RepoToSl[path])
            old_version = rec[:version]
            new_version = repo.head.commit.id
            p path[(repo.working_dir.length + 1)..path.length]
            p repo.status[repo_path].type
            old_version += '+' if rec[:dirty]
            new_version += '+' if repo.status[path[(repo.working_dir.length + 1)..path.length]].type != nil
            fastforward(File.basename(path, '.lsl'), RepoToSl[path], path, rec[:content], old_version, new_version)
          end
        rescue Exception => e
          puts e.message
          puts e.backtrace
        end
      end

      delete do |base, relative|
        p base, relative
        if RepoToSl[path]
          SlToRepo.delete(RepoToSl[path])
          RepoToSl.delete(path)
        end
      end
    end
  end
end
