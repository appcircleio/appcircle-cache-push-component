require 'English'
require 'net/http'
require 'json'
require 'os'
require 'digest'
require 'set'

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

ac_token_id = get_env_variable('AC_TOKEN_ID') || abort_with0('AC_TOKEN_ID env variable must be set when build started.')
ac_callback_url = get_env_variable('AC_CALLBACK_URL') ||
                  abort_with0('AC_CALLBACK_URL env variable must be set when build started.')

def ac_output_dir
  out_dir = get_env_variable('AC_OUTPUT_DIR')
  out_dir && Dir.exist?(out_dir) ? out_dir : nil
end

signed_url_api = "#{ac_callback_url}?action=getCacheUrls"

# check dependencies
run_command('zip -v |head -2')
run_command('curl --version |head -1')

@cache = "ac_cache/#{ac_cache_label}"
zipped = "ac_cache/#{ac_cache_label.gsub('/', '_')}.zip"

puts '--- Inputs:'
puts ac_cache_label
puts ac_cache_included_paths
puts ac_cache_excluded_paths
puts ac_repository_path
puts '-----------'

env_dirs = Hash.new('')
ENV.each_pair do |k, v|
  env_dirs[v] = k if k.start_with?('AC_') && File.directory?(v)
end

def expand_exclude(pattern)
  if pattern.end_with?('/\*')
    exclude = "#{pattern.delete_suffix!('/\*')}/*"
    exclude = "\"#{exclude}\""
    exclude += " \"#{pattern.gsub('**/', '')}/*\"" if pattern.include? '**/'
  else
    exclude = "\"#{pattern}\""
  end
  exclude
end

def add_includes(included_paths, zip)
  included_paths.each do |f|
    next if ['.', '..'].include?(f)
    next if f.end_with?('.') || f.end_with?('..')

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

def add_log_file(folder, file, zip)
  if ac_output_dir
    system("mkdir -p #{folder}")
    zip += " > #{folder}/#{file}"
  end
  zip
end

def run_zip(zip_file, zip)
  run_command_with_log(zip)
  run_command("ls -lh #{zip_file}")
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
  zip_file = "#{cwd}/#{@cache}#{base_path}/#{included_path.gsub('/', '_')}.zip"
  system("mkdir -p #{cwd}/#{@cache}#{base_path}")
  zip = "zip -r -FS #{zip_file}"
  zip = add_includes(paths, zip)
  zip = add_excludes(excluded_paths, zip)
  zip = add_log_file("#{ac_output_dir}/#{@cache}#{base_path}", "#{included_path.gsub('/', '_')}.zip.log", zip)
  run_zip(zip_file, zip)

  Dir.chdir(cwd)
  zip_file
end

def home
  if OS.mac?
    ENV['HOME']
  else
    '/setup'
  end
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
    zip_file = cache_path(home, included_path, excluded_paths['~/'], env_dirs)
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

# remove dead zips (includes) from pulled zips if not in uptodate set
Dir.glob("#{@cache}/**/*.zip", File::FNM_DOTMATCH).each do |zip_file|
  unless uptodate_zips.include?(zip_file)
    system("rm -f #{zip_file}")
    puts "Info: #{zip_file} is not in uptodate includes. Removed."
  end
end
system("find #{@cache} -empty -type d -delete")

run_command("[ -s #{zipped} ] || rm -f #{zipped}")
run_command_with_log("zip -r -0 -FS #{zipped} #{@cache}")
run_command("ls -lh #{zipped}")

if File.exist?("#{zipped}.md5")
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

  ws_signed_url = "#{signed_url_api}&cacheKey=#{ac_cache_label.gsub('/', '_')}&tokenId=#{ac_token_id}"
  puts ws_signed_url

  uri = URI(ws_signed_url)
  response = Net::HTTP.get(uri)
  unless response.empty?
    puts 'Uploading cache...'

    signed = JSON.parse(response)
    ENV['AC_CACHE_PUT_URL'] = signed['putUrl']
    puts ENV['AC_CACHE_PUT_URL']
    curl = 'curl -0 -X PUT -H "Content-Type: application/zip"'
    run_command_with_log("#{curl} --upload-file #{zipped} $AC_CACHE_PUT_URL")
  end
end
