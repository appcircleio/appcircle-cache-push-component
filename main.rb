require 'English'
require 'net/http'
require 'json'
require 'os'
require 'digest'
require 'set'
require 'find'
require 'open3'
require 'tempfile'

def get_env_variable(key)
  return nil if ENV[key].nil? || ENV[key].strip.empty?

  ENV[key].strip
end

def run_command(command)
  unless system(command)
    puts "@@[error] Unexpected exit with code #{$CHILD_STATUS.exitstatus}. Check logs for details."
    exit 0
  end
end

def run_command_with_log(command)
  puts "@@[command] #{command}"
  s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  run_command(command)
  e = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  puts "took #{(e - s).round(3)}s"
end

def abort_with0(message)
  puts "@@[error] #{message}"
  exit 0
end

ac_cache_included_paths = get_env_variable('AC_CACHE_INCLUDED_PATHS') || abort_with0('Included paths must be defined.')
ac_cache_excluded_paths = get_env_variable('AC_CACHE_EXCLUDED_PATHS') || ''
ac_repository_path = get_env_variable('AC_REPOSITORY_DIR')
ac_cache_label = get_env_variable('AC_CACHE_LABEL') || abort_with0('Cache label path must be defined.')
ac_cache_label = ac_cache_label.gsub(%r{[^A-Za-z0-9_/-]}, '_')
ac_cache_key_file = get_env_variable('AC_CACHE_KEY_FILE')

ac_token_id = get_env_variable('AC_TOKEN_ID') || abort_with0('AC_TOKEN_ID env variable must be set when build started.')
ac_callback_url = get_env_variable('AC_CALLBACK_URL') ||
                  abort_with0('AC_CALLBACK_URL env variable must be set when build started.')

def ac_output_dir
  out_dir = get_env_variable('AC_OUTPUT_DIR')
  out_dir && Dir.exist?(out_dir) ? out_dir : nil
end

signed_url_api = "#{ac_callback_url}?action=getCacheUrls"

if get_env_variable('AC_CACHE_PUSH_SKIP')&.downcase == 'true'
  puts 'AC_CACHE_PUSH_SKIP is true. Cache push is skipped.'
  exit 0
end

def command_exists?(name)
  system("command -v #{name} > /dev/null 2>&1")
end

@cache = "ac_cache/#{ac_cache_label}"
# Remote object name stays "<label>.zip" for backend compatibility. Its content is either a zip
# (legacy) or a tar bundle; cache pull detects the format from the file header.
zipped = "ac_cache/#{ac_cache_label.gsub('/', '_')}.zip"
depkey_file = "#{@cache}/.ac_depkey"

# macOS tar adds AppleDouble "._*" entries for extended attributes unless this is set. They change
# between builds and break the unchanged-cache check. No effect on GNU tar.
ENV['COPYFILE_DISABLE'] = '1'

# zstd is preferred; zip is the fallback for runner images without zstd.
@use_zstd = command_exists?('zstd') && command_exists?('tar')

# An older cache pull writes only "<bundle>.md5" and cannot extract a tar bundle. Keep the zip format
# in that case, so the next build of this workflow can still restore the cache.
if @use_zstd && File.exist?("#{zipped}.md5") && !File.exist?("#{zipped}.digest")
  puts 'Warning: An older Cache Pull version is used in this workflow. Falling back to zip compression ' \
       'so it can restore the cache. Update Cache Pull to use zstd.'
  @use_zstd = false
end

# check dependencies
if @use_zstd
  run_command('zstd --version')
  run_command('tar --version |head -1')
  # GNU tar exits with 1 only when a file changed while being read. Other tar implementations (bsdtar
  # on macOS) use 1 for any error, such as an unreadable file.
  @gnu_tar = `tar --version 2>/dev/null`.include?('GNU tar')
else
  puts 'Warning: zstd is not available on this runner. Falling back to zip compression.' unless command_exists?('zstd')
  run_command('zip -v |head -2')
