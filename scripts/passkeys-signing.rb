#!/usr/bin/env ruby
# Optional Developer ID provisioning for Apple's managed browser passkey capability.
# No credentials are read; the embedded profile and public signer certificate are
# checked again after signing. See --help. Compatible with macOS's system Ruby.
require 'base64'
require 'open3'
require 'pathname'
require 'rexml/document'
require 'tempfile'
require 'time'
require 'tmpdir'

module RoomPasskeysSigning
  PASSKEY = 'com.apple.developer.web-browser.public-key-credential'.freeze
  APP_ID = 'com.apple.application-identifier'.freeze
  TEAM_ID = 'com.apple.developer.team-identifier'.freeze
  EMBEDDED_PROFILE = 'Contents/embedded.provisionprofile'.freeze
  Error = Class.new(StandardError)
  Data = Struct.new(:bytes)

  # Pure functions: fixture dictionaries use Time dates and Data certificate DER.
  # The application identifier prefix can differ from the signing Team ID.
  def self.validate_profile(profile, bundle_id:, now:)
    raise Error, 'profile must be a dictionary' unless profile.is_a?(Hash)
    unless bundle_id.is_a?(String) && bundle_id.match?(/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\z/)
      raise Error, 'Info.plist must contain a valid CFBundleIdentifier'
    end
    unless profile['Platform'].is_a?(Array) && profile['Platform'].include?('OSX')
      raise Error, 'profile must support macOS (Platform: OSX)'
    end
    expiry = profile['ExpirationDate']
    raise Error, 'profile is expired or has no valid ExpirationDate' unless expiry.is_a?(Time) && expiry > now

    entitlements = profile['Entitlements']
    unless entitlements.is_a?(Hash) && entitlements[PASSKEY].equal?(true)
      raise Error, "approved profile must grant #{PASSKEY} as boolean true"
    end
    teams = profile['TeamIdentifier']
    unless teams.is_a?(Array) && teams.size == 1 && identifier_prefix?(teams.first)
      raise Error, 'profile must have exactly one valid TeamIdentifier'
    end
    team = teams.first
    raise Error, 'profile TeamIdentifier and team entitlement disagree' unless entitlements[TEAM_ID] == team

    prefixes = profile['ApplicationIdentifierPrefix']
    unless prefixes.is_a?(Array) && !prefixes.empty? && prefixes.all? { |prefix| identifier_prefix?(prefix) }
      raise Error, 'profile has no valid ApplicationIdentifierPrefix'
    end
    app_id = entitlements[APP_ID]
    unless prefixes.any? { |prefix| app_id == "#{prefix}.#{bundle_id}" }
      raise Error, "profile must grant an exact #{APP_ID} for #{bundle_id} (no wildcard)"
    end
    if entitlements.key?('application-identifier') && entitlements['application-identifier'] != app_id
      raise Error, 'profile application identity entitlements disagree'
    end
    certificates = profile['DeveloperCertificates']
    unless certificates.is_a?(Array) && !certificates.empty? && certificates.all? { |cert| cert.is_a?(Data) && cert.bytes.is_a?(String) && !cert.bytes.empty? }
      raise Error, 'profile has no valid DeveloperCertificates data'
    end
    { PASSKEY => true, APP_ID => app_id, TEAM_ID => team }
  end

  def self.identifier_prefix?(value)
    value.is_a?(String) && value.match?(/\A[A-Z0-9]{10}\z/)
  end

  def self.merge_entitlements(base, profile, bundle_id:, now:)
    raise Error, 'base entitlements must be a dictionary' unless base.is_a?(Hash)
    # Never copy any other profile entitlement (sandbox, debug, keychain groups…).
    base.merge(validate_profile(profile, bundle_id: bundle_id, now: now))
  end

  def self.validate_default(base, embedded_profile:)
    if embedded_profile
      # An unknown or expired profile must not be silently kept or deleted.
      raise Error, 'embedded.provisionprofile exists without ROOM_PASSKEYS_PROFILE; remove it explicitly from this build or opt in with an approved profile'
    end
    unless base.is_a?(Hash) && !base.key?(PASSKEY)
      raise Error, "default entitlements must not contain managed capability #{PASSKEY}"
    end
  end

  def self.validate_certificate(profile, leaf_der)
    certificates = profile['DeveloperCertificates']
    unless certificates.is_a?(Array) && leaf_der.is_a?(String) && !leaf_der.empty? && certificates.any? { |cert| cert.is_a?(Data) && cert.bytes == leaf_der }
      raise Error, 'actual app signer leaf certificate is not in profile DeveloperCertificates; check ROOM_SIGN_IDENTITY'
    end
  end

  def self.validate_signed_entitlements(actual, required)
    unless actual.is_a?(Hash) && required.all? { |key, value| actual[key].eql?(value) }
      raise Error, 'signed main app is missing the approved passkey/application/team entitlements'
    end
  end

  # plutil normalizes XML/binary plists before this small typed stdlib reader.
  # Data and dates stay distinct from strings; JSON conversion would lose them.
  module Plist
    def self.parse(xml)
      root = REXML::Document.new(xml).elements['plist']
      raise Error, 'expected one plist value' unless root && root.elements.size == 1
      decode(root.elements[1])
    rescue REXML::ParseException, ArgumentError => error
      raise Error, "invalid plist: #{error.message}"
    end

    def self.decode(node)
      case node.name
      when 'dict'
        children = node.elements.to_a
        raise Error, 'invalid plist dictionary' unless children.size.even?
        children.each_slice(2).each_with_object({}) do |(key, value), result|
          raise Error, 'invalid or duplicate plist key' unless key.name == 'key' && !result.key?(key.text.to_s)
          result[key.text.to_s] = decode(value)
        end
      when 'array' then node.elements.map { |child| decode(child) }
      when 'string' then node.text.to_s
      when 'true' then true
      when 'false' then false
      when 'date' then Time.iso8601(node.text.to_s)
      when 'data' then Data.new(Base64.strict_decode64(node.text.to_s.gsub(/\s+/, '')))
      when 'integer' then Integer(node.text.to_s, 10)
      when 'real' then Float(node.text.to_s)
      else raise Error, "unsupported plist type #{node.name}"
      end
    end

    def self.dump(value)
      document = REXML::Document.new
      document << REXML::XMLDecl.new('1.0', 'UTF-8')
      document.add_element('plist', 'version' => '1.0').add_element(encode(value))
      document.to_s + "\n"
    end

    def self.encode(value)
      type, text = case value
                   when Hash then ['dict', nil]
                   when Array then ['array', nil]
                   when Data then ['data', Base64.strict_encode64(value.bytes)]
                   when Time then ['date', value.getutc.iso8601]
                   when String then ['string', value]
                   when TrueClass then ['true', nil]
                   when FalseClass then ['false', nil]
                   when Integer then ['integer', value.to_s]
                   when Float then ['real', value.to_s]
                   else raise Error, "unsupported plist value #{value.class}"
                   end
      node = REXML::Element.new(type)
      node.add_text(text) if text
      if value.is_a?(Hash)
        value.each do |key, child|
          node.add_element('key').add_text(key)
          node.add_element(encode(child))
        end
      elsif value.is_a?(Array)
        value.each { |child| node.add_element(encode(child)) }
      end
      node
    end
  end

  def self.command(*args, input: '')
    stdout, stderr, status = Open3.capture3(*args, stdin_data: input, binmode: true)
    raise Error, "#{File.basename(args.first)} failed: #{stderr.strip}" unless status.success?
    stdout
  end

  def self.read_plist(path)
    Plist.parse(command('/usr/bin/plutil', '-convert', 'xml1', '-o', '-', '--', path))
  end

  def self.decode_profile(bytes)
    payload = command('/usr/bin/security', 'cms', '-D', input: bytes)
    Plist.parse(command('/usr/bin/plutil', '-convert', 'xml1', '-o', '-', '--', '-', input: payload))
  end

  def self.prepare(app, base_path, profile_path = nil, output = nil)
    embedded = File.join(app, EMBEDDED_PROFILE)
    base = read_plist(base_path)
    unless profile_path
      validate_default(base, embedded_profile: File.exist?(embedded) || File.symlink?(embedded))
      return
    end
    raise Error, 'ROOM_PASSKEYS_PROFILE must be an absolute profile path' unless Pathname.new(profile_path).absolute?
    raise Error, 'generated entitlements must not overwrite the base file' if File.expand_path(output) == File.expand_path(base_path)

    # Read once: the embedded CMS bytes must be the same ones we validated.
    bytes = File.binread(profile_path)
    profile = decode_profile(bytes)
    bundle_id = read_plist(File.join(app, 'Contents/Info.plist'))['CFBundleIdentifier']
    merged = merge_entitlements(base, profile, bundle_id: bundle_id, now: Time.now)
    File.write(output, Plist.dump(merged))
    Tempfile.create(['room-passkeys-', '.provisionprofile'], File.dirname(embedded)) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      file.chmod(0644)
      File.rename(file.path, embedded)
    end
    puts "passkeys: embedded approved profile for #{bundle_id}; signer must match DeveloperCertificates"
  end

  def self.verify(app)
    command('/usr/bin/codesign', '--verify', '--strict', app)
    profile = decode_profile(File.binread(File.join(app, EMBEDDED_PROFILE)))
    bundle_id = read_plist(File.join(app, 'Contents/Info.plist'))['CFBundleIdentifier']
    required = validate_profile(profile, bundle_id: bundle_id, now: Time.now)
    actual = Plist.parse(command('/usr/bin/codesign', '--display', '--entitlements', ':-', app))
    validate_signed_entitlements(actual, required)
    validate_certificate(profile, signer_certificate(app))
    puts 'passkeys: signed main app entitlements and actual signer certificate match its approved profile'
  end

  def self.signer_certificate(app)
    Dir.mktmpdir('room-passkeys-signer-') do |directory|
      prefix = File.join(directory, 'certificate-')
      # codesign's optional prefix MUST use '='; a separate argument is treated
      # as another bundle path and extraction fails even for a valid signature.
      command('/usr/bin/codesign', '--display', "--extract-certificates=#{prefix}", app)
      File.binread("#{prefix}0")
    end
  end

  USAGE = <<~TEXT.freeze
    Usage:
      ruby scripts/passkeys-signing.rb --prepare APP BASE_ENTITLEMENTS [ABSOLUTE_PROFILE OUTPUT_ENTITLEMENTS]
      ruby scripts/passkeys-signing.rb --verify APP

    Normally invoked by scripts/sign-and-notarize.sh. ROOM_PASSKEYS_PROFILE opts
    that script in; Apple must already have approved the managed capability for
    the app's actual bundle ID and signing team. ROOM_SIGN_IDENTITY is unchanged.
    --verify checks the embedded profile, signed main-app entitlements and the
    actual signer leaf certificate, without signing or notarizing anything.
    Without opt-in, preparation refuses any embedded profile or managed base
    entitlement; it never deletes an unrecognized profile from the app.
  TEXT
end

if $PROGRAM_NAME == __FILE__
  begin
    stage = ARGV.shift
    case stage
    when '--help', '-h'
      puts RoomPasskeysSigning::USAGE
    when '--prepare'
      raise RoomPasskeysSigning::Error, RoomPasskeysSigning::USAGE unless [2, 4].include?(ARGV.size)
      RoomPasskeysSigning.prepare(*ARGV)
    when '--verify'
      raise RoomPasskeysSigning::Error, RoomPasskeysSigning::USAGE unless ARGV.size == 1
      RoomPasskeysSigning.verify(ARGV.first)
    else
      raise RoomPasskeysSigning::Error, RoomPasskeysSigning::USAGE
    end
  rescue RoomPasskeysSigning::Error, SystemCallError => error
    warn "passkeys signing: #{error.message}"
    exit 1
  end
end
