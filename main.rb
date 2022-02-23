require 'English'
require 'net/http'
require 'json'
require 'os'
require 'digest'

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
  run_command(command)
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
ac_callback_url = get_env_variable('ASPNETCORE_CALLBACK_URL') ||
                  abort_with0('ASPNETCORE_CALLBACK_URL env variable must be set when build started.')

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

puts 'Inputs:'
puts ac_cache_label
puts ac_cache_included_paths
puts ac_cache_excluded_paths
puts ac_repository_path
puts '------'

system("mkdir -p #{@cache}/repository")

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

def cache_path(base_path, included_path, excluded_paths)
  puts "Global Include: #{included_path}"

  glob_pattern = "#{base_path}/#{included_path}"

  paths = Dir.glob(glob_pattern, File::FNM_DOTMATCH)
  return if paths.empty?

  zip_file = "#{@cache}/#{glob_pattern.gsub('/', '_')}.zip"
  zip = "zip -r -FS #{zip_file}"
  paths.each do |f|
    zip += " #{f}"
  end
  zip += ' -x' unless excluded_paths.empty?
  excluded_paths.each do |excluded|
    zip += " #{expand_exclude(excluded)}"
  end
  if ac_output_dir
    system("mkdir -p #{ac_output_dir}/#{@cache}")
    zip += " > #{ac_output_dir}/#{zip_file}.log"
  end
  run_command_with_log(zip)
  run_command("ls -lh #{zip_file}")
end

def cache_repository_path(base_path, included_path, excluded_paths)
  puts "Repository Include: #{included_path}"

  cwd = Dir.pwd
  Dir.chdir(base_path)
  paths = Dir.glob(included_path.to_s, File::FNM_DOTMATCH)

  if paths.empty?
    Dir.chdir(cwd)
    return
  end

  zip_file = "#{cwd}/#{@cache}/repository/#{included_path.gsub('/', '_')}.zip"
  zip = "zip -r -FS #{zip_file}"
  paths.each do |f|
    next if ['.', '..'].include?(f)
    next if f.end_with?('.') || f.end_with?('..')

    zip += " #{f}"
  end
  zip += ' -x' unless excluded_paths.empty?
  excluded_paths.each do |excluded|
    zip += " #{expand_exclude(excluded)}"
  end
  if ac_output_dir
    system("mkdir -p #{ac_output_dir}/#{@cache}/repository")
    zip += " > #{ac_output_dir}/#{@cache}/repository/#{included_path.gsub('/', '_')}.zip.log"
  end
  run_command_with_log(zip)
  run_command("ls -lh #{zip_file}")

  Dir.chdir(cwd)
end

def home
  if OS.mac?
    ENV['HOME']
  else
    '/setup'
  end
end

def get_excluded_paths(paths)
  r_excludes = []
  g_excludes = []

  paths.split(':').each do |path|
    next if path.empty?

    if path.start_with?('~/')
      path = path[('~/'.length)..-1]
      g_excludes.push("#{home}/#{path}")
    elsif path.start_with?('/')
      g_excludes.push(path)
    else
      r_excludes.push(path)
    end
  end
  { 'global' => g_excludes, 'repository' => r_excludes }
end

excluded_paths = get_excluded_paths(ac_cache_excluded_paths)
puts excluded_paths

ac_cache_included_paths.split(':').each do |included_path|
  next if included_path.empty?

  if included_path.start_with?('~/')
    included_path = included_path[('~/'.length)..-1]
    cache_path(home, included_path, excluded_paths['global'])
  elsif included_path.start_with?('/')
    cache_path('', included_path[1..-1], excluded_paths['global'])
  elsif ac_repository_path
    cache_repository_path(ac_repository_path, included_path, excluded_paths['repository'])
  else
    puts "Warning: #{included_path} is skipped. It can be used only after Git Clone workflow step."
  end
end

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
    puts signed['putUrl']

    ENV['AC_CACHE_PUT_URL'] = signed['putUrl']
    run_command("curl -X PUT -H \"Content-Type: application/zip\" --upload-file #{zipped} $AC_CACHE_PUT_URL")
  end
end