end
run_command('curl --version |head -1')

puts '--- Inputs:'
puts ac_cache_label
puts ac_cache_included_paths
puts ac_cache_excluded_paths
puts ac_repository_path
puts ac_cache_key_file
puts '-----------'

def resolve_key_file(key_file, repository_path)
  return File.expand_path(key_file) if key_file.start_with?('/', '~/')
  return File.join(repository_path, key_file) if repository_path

  nil
end

# The dependency key covers the lock file content and the cache definition, so changing
# included/excluded paths invalidates the stored key as well.
def compute_depkey(key_file_path:, key_file:, included_paths:, excluded_paths:)
  digest = Digest::SHA256.new
  digest << "#{key_file}\0#{included_paths}\0#{excluded_paths}\0"
  digest.file(key_file_path)
  digest.hexdigest
end

new_depkey = nil
if ac_cache_key_file
  key_file_path = resolve_key_file(ac_cache_key_file, ac_repository_path)
  if key_file_path && File.file?(key_file_path)
    new_depkey = compute_depkey(key_file_path: key_file_path, key_file: ac_cache_key_file,
                                included_paths: ac_cache_included_paths, excluded_paths: ac_cache_excluded_paths)
    stored_depkey = File.file?(depkey_file) ? File.read(depkey_file).strip : nil
    puts "Cache key: #{stored_depkey || '(none)'} =? #{new_depkey}"
    if stored_depkey == new_depkey
      puts "#{ac_cache_key_file} has not changed since the last push. Cache push is skipped."
      exit 0
    end
  else
    puts "Warning: Cache key file #{ac_cache_key_file} is not found. Cache will be pushed."
  end
end

env_dirs = Hash.new('')
ENV.each_pair do |k, v|
  env_dirs[v] = k if k.start_with?('AC_') && File.directory?(v)
end

# Returns the zip -x patterns for one user-defined exclude. A "/\*" suffix excludes the folder content,
# and a "**/" prefixed pattern also gets a variant matching at the root.
def exclude_patterns(pattern)
  return [pattern] unless pattern.end_with?('/\*')

  base = pattern.delete_suffix('/\*')
  patterns = ["#{base}/*"]
  patterns << "#{base.gsub('**/', '')}/*" if base.include?('**/')
  patterns
end

def expand_exclude(pattern)
  exclude_patterns(pattern).map { |p| "\"#{p}\"" }.join(' ')
end

def valid_include?(path)
  return false if ['.', '..'].include?(path)

  !(path.end_with?('.') || path.end_with?('..'))
end

def add_includes(included_paths, zip)
  included_paths.each do |f|
    next unless valid_include?(f)

    zip += " #{f}"
  end
  zip
end

def add_excludes(excluded_paths, zip)
  return zip if excluded_paths.empty?

  zip += ' -x'
  excluded_paths.each do |excluded|
    zip += " #{expand_exclude(excluded)}"
  end
  zip
end

# Mirrors zip -x matching: "*" also matches "/" and dot files, folders are matched with a trailing "/".
def excluded_entry?(entry, patterns)
  patterns.any? { |p| File.fnmatch(p, entry, File::FNM_DOTMATCH) }
end

# Lists the entries to archive relative to the current folder, applying excludes the same way as zip.
def collect_entries(included_paths, excluded_paths)
  # excluded_paths is '' (hash default) when a base path has no excludes
  patterns = excluded_paths.empty? ? [] : excluded_paths.flat_map { |e| exclude_patterns(e) }
  entries = []
  included_paths.each do |included|
    next unless valid_include?(included)

    if File.directory?(included)
      # zip follows an included path that is a symlink to a folder and stores the folder content.
      # A trailing "/" makes Find walk the link target. tar would still store the root itself as a
      # symlink, so the root entry is left out: its content is stored under the link name, and tar
      # creates it as a real folder on extract. Links inside the folder are still stored as links.
      root_is_link = File.symlink?(included)
      root = root_is_link ? "#{included}/" : included
      Find.find(root) do |path|
        next if root_is_link && path == root

        is_dir = File.directory?(path) && (path == root || !File.symlink?(path))
        entry = is_dir && !path.end_with?('/') ? "#{path}/" : path
        entries << path unless excluded_entry?(entry, patterns)
      end
    elsif !excluded_entry?(included, patterns)
      entries << included
    end
  end
  entries.uniq.sort
