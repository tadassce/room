# Run: /usr/bin/ruby scripts/tests/test_roomcore_gn.rb
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class RoomCoreGNTest < Minitest::Test
  HELPER = File.expand_path('../lib/roomcore-gn.sh', __dir__).freeze

  def setup
    @root = Dir.mktmpdir('room gn retry ')
    @bin = File.join(@root, 'bin')
    @args = File.join(@root, 'source args.gn')
    @out = File.join(@root, 'out dev')
    @counter = File.join(@root, 'calls')
    FileUtils.mkdir_p(@bin)
    File.write(@args, "is_component_build = true\n")
    File.write(File.join(@bin, 'gn'), <<~RUBY)
      #!/usr/bin/ruby
      count = File.exist?(ENV.fetch('GN_COUNTER')) ? File.read(ENV.fetch('GN_COUNTER')).to_i : 0
      count += 1
      File.write(ENV.fetch('GN_COUNTER'), count.to_s)
      abort 'unexpected GN arguments' unless ARGV == ['gen', ENV.fetch('GN_OUT')]
      exit 42 if ENV['GN_FAIL_FIRST'] == '1' && count == 1
      File.write(File.join(ARGV[1], 'build.ninja'), '# generated fixture')
    RUBY
    File.chmod(0755, File.join(@bin, 'gn'))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def generate(fail_first: false)
    env = { 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'GN_COUNTER' => @counter,
            'GN_OUT' => @out, 'GN_FAIL_FIRST' => fail_first ? '1' : '0' }
    Open3.capture3(env, '/bin/bash', '-c',
                  'set -euo pipefail; source "$1"; roomcore_ensure_gn "$2" "$3"',
                  'gn-retry-test', HELPER, @args, @out).last
  end

  def calls
    File.exist?(@counter) ? File.read(@counter).to_i : 0
  end

  def test_fresh_output_generates_and_identical_successful_output_is_left_alone
    assert generate.success?
    assert File.file?(File.join(@out, 'build.ninja'))
    assert_equal File.read(@args), File.read(File.join(@out, 'args.gn'))
    assert_equal 1, calls
    assert generate.success?
    assert_equal 1, calls
  end

  def test_failed_first_generation_is_retried_even_when_args_are_identical
    first = generate(fail_first: true)
    assert_equal 42, first.exitstatus
    assert File.file?(File.join(@out, 'args.gn'))
    refute File.exist?(File.join(@out, 'build.ninja'))
    assert generate(fail_first: true).success?
    assert File.file?(File.join(@out, 'build.ninja'))
    assert_equal 2, calls
    assert generate(fail_first: true).success?
    assert_equal 2, calls
  end

  def test_changed_args_regenerate_an_existing_build_graph
    assert generate.success?
    File.write(@args, "is_component_build = false\n")
    assert generate.success?
    assert_equal 2, calls
    assert_equal File.read(@args), File.read(File.join(@out, 'args.gn'))
  end

  def test_missing_args_regenerate_even_if_a_graph_exists
    FileUtils.mkdir_p(@out)
    File.write(File.join(@out, 'build.ninja'), '# leftover graph')
    assert generate.success?
    assert_equal 1, calls
    assert_equal File.read(@args), File.read(File.join(@out, 'args.gn'))
  end
end
