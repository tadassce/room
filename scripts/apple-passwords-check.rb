#!/usr/bin/env ruby
# Unapproved Debug build only: real startup gate + native window routing.
# No Apple helper launch, credential request, real browser state or keychain.
require 'fileutils'
require 'open3'
require 'socket'
require 'timeout'

# Check/reap first: even a deadline racing a normal exit cannot signal a
# recycled pid. Until this child is reaped its process-group id is ours.
def stop_owned_group(pid)
  return if Process.waitpid(pid, Process::WNOHANG)
  Process.kill('TERM', -pid)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
  loop do
    return if Process.waitpid(pid, Process::WNOHANG)
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.1
  end
  Process.kill('KILL', -pid)
  Process.waitpid(pid)
rescue Errno::ESRCH, Errno::ECHILD
  # Already exited/reaped.
end

ROOT = File.expand_path('..', __dir__)
app = File.expand_path(ENV.fetch('ROOM_APP', 'build/roomcore/DerivedData/Build/Products/Debug/Room.app'), ROOT)
out = File.expand_path(ARGV.fetch(0, "build/apple-passwords/window-check-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"), ROOT)
state = File.join(out, 'state')
engine = File.join(out, 'engine')
spike = File.join(out, 'spike.txt')
abort 'Use a fresh output directory (state/engine/spike output already exists).' if [state, engine, spike].any? { |p| File.exist?(p) || File.symlink?(p) }
identifier, result = Open3.capture2('/usr/bin/plutil', '-extract', 'CFBundleIdentifier', 'raw', File.join(app, 'Contents/Info.plist'))
abort 'Requires the session Debug app (app.room.desktop.dev), never the user’s Room.' unless result.success? && identifier.strip == 'app.room.desktop.dev'
FileUtils.mkdir_p(out)

# A single loopback fixture, ephemeral port; no other test servers needed.
server = TCPServer.new('127.0.0.1', 0)
url = "http://127.0.0.1:#{server.addr[1]}/"
worker = Thread.new do
  loop do
    client = server.accept
    begin
      while (line = client.gets(8192)) && line != "\r\n"; end
      body = '<!doctype html><meta charset="utf-8"><title>Room WebAuthn window fixture</title><p>Window routing only. No credentials requested.</p>'
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: #{body.bytesize}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n#{body}")
    ensure
      client.close
    end
  end
rescue IOError, Errno::EBADF
  # Closed by the owner in ensure below.
end

pid = nil
begin
  # Direct launch: window identity does not need foreground activation. Own
  # process group + deadline, so a failed probe cannot leave an app running.
  pid = Process.spawn(File.join(app, 'Contents/MacOS/Room'),
                      '-RoomSpike', 'applepasswords', '-RoomSpikeOutput', spike,
                      '-RoomStateDirectory', state, '-RoomEngineDirectory', engine,
                      '-RoomSuggestionsOff', 'YES', '-ApplePersistenceIgnoreState', 'YES',
                      '-RoomApplePasswordsFixtureURL', url, "--log-net-log=#{File.join(out, 'netlog.json')}",
                      pgroup: true, chdir: ROOT, out: File.join(out, 'driver.log'), err: [:child, :out])
  _, status = Timeout.timeout(120) { Process.wait2(pid) }
  pid = nil # Reaped; never signal a pid after it could be reused.
  ok = status.success?
  text = File.exist?(spike) ? File.read(spike) : ''
  puts text
  required = %w[apple_passwords_gate webauthn_fixture webauthn_first_after_second webauthn_second webauthn_detached webauthn_reattached webauthn_moved]
  failed = required.reject { |key| text.lines.any? { |line| line.start_with?("#{key}: passed=true") } }
  failed << 'distinct windows' unless text.lines.any? { |line| line.start_with?('webauthn_windows: distinct=true ') }
  abort "FAIL: #{failed.join(', ')} (see #{out})" unless ok && failed.empty? && text.include?("end: applepasswords\n") && !text.lines.any? { |line| line.start_with?('error:') }
  puts "PASS: startup gate and native-window callback; no credential transaction. Evidence: #{out}"
rescue Timeout::Error
  abort "FAIL: probe exceeded 120 s (see #{out})"
ensure
  stop_owned_group(pid) if pid
  worker.kill
  server.close
  worker.join
end
