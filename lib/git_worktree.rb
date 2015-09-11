require 'rugged'
require_relative 'git_worktree_exception'

class GitWorktree
  attr_accessor :name, :email, :base_name
  ENTRY_KEYS = [:path, :dev, :ino, :mode, :gid, :uid, :ctime, :mtime]
  DEFAULT_FILE_MODE = 0100644
  LOCK_REFERENCE = 'refs/locks'
  MASTER_REF = 'refs/heads/master'

  def initialize(options = {})
    raise ArgumentError, "Must specify path" unless options.key?(:path)
    @path          = options[:path]
    @email         = options[:email]
    @username      = options[:username]
    @bare          = options[:bare]
    @commit_sha    = options[:commit_sha]
    @password      = options[:password]
    @fast_forward_merge = options[:ff] || true
    @ssl_no_verify = options[:ssl_no_verify] || false
    @remote_name   = 'origin'
    @cred          = Rugged::Credentials::UserPassword.new(:username => @username,
                                                           :password => @password)
    @base_name = File.basename(@path)
    process_repo(options)
  end

  def delete_repo
    return false unless @repo
    @repo.close
    FileUtils.rm_rf(@path)
    true
  end

  def add(path, data, commit_sha = nil, default_entry_keys = {})
    entry = {}
    entry[:path] = path
    ENTRY_KEYS.each { |key| entry[key] = default_entry_keys[key] if default_entry_keys.key?(key) }
    entry[:oid]  = @repo.write(data, :blob)
    entry[:mode] ||= DEFAULT_FILE_MODE
    entry[:mtime] ||= Time.now
    current_index(commit_sha).add(entry)
  end

  def remove(path, commit_sha = nil)
    current_index(commit_sha).remove(path)
  end

  def remove_dir(path, commit_sha = nil)
    current_index(commit_sha).remove_dir(path)
  end

  def file_exists?(path, commit_sha = nil)
    !!find_entry(path, commit_sha)
  end

  def directory_exists?(path, commit_sha = nil)
    entry = find_entry(path, commit_sha)
    entry && entry[:type] == :tree
  end

  def read_file(path, commit_sha = nil)
    read_entry(fetch_entry(path, commit_sha))
  end

  def read_entry(entry)
    @repo.lookup(entry[:oid]).content
  end

  def entries(path, commit_sha = nil)
    tree = get_tree(path, commit_sha)
    tree.find_all.collect { |e| e[:name] }
  end

  def nodes(path, commit_sha = nil)
    tree = path.empty? ? lookup_commit_tree(commit_sha || @commit_sha) : get_tree(path, commit_sha)
    entries = tree.find_all
    entries.each do |entry|
      entry[:full_name] = File.join(@base_name, path, entry[:name])
      entry[:rel_path] = File.join(path, entry[:name])
    end
  end

  def save_changes(message, owner = :local)
    cid = commit(message)
    if owner == :local
      lock { merge(cid) }
    else
      merge_and_push(cid)
    end
    true
  end

  def file_attributes(fname)
    walker = Rugged::Walker.new(@repo)
    walker.sorting(Rugged::SORT_DATE)
    walker.push(@repo.ref(MASTER_REF).target)
    commit = walker.find { |c| c.diff(:paths => [fname]).size > 0 }
    return {} unless commit
    {:updated_on => commit.time.gmtime, :updated_by => commit.author[:name]}
  end

  def file_list(commit_sha = nil)
    tree = lookup_commit_tree(commit_sha || @commit_sha)
    return [] unless tree
    tree.walk(:preorder).collect { |root, entry| "#{root}#{entry[:name]}" }
  end

  def find_entry(path, commit_sha = nil)
    get_tree_entry(path, commit_sha)
  end

  def mv_file_with_new_contents(old_file, new_path, new_data, commit_sha = nil, default_entry_keys = {})
    add(new_path, new_data, commit_sha, default_entry_keys)
    remove(old_file, commit_sha)
  end

  def mv_file(old_file, new_file, commit_sha = nil)
    entry = current_index[old_file]
    return unless entry
    entry[:path] = new_file
    current_index(commit_sha).add(entry)
    remove(old_file, commit_sha)
  end

  def mv_dir(old_dir, new_dir, commit_sha = nil)
    raise GitWorktreeException::DirectoryAlreadyExists, new_dir if find_entry(new_dir)
    old_dir = fix_path_mv(old_dir)
    new_dir = fix_path_mv(new_dir)
    updates = current_index(commit_sha).entries.select { |entry| entry[:path].start_with?(old_dir) }
    updates.each do |entry|
      entry[:path] = entry[:path].sub(old_dir, new_dir)
      current_index(commit_sha).add(entry)
    end
    current_index(commit_sha).remove_dir(old_dir)
  end

  private

  def fetch_and_merge
    fetch
    commit = @repo.ref("refs/remotes/#{@remote_name}/master").target
    merge(commit)
  end

  def fetch
    options = {:credentials => @cred}
    ssl_no_verify_options(options) do
      @repo.fetch(@remote_name, options)
    end
  end

  def pull
    lock { fetch_and_merge }
  end

  def merge_and_push(commit)
    rebase = false
    push_lock do
      @saved_cid = @repo.ref(MASTER_REF).target.oid
      merge(commit, rebase)
      rebase = true
      @repo.push(@remote_name, [MASTER_REF], :credentials => @cred)
    end
  end

  def merge(commit, rebase = false)
    master_branch = @repo.ref(MASTER_REF)
    merge_index = master_branch ? @repo.merge_commits(master_branch.target, commit) : nil
    if merge_index && merge_index.conflicts?
      result = differences_with_master(commit)
      raise GitWorktreeException::GitConflicts, result
    end
    commit = rebase(commit, merge_index, master_branch ? master_branch.target : nil) if rebase
    @repo.reset(commit, :soft)
  end

  def rebase(commit, merge_index, parent)
    commit_obj = commit if commit.class == Rugged::Commit
    commit_obj ||= @repo.lookup(commit)
    Rugged::Commit.create(@repo, :author    => commit_obj.author,
                                 :committer => commit_obj.author,
                                 :message   => commit_obj.message,
                                 :parents   => parent ? [parent] : [],
                                 :tree      => merge_index.write_tree(@repo))
  end

  def commit(message)
    tree = @current_index.write_tree(@repo)
    parents = @repo.empty? ? [] : [@repo.ref(MASTER_REF).target].compact
    create_commit(message, tree, parents)
  end

  def process_repo(options)
    if options[:url]
      clone(options[:url])
    elsif options[:new]
      create_repo
    else
      open_repo
    end
  end

  def create_repo
    @repo = @bare ? Rugged::Repository.init_at(@path, :bare) : Rugged::Repository.init_at(@path)
    @repo.config['user.name']  = @username  if @username
    @repo.config['user.email'] = @email if @email
    @repo.config['merge.ff']   = 'only' if @fast_forward_merge
  end

  def open_repo
    @repo = Rugged::Repository.new(@path)
  end

  def clone(url)
    options = {:credentials => @cred, :bare => true, :remote => @remote_name}
    ssl_no_verify_options(options) do
      @repo = Rugged::Repository.clone_at(url, @path, options)
    end
  end

  def fetch_entry(path, commit_sha = nil)
    find_entry(path, commit_sha).tap do |entry|
      raise GitWorktreeException::GitEntryMissing, path unless entry
    end
  end

  def fix_path_mv(dir_name)
    dir_name = dir_name[1..-1] if dir_name[0] == '/'
    dir_name += '/'            if dir_name[-1] != '/'
    dir_name
  end

  def get_tree(path, commit_sha = nil)
    return lookup_commit_tree(commit_sha || @commit_sha) if path.empty?
    entry = get_tree_entry(path, commit_sha)
    raise GitWorktreeException::GitEntryMissing, path unless entry
    raise GitWorktreeException::GitEntryNotADirectory, path  unless entry[:type] == :tree
    @repo.lookup(entry[:oid])
  end

  def lookup_commit_tree(commit_sha = nil)
    return nil unless @repo.branches['master']
    ct = commit_sha ? @repo.lookup(commit_sha) : @repo.branches['master'].target
    ct.tree if ct
  end

  def get_tree_entry(path, commit_sha = nil)
    path = path[1..-1] if path[0] == '/'
    tree = lookup_commit_tree(commit_sha || @commit_sha)
    begin
      entry             = tree.path(path)
      entry[:full_name] = File.join(@base_name, path)
      entry[:rel_path]  = path
    rescue
      return nil
    end
    entry
  end

  def current_index(commit_sha = nil)
    @current_index ||= Rugged::Index.new.tap do |index|
      unless @repo.empty?
        tree = lookup_commit_tree(commit_sha || @commit_sha)
        raise ArgumentError, "Cannot locate commit tree" unless tree
        @current_tree_oid = tree.oid
        index.read_tree(tree)
      end
    end
  end

  def create_commit(message, tree, parents)
    author = {:email => @email, :name => @username, :time => Time.now}
    # Create the actual commit but dont update the reference
    Rugged::Commit.create(@repo, :author  => author,  :committer  => author,
                                 :message => message, :parents    => parents,
                                 :tree    => tree)
  end

  def lock
    @repo.references.create(LOCK_REFERENCE, MASTER_REF)
    yield
  rescue Rugged::ReferenceError
    sleep 0.1
    retry
  ensure
    @repo.references.delete(LOCK_REFERENCE)
  end

  def push_lock
    @repo.references.create(LOCK_REFERENCE, MASTER_REF)
    begin
      yield
    rescue Rugged::ReferenceError => err
      sleep 0.1
      @repo.reset(@saved_cid, :soft)
      fetch_and_merge
      retry
    rescue GitWorktreeException::GitConflicts => err
      @repo.reset(@saved_cid, :soft)
      raise GitWorktreeException::GitConflicts, err.conflicts
    ensure
      @repo.references.delete(LOCK_REFERENCE)
    end
  end

  def differences_with_master(commit)
    differences = {}
    diffs = @repo.diff(commit, @repo.ref(MASTER_REF).target)
    diffs.deltas.each do |delta|
      result = []
      delta.diff.each_line do |line|
        next unless line.addition? || line.deletion?
        result << "+ #{line.content.to_str}"  if line.addition?
        result << "- #{line.content.to_str}"  if line.deletion?
      end
      differences[delta.old_file[:path]] = {:status => delta.status, :diffs => result}
    end
    differences
  end

  def ssl_no_verify_options(options)
    return yield unless @ssl_no_verify
    begin
      options[:ignore_cert_errors] = true
      ENV['GIT_SSL_NO_VERIFY'] = 'false'
      yield
    ensure
      ENV.delete('GIT_SSL_NO_VERIFY')
    end
  end
end
