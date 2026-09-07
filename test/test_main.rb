# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'stringio'
require 'json'
require 'rbconfig'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m"   # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Capture everything written to $stdout while the block runs.
# SystemExit raised inside the block propagates after $stdout is restored.
def capture_stdout
  old = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  captured = $stdout.string if $stdout.is_a?(StringIO)
  $stdout = old
  @last_stdout = captured
end

# Set $CHILD_STATUS ($?) to a non-zero exit code without touching the shell or
# any external toolchain: only the already-running Ruby interpreter is spawned.
def set_child_status(code)
  Process.wait(Process.spawn(RbConfig.ruby, '-e', "exit #{code}"))
end

# Stub Kernel#system on the example so that no command is ever executed.
# Returns the array that collects the composed command strings.
def stub_system(success: true, exit_code: 0)
  captured = []
  allow(self).to receive(:system) do |cmd|
    captured << cmd
    set_child_status(exit_code) unless success
    success
  end
  captured
end

# Kernel#system(nil) raises TypeError before spawning anything; make the stub
# reproduce that so the nil-command tests never reach a shell either.
def stub_system_passthrough_nil
  allow(self).to receive(:system) do |cmd|
    raise TypeError, 'no implicit conversion of nil into String' if cmd.nil?

    true
  end
end

# Every ENV key main.rb reads. Passing nil to Open3.capture3 unsets the key in
# the child, isolating the subprocess tests from the ambient environment.
MAIN_ENV_KEYS = %w[
  HOME
  AC_CACHE_INCLUDED_PATHS
  AC_CACHE_EXCLUDED_PATHS
  AC_REPOSITORY_DIR
  AC_CACHE_LABEL
  AC_TOKEN_ID
  AC_CALLBACK_URL
  AC_OUTPUT_DIR
  AC_CACHE_PROVIDER
  AC_CACHE_UPLOAD_URL
  _TEST_HTTP_CODE
  _TEST_HTTP_BODY
].freeze

# Preloaded into the child via RUBYOPT=-r<file>. It replaces Kernel#system and
# Net::HTTP.get_response so the subprocess never runs zip/curl/find/rm and never
# opens a network connection. Every stubbed call is echoed to stdout so the
# tests can assert the composed command strings.
MAIN_STUB_SOURCE = <<~'RUBY_SRC'
  require 'net/http'

  module Kernel
    def system(*args)
      $stdout.puts "[stub-system] #{args.join(' ')}"
      true
    end
  end

  class StubHttpResponse
    attr_reader :body

    def initialize(code, body)
      @code = code.to_s
      @body = body
    end

    def code
      @code
    end

    def message
      'STUB'
    end

    def is_a?(klass)
      return @code.to_i.between?(200, 299) if klass == Net::HTTPSuccess

      super
    end
  end

  Net::HTTP.singleton_class.send(:define_method, :get_response) do |uri, *_rest|
    $stdout.puts "[stub-http] GET #{uri}"
    StubHttpResponse.new(ENV.fetch('_TEST_HTTP_CODE', '200'), ENV.fetch('_TEST_HTTP_BODY', ''))
  end
RUBY_SRC

# Run main.rb in a subprocess with a controlled ENV and the stub preloaded.
# Returns [stdout, stderr, status]. `chdir` defaults to a throw-away tmpdir so
# the script never writes outside of it.
def run_main(env = {}, chdir: nil)
  Dir.mktmpdir('cache_push_main') do |tmp|
    stub_path = File.join(tmp, 'main_stub.rb')
    File.write(stub_path, MAIN_STUB_SOURCE)

    clean_env = MAIN_ENV_KEYS.to_h { |k| [k, nil] }.merge(env)
    clean_env['RUBYOPT'] = ["-r#{stub_path}", ENV['RUBYOPT']].compact.join(' ')

    Open3.capture3(clean_env, "ruby #{MAIN_RB}", chdir: chdir || tmp)
  end
end

# A complete, valid ENV for main.rb. Callers merge overrides on top.
def valid_main_env(repo_dir, overrides = {})
  {
    'HOME'                    => repo_dir,
    'AC_CACHE_INCLUDED_PATHS' => 'src',
    'AC_CACHE_LABEL'          => 'main/cache',
    'AC_TOKEN_ID'             => 'token-123',
    'AC_CALLBACK_URL'         => 'https://api.example.test/callback',
    'AC_REPOSITORY_DIR'       => repo_dir
  }.merge(overrides)
end

def signed_response_body(upload_url: 'https://upload.example.test/put', http_method: 'PUT', sign_params: nil)
  configuration = { 'httpMethod' => http_method }
  configuration['signParameters'] = sign_params if sign_params
  { 'uploadInformation' => { 'uploadUrl' => upload_url, 'configuration' => configuration } }.to_json
end