end

def run_tar_zstd(archive_file, entries)
  Tempfile.create('ac_cache_entries') do |list|
    list.write(entries.join("\0"))
    list.flush
    tar = ['tar', '--null', '--no-recursion', '-T', list.path, '-cf', '-']
    zstd = ['zstd', '-1', '-T0', '-q', '-f', '-o', archive_file]
    puts "@@[command] #{tar.join(' ')} | #{zstd.join(' ')} (#{entries.length} entries)"
    s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    statuses = Open3.pipeline(tar, zstd)
    e = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    tar_status, zstd_status = statuses
    # GNU tar exits with 1 when a file changed while being read; the archive is still complete.
    # Any other non-zero exit (including 1 from bsdtar) can mean a partial archive, so nothing is uploaded.
    tolerated = @gnu_tar ? [0, 1] : [0]
    puts "Warning: tar reported changed files while compressing #{archive_file}." if @gnu_tar && tar_status.exitstatus == 1
    unless tolerated.include?(tar_status.exitstatus) && zstd_status.success?
      abort_with0("Unexpected exit (tar: #{tar_status.exitstatus}, zstd: #{zstd_status.exitstatus}) " \
                  "while compressing #{archive_file}.")
    end
    puts "took #{(e - s).round(3)}s"
  end
  run_command("ls -lh #{archive_file}")
end

def add_log_file(folder, file, zip)
  if ac_output_dir
    system("mkdir -p #{folder}")
    zip += " > #{folder}/#{file}"
  end
  zip
end

def zip_file?(file)
  File.open(file, 'rb') { |f| f.read(2) } == 'PK'
end

# Returns false when zip has nothing to add (exit 12, every file excluded), like the zstd path.
def run_zip(zip_file, zip)
  puts "@@[command] #{zip}"
  s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  system(zip)
  e = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  if $CHILD_STATUS.exitstatus == 12
    puts "Warning: #{zip_file} has no files left after excludes. Skipped."
    system("rm -f #{zip_file}")
    return false
  end
  unless $CHILD_STATUS.success?
    puts "@@[error] Unexpected exit with code #{$CHILD_STATUS.exitstatus}. Check logs for details."
    exit 0
  end
  puts "took #{(e - s).round(3)}s"
  run_command("ls -lh #{zip_file}")
  true
end

def cache_path(base_path, included_path, excluded_paths, env_dirs)
  puts "Include: #{included_path} in #{base_path}"

  unless Dir.exist?(base_path)
    puts "Warning: #{base_path} doesn't exist yet. Check folder is correct and available."
    return nil
  end

  cwd = Dir.pwd
  Dir.chdir(base_path)
  paths = Dir.glob(included_path.to_s, File::FNM_DOTMATCH)

  if paths.empty?
    Dir.chdir(cwd)
    return nil
  end

  base_path = "/#{env_dirs[base_path]}" if env_dirs.key?(base_path)
  system("mkdir -p #{cwd}/#{@cache}#{base_path}")

  if @use_zstd
    archive_file = "#{cwd}/#{@cache}#{base_path}/#{included_path.gsub('/', '_')}.tar.zst"
    entries = collect_entries(paths, excluded_paths)
    if entries.empty?
      puts "Warning: #{included_path} has no files left after excludes. Skipped."
      Dir.chdir(cwd)
      return nil
    end
    run_tar_zstd(archive_file, entries)
    Dir.chdir(cwd)
    return archive_file
  end

  zip_file = "#{cwd}/#{@cache}#{base_path}/#{included_path.gsub('/', '_')}.zip"
  zip = "zip -r -FS #{zip_file}"
  zip = add_includes(paths, zip)
  zip = add_excludes(excluded_paths, zip)
  zip = add_log_file("#{ac_output_dir}/#{@cache}#{base_path}", "#{included_path.gsub('/', '_')}.zip.log", zip)
  zipped_ok = run_zip(zip_file, zip)

  Dir.chdir(cwd)
  zipped_ok ? zip_file : nil
end

def search_env_dirs(path, env_dirs)
  return path if env_dirs.key?(path)

  index_of_slash = path.rindex('/')
  return search_env_dirs(path[0..index_of_slash - 1], env_dirs) if index_of_slash.positive?

  nil
end

def find_base_path(path, env_dirs)
  base_path = ''
  parts = path.split('/')
  order = 1
  parts.each do |w|
    break if order == parts.length
    break if w.include?('*')

    base_path += "/#{w}" unless w.empty?
    order += 1
  end
  env_path = search_env_dirs(base_path, env_dirs)
  env_path || base_path
end

def get_excluded_paths(paths, env_dirs)
  home = '~/'

  excludes = Hash.new('')
  excludes[home] = []
  excludes[''] = [] # repository

  paths.split(':').each do |path|
    next if path.empty?

    if path.start_with?(home)
      path = path[(home.length)..-1]
      excludes[home].push(path)
    elsif path.start_with?('/')
      base_path = find_base_path(path, env_dirs)
      next unless base_path

      excludes[base_path] = [] unless excludes.key?(base_path)
      excludes[base_path].push(path[(base_path.length + 1)..-1])
    else
      excludes[''].push(path)
    end
  end
  excludes
end

excluded_paths = get_excluded_paths(ac_cache_excluded_paths, env_dirs)
puts excluded_paths

uptodate_zips = Set.new([])

ac_cache_included_paths.split(':').each do |included_path|
  next if included_path.empty?

  zip_file = nil
  if included_path.start_with?('~/')
    included_path = included_path[('~/'.length)..-1]
    zip_file = cache_path(ENV['HOME'], included_path, excluded_paths['~/'], env_dirs)
  elsif included_path.start_with?('/')
    base_path = find_base_path(included_path, env_dirs)
    next unless base_path

    zip_file = cache_path(base_path, included_path[(base_path.length + 1)..-1], excluded_paths[base_path], env_dirs)
  elsif ac_repository_path
    zip_file = cache_path(ac_repository_path, included_path, excluded_paths[''], env_dirs)
  else
    puts "Warning: #{included_path} is skipped. It can be used only after Git Clone workflow step."
  end

  uptodate_zips.add(zip_file.sub("#{Dir.pwd}/", '')) if zip_file
end

# remove dead archives (includes) from pulled archives if not in uptodate set
Dir.glob(["#{@cache}/**/*.zip", "#{@cache}/**/*.tar.zst"], File::FNM_DOTMATCH).each do |archive_file|
  unless uptodate_zips.include?(archive_file)
    system("rm -f #{archive_file}")
    puts "Info: #{archive_file} is not in uptodate includes. Removed."
  end
end
system("find #{@cache} -empty -type d -delete")

if new_depkey
  system("mkdir -p #{@cache}")
  File.write(depkey_file, "#{new_depkey}\n")
else
  # No usable key file, so a stale key from a pulled cache must not be pushed again.
  if File.file?(depkey_file)
    File.delete(depkey_file)
    puts 'Info: Stale cache key removed. It is not pushed with this cache.'
  end
end