# Build a repository tree + the pre-existing cache zip main.rb expects to find
# after its (stubbed) zip command has "run".
def prepare_cache_workspace(tmp, label: 'main/cache')
  FileUtils.mkdir_p(File.join(tmp, 'repo', 'src'))
  File.write(File.join(tmp, 'repo', 'src', 'a.txt'), 'a')
  FileUtils.mkdir_p(File.join(tmp, 'ac_cache'))
  File.write(File.join(tmp, 'ac_cache', "#{label.gsub('/', '_')}.zip"), 'fake zip content')
  File.join(tmp, 'repo')
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env_variable' do
  around do |example|
    old = ENV['_TEST_VAR']
    example.run
    old.nil? ? ENV.delete('_TEST_VAR') : ENV['_TEST_VAR'] = old
  end

  it 'returns the value when the key is set' do
    ENV['_TEST_VAR'] = 'hello'
    expect(get_env_variable('_TEST_VAR')).to eq('hello')
  end

  it 'strips surrounding whitespace' do
    ENV['_TEST_VAR'] = "  hello \n"
    expect(get_env_variable('_TEST_VAR')).to eq('hello')
  end

  it 'returns nil when the key is missing' do
    ENV.delete('_TEST_VAR')
    expect(get_env_variable('_TEST_VAR')).to be_nil
  end

  it 'returns nil when the value is an empty string' do
    ENV['_TEST_VAR'] = ''
    expect(get_env_variable('_TEST_VAR')).to be_nil
  end

  it 'returns nil when the value is only whitespace' do
    ENV['_TEST_VAR'] = "   \t"
    expect(get_env_variable('_TEST_VAR')).to be_nil
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command' do
  it 'passes the command string to system untouched and does not exit on success' do
    captured = stub_system
    expect { run_command('zip -v |head -2') }.not_to raise_error
    expect(captured).to eq(['zip -v |head -2'])
  end

  it 'exits with status 0 and reports the child exit code when the command fails' do
    stub_system(success: false, exit_code: 3)
    expect {
      capture_stdout { run_command('zip -r broken.zip missing') }
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to include('@@[error] Unexpected exit with code 3')
  end

  it 'raises TypeError for a nil command (system(nil))' do
    stub_system_passthrough_nil
    expect { run_command(nil) }.to raise_error(TypeError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command_with_log' do
  it 'logs the command, runs it, and prints the elapsed time' do
    captured = stub_system
    out = capture_stdout { run_command_with_log('ls -lh cache.zip') }
    expect(captured).to eq(['ls -lh cache.zip'])
    expect(out).to include('@@[command] ls -lh cache.zip')
    expect(out).to match(/took \d+\.\d+s/)
  end

  it 'exits with status 0 when the underlying command fails' do
    stub_system(success: false, exit_code: 1)
    expect {
      capture_stdout { run_command_with_log('curl -0 -X PUT $AC_CACHE_UPLOAD_URL') }
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to include('@@[command] curl -0 -X PUT $AC_CACHE_UPLOAD_URL')
    expect(@last_stdout).to include('@@[error] Unexpected exit with code 1')
    expect(@last_stdout).not_to match(/took/)
  end

  it 'raises TypeError for a nil command after logging it' do
    stub_system_passthrough_nil
    expect { capture_stdout { run_command_with_log(nil) } }.to raise_error(TypeError)
    expect(@last_stdout).to include('@@[command] ')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#abort_with0' do
  it 'prints the message with the @@[error] prefix and exits with status 0' do
    expect {
      capture_stdout { abort_with0('Included paths must be defined.') }
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to eq("@@[error] Included paths must be defined.\n")
  end

  it 'still exits with status 0 for an empty message' do
    expect { capture_stdout { abort_with0('') } }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to eq("@@[error] \n")
  end

  it 'still exits with status 0 for a nil message' do
    expect { capture_stdout { abort_with0(nil) } }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to eq("@@[error] \n")
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#ac_output_dir' do
  let(:tmpdir) { Dir.mktmpdir('ac_output_dir') }

  around do |example|
    old = ENV['AC_OUTPUT_DIR']
    example.run
    old.nil? ? ENV.delete('AC_OUTPUT_DIR') : ENV['AC_OUTPUT_DIR'] = old
  end
  after { FileUtils.rm_rf(tmpdir) }

  it 'returns the directory when AC_OUTPUT_DIR points to an existing directory' do
    ENV['AC_OUTPUT_DIR'] = tmpdir
    expect(ac_output_dir).to eq(tmpdir)
  end

  it 'returns nil when AC_OUTPUT_DIR is not set' do
    ENV.delete('AC_OUTPUT_DIR')
    expect(ac_output_dir).to be_nil
  end

  it 'returns nil when AC_OUTPUT_DIR is empty' do
    ENV['AC_OUTPUT_DIR'] = ''
    expect(ac_output_dir).to be_nil
  end

  it 'returns nil when AC_OUTPUT_DIR points to a missing directory' do
    ENV['AC_OUTPUT_DIR'] = File.join(tmpdir, 'does-not-exist')
    expect(ac_output_dir).to be_nil
  end

  it 'returns nil when AC_OUTPUT_DIR points to a file instead of a directory' do
    file = File.join(tmpdir, 'file.txt')
    File.write(file, 'x')
    ENV['AC_OUTPUT_DIR'] = file
    expect(ac_output_dir).to be_nil
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#expand_exclude' do
  # expand_exclude uses delete_suffix!, which mutates its argument. main.rb
  # always passes ENV-derived (unfrozen) strings, so the tests do the same.
  it 'quotes a plain pattern' do
    expect(expand_exclude('*.apk')).to eq('"*.apk"')
  end

  it 'quotes a path pattern' do
    expect(expand_exclude('.gradle/*.lock')).to eq('".gradle/*.lock"')
  end

  it 'turns a /\* suffix into a folder exclude' do
    expect(expand_exclude(+'app/gradle*/\*')).to eq('"app/gradle*/*"')
  end

  it 'adds a root-level variant for a recursive /\* pattern' do
    expect(expand_exclude(+'**/gradle*/\*')).to eq('"**/gradle*/*" "gradle*/*"')
  end

  it 'keeps a recursive pattern without the /\* suffix as-is' do
    expect(expand_exclude('**/gradle*')).to eq('"**/gradle*"')
  end

  it 'returns an empty quoted string for an empty pattern' do
    expect(expand_exclude('')).to eq('""')
  end

  it 'raises NoMethodError for a nil pattern' do
    expect { expand_exclude(nil) }.to raise_error(NoMethodError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#add_includes' do
  let(:zip) { 'zip -r -FS out.zip' }

  it 'appends every path to the zip command' do
    expect(add_includes(%w[.gradle app/build], zip)).to eq('zip -r -FS out.zip .gradle app/build')
  end

  it 'skips "." and ".." entries' do
    expect(add_includes(['.', '..', 'src'], zip)).to eq('zip -r -FS out.zip src')
  end

  it 'skips entries ending in "/." or "/.."' do
    expect(add_includes(['app/.', 'app/..', 'app/x'], zip)).to eq('zip -r -FS out.zip app/x')
  end

  it 'returns the command unchanged for an empty list' do
    expect(add_includes([], zip)).to eq(zip)
  end

  it 'does not mutate the original zip string' do
    original = +'zip -r -FS out.zip'
    add_includes(['src'], original)
    expect(original).to eq('zip -r -FS out.zip')
  end

  it 'raises NoMethodError for a nil list' do
    expect { add_includes(nil, zip) }.to raise_error(NoMethodError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#add_excludes' do
  let(:zip) { 'zip -r -FS out.zip src' }

  it 'appends -x followed by each expanded exclude' do
    expect(add_excludes(['*.apk', +'**/gradle*/\*'], zip))
      .to eq('zip -r -FS out.zip src -x "*.apk" "**/gradle*/*" "gradle*/*"')
  end

  it 'returns the command unchanged for an empty list' do
    expect(add_excludes([], zip)).to eq(zip)
  end

  it 'returns the command unchanged for the Hash default empty string' do
    # get_excluded_paths builds Hash.new(''), so unknown base paths yield ''.
    expect(add_excludes(Hash.new('')['/unknown'], zip)).to eq(zip)
  end

  it 'raises NoMethodError for a nil list' do
    expect { add_excludes(nil, zip) }.to raise_error(NoMethodError)
  end

  it 'propagates NoMethodError for a nil element' do
    expect { add_excludes([nil], zip) }.to raise_error(NoMethodError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#add_log_file' do
  let(:zip) { 'zip -r -FS out.zip src' }

  context 'when an output directory is available' do
    before { allow(self).to receive(:ac_output_dir).and_return('/tmp/out') }

    it 'creates the log folder and redirects zip output into the log file' do
      captured = stub_system
      result = add_log_file('/tmp/out/ac_cache/label', 'src.zip.log', zip)
      expect(captured).to eq(['mkdir -p /tmp/out/ac_cache/label'])
      expect(result).to eq('zip -r -FS out.zip src > /tmp/out/ac_cache/label/src.zip.log')
    end
  end

  context 'when no output directory is available' do
    before { allow(self).to receive(:ac_output_dir).and_return(nil) }

    it 'returns the command unchanged and does not run mkdir' do
      captured = stub_system
      expect(add_log_file('/tmp/out/ac_cache/label', 'src.zip.log', zip)).to eq(zip)
      expect(captured).to be_empty
    end

    it 'returns nil unchanged for a nil command' do
      expect(add_log_file('/tmp/out', 'x.log', nil)).to be_nil
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_zip' do
  it 'runs the zip command with logging and then lists the resulting file' do
    captured = stub_system
    out = capture_stdout { run_zip('/work/ac_cache/label/src.zip', 'zip -r -FS /work/ac_cache/label/src.zip src') }
    expect(captured).to eq([
      'zip -r -FS /work/ac_cache/label/src.zip src',
      'ls -lh /work/ac_cache/label/src.zip'
    ])
    expect(out).to include('@@[command] zip -r -FS /work/ac_cache/label/src.zip src')
  end

  it 'exits with status 0 and skips the listing when zip fails' do
    captured = stub_system(success: false, exit_code: 12)
    expect {
      capture_stdout { run_zip('/work/out.zip', 'zip -r -FS /work/out.zip src') }
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(captured).to eq(['zip -r -FS /work/out.zip src'])
    expect(@last_stdout).to include('@@[error] Unexpected exit with code 12')
  end

  it 'raises TypeError for a nil zip command' do
    stub_system_passthrough_nil
    expect { capture_stdout { run_zip('/work/out.zip', nil) } }.to raise_error(TypeError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#cache_path' do
  let(:tmpdir)   { File.realpath(Dir.mktmpdir('cache_path')) }
  let(:workdir)  { File.join(tmpdir, 'work') }
  let(:repo)     { File.join(tmpdir, 'repo') }
  let(:env_dirs) { Hash.new('') }

  before do
    @cache = 'ac_cache/main_cache'
    FileUtils.mkdir_p(workdir)
    FileUtils.mkdir_p(File.join(repo, 'src'))
    FileUtils.mkdir_p(File.join(repo, '.gradle'))
    File.write(File.join(repo, 'src', 'a.txt'), 'a')
    File.write(File.join(repo, 'gradle.properties'), 'x')
    @orig_cwd = Dir.pwd
    Dir.chdir(workdir)
    allow(self).to receive(:ac_output_dir).and_return(nil)
  end

  after do
    Dir.chdir(@orig_cwd)
    FileUtils.rm_rf(tmpdir)
  end

  it 'composes the zip command for matching paths and returns the zip file path' do
    captured = stub_system
    zip_file = nil
    out = capture_stdout { zip_file = cache_path(repo, 'src', [], env_dirs) }

    expect(zip_file).to eq("#{workdir}/ac_cache/main_cache#{repo}/src.zip")
    expect(out).to include("Include: src in #{repo}")
    expect(captured).to eq([
      "mkdir -p #{workdir}/ac_cache/main_cache#{repo}",
      "zip -r -FS #{zip_file} src",
      "ls -lh #{zip_file}"
    ])
  end

  it 'expands glob patterns, applies excludes and encodes slashes in the zip name' do
    captured = stub_system
    zip_file = nil
    capture_stdout { zip_file = cache_path(repo, 'src/*', ['*.apk', +'**/gradle*/\*'], env_dirs) }

    expect(zip_file).to eq("#{workdir}/ac_cache/main_cache#{repo}/src_*.zip")
    expect(captured[1]).to eq("zip -r -FS #{zip_file} src/a.txt -x \"*.apk\" \"**/gradle*/*\" \"gradle*/*\"")
  end

  it 'includes dot-files via FNM_DOTMATCH but skips "." and ".." entries' do
    captured = stub_system
    capture_stdout { cache_path(repo, '*', [], env_dirs) }
    zip_cmd = captured[1]
    expect(zip_cmd).to include(' .gradle')
    expect(zip_cmd).to include(' src')
    expect(zip_cmd).not_to match(/ \.( |$)/)
    expect(zip_cmd).not_to match(/ \.\.( |$)/)
  end

  it 'maps the base path onto its AC_ environment variable name when known' do
    captured = stub_system
    env_dirs[repo] = 'AC_REPOSITORY_DIR'
    zip_file = nil
    capture_stdout { zip_file = cache_path(repo, 'src', [], env_dirs) }

    expect(zip_file).to eq("#{workdir}/ac_cache/main_cache/AC_REPOSITORY_DIR/src.zip")
    expect(captured.first).to eq("mkdir -p #{workdir}/ac_cache/main_cache/AC_REPOSITORY_DIR")
  end

  it 'redirects zip output to a log file when an output dir is available' do
    allow(self).to receive(:ac_output_dir).and_return('/out')
    captured = stub_system
    zip_file = nil
    capture_stdout { zip_file = cache_path(repo, 'src', [], env_dirs) }

    expect(captured).to include("mkdir -p /out/ac_cache/main_cache#{repo}")
    expect(captured).to include("zip -r -FS #{zip_file} src > /out/ac_cache/main_cache#{repo}/src.zip.log")
  end

  it 'restores the working directory after zipping' do
    stub_system
    capture_stdout { cache_path(repo, 'src', [], env_dirs) }
    expect(Dir.pwd).to eq(File.realpath(workdir))
  end

  it 'returns nil and warns when the base path does not exist' do
    captured = stub_system
    result = nil
    out = capture_stdout { result = cache_path(File.join(tmpdir, 'missing'), 'src', [], env_dirs) }
    expect(result).to be_nil
    expect(out).to include("Warning: #{File.join(tmpdir, 'missing')} doesn't exist yet.")
    expect(captured).to be_empty
  end

  it 'returns nil without running anything when the include matches nothing' do
    captured = stub_system
    result = nil
    capture_stdout { result = cache_path(repo, 'no-such-folder/**', [], env_dirs) }
    expect(result).to be_nil
    expect(captured).to be_empty
    expect(Dir.pwd).to eq(File.realpath(workdir))
  end

  it 'returns nil for an empty include pattern' do
    captured = stub_system
    result = nil
    capture_stdout { result = cache_path(repo, '', [], env_dirs) }
    expect(result).to be_nil
    expect(captured).to be_empty
  end

  it 'exits with status 0 when the zip command fails' do
    stub_system(success: false, exit_code: 15)
    expect {
      capture_stdout { cache_path(repo, 'src', [], env_dirs) }
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    expect(@last_stdout).to include('@@[error] Unexpected exit with code 15')
  end

  it 'raises TypeError when base_path is nil (e.g. HOME unset for a ~/ include)' do
    expect { capture_stdout { cache_path(nil, '.gradle', [], env_dirs) } }.to raise_error(TypeError)
  end

  it 'treats a nil included_path as an empty glob and returns nil' do
    captured = stub_system
    result = nil
    capture_stdout { result = cache_path(repo, nil, [], env_dirs) }
    expect(result).to be_nil
    expect(captured).to be_empty
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#search_env_dirs' do
  let(:env_dirs) { { '/Volumes/agent/temp' => 'AC_TEMP_DIR', '/Volumes/agent/repo' => 'AC_REPOSITORY_DIR' } }

  it 'returns the path when it is an env dir itself' do
    expect(search_env_dirs('/Volumes/agent/temp', env_dirs)).to eq('/Volumes/agent/temp')
  end

  it 'walks up the tree until it finds an env dir ancestor' do
    expect(search_env_dirs('/Volumes/agent/temp/derived/data', env_dirs)).to eq('/Volumes/agent/temp')
  end

  it 'returns nil when no ancestor is an env dir' do
    expect(search_env_dirs('/usr/local/lib', env_dirs)).to be_nil
  end

  it 'returns nil for a root-level path' do
    expect(search_env_dirs('/tmp', env_dirs)).to be_nil
  end

  it 'raises NoMethodError for a path without any slash (rindex returns nil)' do
    expect { search_env_dirs('relative', env_dirs) }.to raise_error(NoMethodError)
  end

  it 'raises NoMethodError for an empty path' do
    expect { search_env_dirs('', env_dirs) }.to raise_error(NoMethodError)
  end

  it 'returns nil when env_dirs is empty' do
    expect(search_env_dirs('/Volumes/agent/temp/x', {})).to be_nil
  end

  it 'raises NoMethodError for a nil path' do
    expect { search_env_dirs(nil, env_dirs) }.to raise_error(NoMethodError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#find_base_path' do
  let(:env_dirs) { { '/Volumes/agent/temp' => 'AC_TEMP_DIR' } }

  it 'returns the parent folder of a plain absolute path' do
    expect(find_base_path('/usr/local/lib/file.txt', {})).to eq('/usr/local/lib')
  end

  it 'stops at the first glob segment' do
    expect(find_base_path('/usr/local/**/*.lock', {})).to eq('/usr/local')
  end

  it 'prefers the matching env dir ancestor over the literal parent' do
    expect(find_base_path('/Volumes/agent/temp/sim/DerivedData', env_dirs)).to eq('/Volumes/agent/temp')
  end

  it 'returns the env dir itself when the path is directly under it' do
    expect(find_base_path('/Volumes/agent/temp/DerivedData', env_dirs)).to eq('/Volumes/agent/temp')
  end

  # A single-segment absolute path yields an empty base, which search_env_dirs
  # cannot handle (''.rindex('/') is nil). Documented as the current behavior.
  it 'raises NoMethodError for a single-segment absolute path' do
    expect { find_base_path('/file.txt', {}) }.to raise_error(NoMethodError)
  end

  it 'raises NoMethodError for a root glob' do
    expect { find_base_path('/*', {}) }.to raise_error(NoMethodError)
  end

  it 'raises NoMethodError for an empty path' do
    expect { find_base_path('', {}) }.to raise_error(NoMethodError)
  end

  it 'raises NoMethodError for a nil path' do
    expect { find_base_path(nil, {}) }.to raise_error(NoMethodError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_excluded_paths' do
  let(:env_dirs) { { '/Volumes/agent/temp' => 'AC_TEMP_DIR' } }

  it 'returns empty home and repository buckets for an empty string' do
    expect(get_excluded_paths('', env_dirs)).to eq({ '~/' => [], '' => [] })
  end

  it 'puts relative patterns into the repository bucket' do
    expect(get_excluded_paths('.gradle/*.lock:*.apk', env_dirs)).to eq({ '~/' => [], '' => ['.gradle/*.lock', '*.apk'] })
  end

  it 'strips the ~/ prefix and puts the pattern into the home bucket' do
    expect(get_excluded_paths('~/.gradle/caches/*.lock', env_dirs)['~/']).to eq(['.gradle/caches/*.lock'])
  end

  it 'groups absolute patterns under their env dir base path' do
    result = get_excluded_paths('/Volumes/agent/temp/sim/*.log', env_dirs)
    expect(result['/Volumes/agent/temp']).to eq(['sim/*.log'])
  end

  it 'groups absolute patterns without env dir under their literal parent' do
    result = get_excluded_paths('/opt/cache/*.tmp:/opt/cache/**/*.bak', env_dirs)
    expect(result['/opt/cache']).to eq(['*.tmp', '**/*.bak'])
  end

  it 'handles a mix of all three kinds at once' do
    result = get_excluded_paths('*.apk:~/.m2/*.lock:/Volumes/agent/temp/x/*.log', env_dirs)
    expect(result['']).to eq(['*.apk'])
    expect(result['~/']).to eq(['.m2/*.lock'])
    expect(result['/Volumes/agent/temp']).to eq(['x/*.log'])
  end

  it 'ignores empty segments from leading, trailing or doubled colons' do
    expect(get_excluded_paths(':*.apk::build/:', env_dirs)['']).to eq(['*.apk', 'build/'])
  end

  it 'returns the Hash default empty string for unknown base paths' do
    expect(get_excluded_paths('', env_dirs)['/nowhere']).to eq('')
  end

  it 'raises NoMethodError for nil' do
    expect { get_excluded_paths(nil, env_dirs) }.to raise_error(NoMethodError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation (subprocess)' do
  # main.rb reports configuration errors through abort_with0, which prints
  # "@@[error] ..." to stdout and exits 0 on purpose so a cache problem never
  # fails the whole build. The assertions therefore check for the error line
  # and that the script stopped before doing any work.
  shared_examples 'aborts before doing any work' do |expected_message, env|
    it "prints '@@[error] #{expected_message}' and stops" do
      out, _err, status = run_main(env)
      expect(status.exitstatus).to eq(0)
      expect(out).to include("@@[error] #{expected_message}")
      expect(out).not_to include('--- Inputs:')
      expect(out).not_to include('[stub-system]')
    end
  end

  let(:tmpdir) { File.realpath(Dir.mktmpdir('env_validation')) }
  let(:base_env) { valid_main_env(tmpdir) }
  after { FileUtils.rm_rf(tmpdir) }

  context 'AC_CACHE_INCLUDED_PATHS' do
    context 'when missing' do
      include_examples 'aborts before doing any work', 'Included paths must be defined.', {}
    end

    context 'when empty' do
      include_examples 'aborts before doing any work', 'Included paths must be defined.',
                       { 'AC_CACHE_INCLUDED_PATHS' => '' }
    end
  end

  context 'AC_CACHE_LABEL' do
    context 'when missing' do
      include_examples 'aborts before doing any work', 'Cache label path must be defined.',
                       { 'AC_CACHE_INCLUDED_PATHS' => 'src' }
    end

    context 'when empty' do
      include_examples 'aborts before doing any work', 'Cache label path must be defined.',
                       { 'AC_CACHE_INCLUDED_PATHS' => 'src', 'AC_CACHE_LABEL' => '' }
    end
  end

  context 'AC_TOKEN_ID' do
    context 'when missing' do
      include_examples 'aborts before doing any work', 'AC_TOKEN_ID env variable must be set when build started.',
                       { 'AC_CACHE_INCLUDED_PATHS' => 'src', 'AC_CACHE_LABEL' => 'label' }
    end

    context 'when empty' do
      include_examples 'aborts before doing any work', 'AC_TOKEN_ID env variable must be set when build started.',
                       { 'AC_CACHE_INCLUDED_PATHS' => 'src', 'AC_CACHE_LABEL' => 'label', 'AC_TOKEN_ID' => '' }
    end
  end

  context 'AC_CALLBACK_URL' do
    context 'when missing' do
      include_examples 'aborts before doing any work', 'AC_CALLBACK_URL env variable must be set when build started.',
                       { 'AC_CACHE_INCLUDED_PATHS' => 'src', 'AC_CACHE_LABEL' => 'label', 'AC_TOKEN_ID' => 't' }
    end

    context 'when empty' do
      include_examples 'aborts before doing any work', 'AC_CALLBACK_URL env variable must be set when build started.',
                       { 'AC_CACHE_INCLUDED_PATHS' => 'src', 'AC_CACHE_LABEL' => 'label', 'AC_TOKEN_ID' => 't',
                         'AC_CALLBACK_URL' => '' }
    end
  end

  context 'HOME' do
    let(:repo) { prepare_cache_workspace(tmpdir) }
    let(:home_env) { valid_main_env(repo, 'AC_CACHE_INCLUDED_PATHS' => '~/.gradle:src') }

    it 'fails with TypeError (non-zero exit) when HOME is missing and a ~/ path is included' do
      out, err, status = run_main(home_env.merge('HOME' => nil), chdir: tmpdir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/TypeError|no implicit conversion of nil into String/)
      expect(out).to include('Include: .gradle in ')
      expect(out).not_to include('[stub-system] zip -r -FS')
    end

    it 'warns and skips the ~/ include when HOME is empty' do
      out, err, status = run_main(home_env.merge('HOME' => '', '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir)
      expect(status.exitstatus).to eq(0), "stdout:\n#{out}\nstderr:\n#{err}"
      expect(out).to include("Warning:  doesn't exist yet. Check folder is correct and available.")
      expect(out).not_to include('.gradle.zip')
      expect(out).to include('[stub-system] curl -0 -X PUT')
    end

    it 'does not need HOME when no ~/ path is included' do
      out, err, status = run_main(valid_main_env(repo, 'HOME' => nil, '_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir)
      expect(status.exitstatus).to eq(0), "stdout:\n#{out}\nstderr:\n#{err}"
      expect(out).to include('--- Inputs:')
      expect(out).to include('[stub-system] curl -0 -X PUT')
    end
  end

  context 'AC_CACHE_UPLOAD_URL (set by main.rb from the signed URL response)' do
    let(:repo) { prepare_cache_workspace(tmpdir) }
    let(:env)  { valid_main_env(repo, 'AC_CACHE_PROVIDER' => 'FILESYSTEM') }

    # The FILESYSTEM provider interpolates ENV['AC_CACHE_UPLOAD_URL'] into the
    # curl command, which makes the resolved value observable from outside.
    it 'ends up unset (blank curl target) when uploadInformation.uploadUrl is missing' do
      body = { 'uploadInformation' => { 'configuration' => { 'httpMethod' => 'PUT' } } }.to_json
      out, _err, status = run_main(env.merge('_TEST_HTTP_BODY' => body), chdir: tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(out).to include("[stub-system] curl -0 --location --request PUT '' --form")
    end

    it 'ends up empty (blank curl target) when uploadInformation.uploadUrl is an empty string' do
      out, _err, status = run_main(env.merge('_TEST_HTTP_BODY' => signed_response_body(upload_url: '')), chdir: tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(out).to include("[stub-system] curl -0 --location --request PUT '' --form")
    end

    it 'is overwritten by the response value even when pre-set in the environment' do
      out, _err, status = run_main(
        env.merge('AC_CACHE_UPLOAD_URL' => 'https://stale.example.test/old',
                  '_TEST_HTTP_BODY' => signed_response_body(upload_url: 'https://fresh.example.test/new')),
        chdir: tmpdir
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include("[stub-system] curl -0 --location --request PUT 'https://fresh.example.test/new' --form")
      expect(out).not_to include('stale.example.test')
    end

    it 'fails with NoMethodError (non-zero exit) when uploadInformation is missing' do
      out, err, status = run_main(env.merge('_TEST_HTTP_BODY' => '{}'), chdir: tmpdir)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/NoMethodError|undefined method/)
      expect(out).not_to include('[stub-system] curl -0 --location')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb end-to-end (subprocess, stubbed toolchain and network)' do
  let(:tmpdir) { File.realpath(Dir.mktmpdir('cache_push_e2e')) }
  let(:repo)   { prepare_cache_workspace(tmpdir) }
  let(:env)    { valid_main_env(repo) }
  after { FileUtils.rm_rf(tmpdir) }

  it 'checks dependencies, zips the include, and uploads with a PUT curl' do
    out, err, status = run_main(env.merge('_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir)

    expect(status.exitstatus).to eq(0), "stdout:\n#{out}\nstderr:\n#{err}"
    expect(out).to include('[stub-system] zip -v |head -2')
    expect(out).to include('[stub-system] curl --version |head -1')
    expect(out).to include("Include: src in #{repo}")
    # AC_REPOSITORY_DIR is an AC_-prefixed env dir, so the zip is filed under its variable name.
    expect(out).to include("[stub-system] zip -r -FS #{tmpdir}/ac_cache/main/cache/AC_REPOSITORY_DIR/src.zip src")
    expect(out).to include("[stub-system] ls -lh #{tmpdir}/ac_cache/main/cache/AC_REPOSITORY_DIR/src.zip")
    expect(out).to include('[stub-system] zip -r -0 -FS ac_cache/main_cache.zip ac_cache/main/cache')
    expect(out).to include('[stub-http] GET https://api.example.test/callback?action=getCacheUrls&cacheKey=main_cache&tokenId=token-123&fileSize=16')
    expect(out).to include("[stub-system] curl -0 -X PUT -H 'Content-Type: application/zip' --upload-file ac_cache/main_cache.zip $AC_CACHE_UPLOAD_URL")
    expect(out).not_to include('@@[error]')
  end

  it 'uploads with a multipart POST including the sign parameters' do
    body = signed_response_body(http_method: 'POST', sign_params: { 'key' => 'k1', 'policy' => 'p1' })
    out, _err, status = run_main(env.merge('_TEST_HTTP_BODY' => body), chdir: tmpdir)

    expect(status.exitstatus).to eq(0)
    expect(out).to include(
      "[stub-system] curl -0 -X POST $AC_CACHE_UPLOAD_URL --form 'key=\"k1\"' --form 'policy=\"p1\"' --form 'file=@ac_cache/main_cache.zip'"
    )
  end

  it 'uses the FILESYSTEM provider curl when AC_CACHE_PROVIDER=FILESYSTEM' do
    out, _err, status = run_main(
      env.merge('AC_CACHE_PROVIDER' => 'FILESYSTEM', '_TEST_HTTP_BODY' => signed_response_body(upload_url: 'http://fs.local/up')),
      chdir: tmpdir
    )

    expect(status.exitstatus).to eq(0)
    expect(out).to include("[stub-system] curl -0 --location --request PUT 'http://fs.local/up' --form 'file=@\"ac_cache/main_cache.zip\"'")
  end

  it 'fails with NoMethodError (non-zero exit) when the response has no configuration' do
    body = { 'uploadInformation' => { 'uploadUrl' => 'https://u.example.test/x' } }.to_json
    out, err, status = run_main(env.merge('_TEST_HTTP_BODY' => body), chdir: tmpdir)

    expect(status.exitstatus).not_to eq(0)
    expect(err).to match(/NoMethodError|undefined method/)
    expect(out).not_to include('[stub-system] curl -0')
  end

  it 'skips the upload when the pulled md5 matches the pushed zip' do
    repo # build the workspace first
    zipped = File.join(tmpdir, 'ac_cache', 'main_cache.zip')
    File.write("#{zipped}.md5", "#{Digest::MD5.file(zipped).hexdigest}\n")
    out, _err, status = run_main(env.merge('_TEST_HTTP_BODY' => signed_response_body), chdir: tmpdir)

    expect(status.exitstatus).to eq(0)
    expect(out).to include('Cache is the same as pulled one. No need to upload.')
    expect(out).not_to include('[stub-http]')
  end

  it 'reports a 4xx signed URL response with status, message and body' do
    out, _err, status = run_main(env.merge('_TEST_HTTP_CODE' => '403', '_TEST_HTTP_BODY' => 'forbidden'), chdir: tmpdir)

    expect(status.exitstatus).to eq(0)
    expect(out).to include("@@[error] Failed to get signed URL. HTTP status code: '403' - message: 'STUB'. Signed URL details response: 'forbidden'.")
  end

  it 'reports a generic failure for a non-success, non-4xx signed URL response' do
    out, _err, status = run_main(env.merge('_TEST_HTTP_CODE' => '302'), chdir: tmpdir)

    expect(status.exitstatus).to eq(0)
    expect(out).to include('@@[error] Failed to get signed URL.')
    expect(out).not_to include('HTTP status code')
  end

  it 'normalizes unsafe characters in AC_CACHE_LABEL' do
    FileUtils.mkdir_p(File.join(tmpdir, 'ac_cache'))
    File.write(File.join(tmpdir, 'ac_cache', 'feat_x_y_cache.zip'), 'z')
    out, _err, status = run_main(
      env.merge('AC_CACHE_LABEL' => 'feat x:y/cache', '_TEST_HTTP_BODY' => signed_response_body),
      chdir: tmpdir
    )

    expect(status.exitstatus).to eq(0)
    expect(out).to include('[stub-system] zip -r -0 -FS ac_cache/feat_x_y_cache.zip ac_cache/feat_x_y/cache')
    expect(out).to include('cacheKey=feat_x_y_cache')
  end

  it 'warns and skips repository-relative includes when AC_REPOSITORY_DIR is unset' do
    out, _err, status = run_main(
      env.merge('AC_REPOSITORY_DIR' => nil, '_TEST_HTTP_BODY' => signed_response_body),
      chdir: tmpdir
    )

    expect(status.exitstatus).to eq(0)
    expect(out).to include('Warning: src is skipped. It can be used only after Git Clone workflow step.')
    expect(out).not_to include('[stub-system] zip -r -FS')
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
# Lines outside the `if __FILE__ == $PROGRAM_NAME` blocks are the function
# definitions exercised in-process. The guarded main blocks only run in the
# subprocess tests, which Coverage cannot instrument, so they are reported apart.
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data = result[main_path]

  # Mark every line that sits inside an `if __FILE__ == $PROGRAM_NAME` block
  # (opened at column 0 and closed by a bare `end` at column 0).
  in_main = []
  inside  = false
  File.readlines(main_path).each do |line|
    inside = true if line.start_with?('if __FILE__ == $PROGRAM_NAME')
    in_main << inside
    inside = false if inside && line.rstrip == 'end'
  end

  lines     = data.each_with_index.reject { |c, _| c.nil? }
  functions = lines.reject { |_, i| in_main[i] }
  main_blk  = lines.select { |_, i| in_main[i] }

  report = lambda do |label, subset|
    total   = subset.size
    covered = subset.count { |c, _| c.to_i > 0 }
    pct     = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
    color   = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
    filled  = (pct / 5).round
    bar     = "\e[32m" + '█' * filled + "\e[90m" + '░' * (20 - filled) + "\e[0m"
    puts "  #{label.ljust(22)} #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
    subset.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }
  end

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report (main.rb)'
  puts "\e[90m#{'─' * 72}\e[0m"
  uncovered = report.call('functions', functions)
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  report.call('main block (in-proc)', main_blk)
  puts "  \e[90mThe main block is covered by the subprocess tests, which are not instrumented.\e[0m"
  report.call('total', lines)
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