# Digest of the archives inside the cache folder. Cache pull writes the same digest right after it
# extracts the bundle, so an unchanged cache is detected without building the bundle.
def cache_digest(cache_dir)
  digest = Digest::MD5.new
  Dir.glob("#{cache_dir}/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) }.sort.each do |f|
    digest << "#{f.delete_prefix("#{cache_dir}/")}\0#{Digest::MD5.file(f).hexdigest}\n"
  end
  digest.hexdigest
end

if File.exist?("#{zipped}.digest") && Dir.exist?(@cache)
  pulled_digest = File.read("#{zipped}.digest").strip
  pushed_digest = cache_digest(@cache)
  puts "#{pulled_digest} =? #{pushed_digest}"
  if pulled_digest == pushed_digest
    puts 'Cache is the same as pulled one. No need to upload.'
    exit 0
  end
end

if @use_zstd
  # Inner archives are already compressed, so the outer bundle is a plain tar.
  system("rm -f #{zipped}")
  run_command_with_log("tar -cf #{zipped} #{@cache}")
else
  # zip -FS updates the pulled bundle in place. The pulled bundle can be empty or a tar bundle written
  # by a zstd runner (for example, when an older Cache Pull could not extract it); zip cannot update
  # either, so it is removed first.
  system("rm -f #{zipped}") unless File.size?(zipped) && zip_file?(zipped)
  run_command_with_log("zip -r -0 -FS #{zipped} #{@cache}")
end
run_command("ls -lh #{zipped}")

# Legacy check for caches pulled by an older cache pull version, which only writes the bundle MD5.
if !File.exist?("#{zipped}.digest") && File.exist?("#{zipped}.md5")
  pulled_md5sum = File.open("#{zipped}.md5", 'r', &:readline).strip
  pushed_md5sum = Digest::MD5.file(zipped).hexdigest
  puts "#{pulled_md5sum} =? #{pushed_md5sum}"
  if pulled_md5sum == pushed_md5sum
    puts 'Cache is the same as pulled one. No need to upload.'
    exit 0
  end
end

unless ac_token_id.empty?
  puts ''

  file_size = File.size(zipped)
  safe_label = ac_cache_label.gsub('/', '_')
  ws_signed_url = "#{signed_url_api}&cacheKey=#{safe_label}&tokenId=#{ac_token_id}&fileSize=#{file_size}"
  puts ws_signed_url

  uri = URI(ws_signed_url)
  response = Net::HTTP.get_response(uri)

  if response.is_a?(Net::HTTPSuccess)
    puts 'Uploading cache...'

    signed = JSON.parse(response.body)
    ENV['AC_CACHE_UPLOAD_URL'] = signed['uploadInformation']['uploadUrl']
    puts ENV['AC_CACHE_UPLOAD_URL']

    http_method = signed['uploadInformation']['configuration']['httpMethod']
    sign_params = signed['uploadInformation']['configuration']['signParameters']

    if get_env_variable('AC_CACHE_PROVIDER').eql?('FILESYSTEM')
      curl = 'curl -0 --location --request PUT'
      run_command_with_log("#{curl} '#{ENV['AC_CACHE_UPLOAD_URL']}' --form 'file=@\"#{zipped}\"'")
    else
      curl_base = ["curl -0 -X #{http_method}"]
      url_part = ["$AC_CACHE_UPLOAD_URL"]

      if http_method == "POST"
        form_data = sign_params.map { |k, v| "--form '#{k}=\"#{v}\"'" }
        form_data << "--form 'file=@#{zipped}'"
        curl_cmd = (curl_base + url_part + form_data).join(' ')
      else
        upload_part = [
          "-H 'Content-Type: application/zip'",
          "--upload-file #{zipped}"
        ]
        curl_cmd = (curl_base + upload_part + url_part).join(' ')
      end

      run_command_with_log(curl_cmd)
    end
  elsif response.code.to_i >= 400
    abort_with0("Failed to get signed URL. " +
      "HTTP status code: '#{response.code}' - message: '#{response.message}'. " +
      "Signed URL details response: '#{response.body}'."
    )
  else
    abort_with0("Failed to get signed URL.")
  end
end
