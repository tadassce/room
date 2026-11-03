# Run: ruby scripts/tests/test_passkeys_signing.rb
require 'minitest/autorun'
require_relative '../passkeys-signing'

class PasskeysSigningTest < Minitest::Test
  Signing = RoomPasskeysSigning
  BUNDLE_ID = 'org.example.room'.freeze
  TEAM = 'TEAM123456'.freeze
  PREFIX = 'SEED123456'.freeze # A historical App ID prefix need not equal the team.

  def setup
    @now = Time.utc(2026, 1, 1)
    @leaf = "fixture certificate DER\x00\xff".b
    @profile = {
      'Platform' => ['OSX'],
      'ExpirationDate' => Time.utc(2027, 1, 1),
      'ApplicationIdentifierPrefix' => [PREFIX],
      'TeamIdentifier' => [TEAM],
      'DeveloperCertificates' => [Signing::Data.new(@leaf)],
      'Entitlements' => {
        Signing::PASSKEY => true,
        Signing::APP_ID => "#{PREFIX}.#{BUNDLE_ID}",
        Signing::TEAM_ID => TEAM,
        'com.apple.security.app-sandbox' => true,
        'get-task-allow' => true,
        'keychain-access-groups' => ["#{PREFIX}.*"]
      }
    }
    @base = { 'com.apple.security.device.camera' => true, 'com.apple.security.print' => true }
  end

  def validate(bundle_id = BUNDLE_ID)
    Signing.validate_profile(@profile, bundle_id: bundle_id, now: @now)
  end

  def test_exact_mac_profile_identity_with_independent_app_prefix
    assert_equal({
      Signing::PASSKEY => true,
      Signing::APP_ID => "#{PREFIX}.#{BUNDLE_ID}",
      Signing::TEAM_ID => TEAM
    }, validate)
  end

  def test_a_forks_own_bundle_and_team_are_not_hard_coded
    @profile['TeamIdentifier'] = ['FORK123456']
    @profile['ApplicationIdentifierPrefix'] = ['FORK123456']
    @profile['Entitlements'][Signing::TEAM_ID] = 'FORK123456'
    @profile['Entitlements'][Signing::APP_ID] = 'FORK123456.com.fork.browser'
    assert_equal 'FORK123456', validate('com.fork.browser')[Signing::TEAM_ID]
  end

  def test_wrong_bundle_id_and_debug_suffix_are_rejected
    ['org.example.other', "#{BUNDLE_ID}.dev"].each do |bundle_id|
      error = assert_raises(Signing::Error) { validate(bundle_id) }
      assert_match(/exact.*no wildcard/, error.message)
    end
  end

  def test_wildcard_app_identifiers_are_not_approval
    ["#{PREFIX}.*", "#{PREFIX}.#{BUNDLE_ID}.*", '*.org.example.room'].each do |app_id|
      @profile['Entitlements'][Signing::APP_ID] = app_id
      assert_raises(Signing::Error) { validate }
    end
  end

  def test_app_identifier_must_use_a_declared_prefix
    @profile['Entitlements'][Signing::APP_ID] = "#{TEAM}.#{BUNDLE_ID}"
    assert_raises(Signing::Error) { validate }
  end

  def test_absent_or_invalid_application_prefix_is_rejected
    [nil, [], ['*'], ['SEED123456.*'], PREFIX].each do |prefixes|
      @profile['ApplicationIdentifierPrefix'] = prefixes
      assert_raises(Signing::Error) { validate }
    end
  end

  def test_missing_app_identifier_is_rejected
    @profile['Entitlements'].delete(Signing::APP_ID)
    assert_raises(Signing::Error) { validate }
  end

  def test_conflicting_application_identity_alias_is_rejected
    @profile['Entitlements']['application-identifier'] = "#{PREFIX}.another.app"
    assert_raises(Signing::Error) { validate }
  end

  def test_managed_entitlement_is_a_literal_boolean_true
    [false, nil, 'true', 'YES', 1, 1.0, [true]].each do |value|
      @profile['Entitlements'][Signing::PASSKEY] = value
      error = assert_raises(Signing::Error) { validate }
      assert_match(/boolean true/, error.message)
    end
    @profile['Entitlements'].delete(Signing::PASSKEY)
    assert_raises(Signing::Error) { validate }
  end

  def test_missing_entitlements_dictionary_is_rejected
    @profile.delete('Entitlements')
    assert_raises(Signing::Error) { validate }
  end

  def test_mismatched_or_missing_team_entitlement_is_rejected
    ['OTHR123456', nil, true].each do |team|
      @profile['Entitlements'][Signing::TEAM_ID] = team
      error = assert_raises(Signing::Error) { validate }
      assert_match(/team entitlement disagree/, error.message)
    end
  end

  def test_invalid_or_ambiguous_team_identifier_is_rejected
    [nil, [], [TEAM, 'OTHR123456'], ['*'], ['short'], TEAM].each do |teams|
      @profile['TeamIdentifier'] = teams
      assert_raises(Signing::Error) { validate }
    end
  end

  def test_expiration_is_checked_against_the_injected_clock
    [@now - 1, @now, nil, '2027-01-01T00:00:00Z'].each do |expiry|
      @profile['ExpirationDate'] = expiry
      error = assert_raises(Signing::Error) { validate }
      assert_match(/ExpirationDate/, error.message)
    end
  end

  def test_other_platforms_and_missing_platform_are_rejected
    [['iOS'], ['visionOS'], [], nil, 'OSX'].each do |platforms|
      @profile['Platform'] = platforms
      assert_raises(Signing::Error) { validate }
    end
  end

  def test_profile_needs_nonempty_certificate_data_not_strings
    [nil, [], [@leaf], [Signing::Data.new('')], [Signing::Data.new(nil)]].each do |certificates|
      @profile['DeveloperCertificates'] = certificates
      assert_raises(Signing::Error) { validate }
    end
  end

  def test_merge_copies_only_required_identity_and_passkey_entitlements
    original_base = Marshal.load(Marshal.dump(@base))
    original_profile = Marshal.load(Marshal.dump(@profile))
    merged = Signing.merge_entitlements(@base, @profile, bundle_id: BUNDLE_ID, now: @now)
    assert_equal @base.merge(validate), merged
    assert_equal (@base.keys + [Signing::PASSKEY, Signing::APP_ID, Signing::TEAM_ID]).sort, merged.keys.sort
    %w[com.apple.security.app-sandbox get-task-allow keychain-access-groups].each do |key|
      refute merged.key?(key), "extra profile entitlement leaked: #{key}"
    end
    assert_equal original_base, @base
    assert_equal original_profile, @profile
  end

  def test_invalid_profile_cannot_be_merged
    @profile['Entitlements'][Signing::PASSKEY] = false
    assert_raises(Signing::Error) do
      Signing.merge_entitlements(@base, @profile, bundle_id: BUNDLE_ID, now: @now)
    end
    refute @base.key?(Signing::PASSKEY)
  end

  def test_actual_signer_leaf_must_match_exact_certificate_bytes
    validate
    assert_nil Signing.validate_certificate(@profile, @leaf.dup)
    error = assert_raises(Signing::Error) do
      Signing.validate_certificate(@profile, "another or renewed certificate DER\x00\xff".b)
    end
    assert_match(/ROOM_SIGN_IDENTITY/, error.message)
    [nil, ''].each do |leaf|
      assert_raises(Signing::Error) { Signing.validate_certificate(@profile, leaf) }
    end
  end

  def test_certificate_extraction_uses_codesigns_optional_argument_syntax
    runner = lambda do |*args|
      assert_equal ['/usr/bin/codesign', '--display'], args.first(2)
      assert_equal '/tmp/Some Browser.app', args.last
      assert_match(/\A--extract-certificates=.+/, args[2])
      prefix = args[2].split('=', 2).last
      File.binwrite("#{prefix}0", @leaf)
      ''
    end
    Signing.stub(:command, runner) do
      assert_equal @leaf, Signing.signer_certificate('/tmp/Some Browser.app')
    end
  end

  def test_any_profile_developer_certificate_may_be_the_actual_signer
    @profile['DeveloperCertificates'].unshift(Signing::Data.new('another approved certificate'.b))
    validate
    assert_nil Signing.validate_certificate(@profile, @leaf)
  end

  def test_signed_entitlements_must_include_the_literal_approved_identity
    required = validate
    assert_nil Signing.validate_signed_entitlements(@base.merge(required), required)
    [Signing::PASSKEY, Signing::APP_ID, Signing::TEAM_ID].each do |key|
      actual = required.dup
      actual.delete(key)
      assert_raises(Signing::Error) { Signing.validate_signed_entitlements(actual, required) }
    end
    assert_raises(Signing::Error) do
      Signing.validate_signed_entitlements(required.merge(Signing::PASSKEY => 1), required)
    end
    assert_raises(Signing::Error) do
      Signing.validate_signed_entitlements(required.merge(Signing::TEAM_ID => 'OTHR123456'), required)
    end
  end

  def test_default_entitlements_are_unchanged_without_an_embedded_profile
    original = @base.dup
    assert_nil Signing.validate_default(@base, embedded_profile: false)
    assert_equal original, @base
    refute @base.key?(Signing::PASSKEY)
  end

  def test_default_signing_refuses_any_leftover_profile_rather_than_shipping_or_deleting_it
    error = assert_raises(Signing::Error) { Signing.validate_default(@base, embedded_profile: true) }
    assert_match(/without ROOM_PASSKEYS_PROFILE/, error.message)
    assert_match(/remove it explicitly/, error.message)
  end

  def test_default_signing_refuses_even_a_false_managed_base_entitlement
    [true, false].each do |value|
      assert_raises(Signing::Error) do
        Signing.validate_default(@base.merge(Signing::PASSKEY => value), embedded_profile: false)
      end
    end
  end

  def test_plist_codec_keeps_boolean_date_and_certificate_types_without_apple_secrets
    decoded = Signing::Plist.parse(Signing::Plist.dump(@profile))
    assert_equal @profile, decoded
    assert_instance_of Time, decoded['ExpirationDate']
    assert_instance_of Signing::Data, decoded['DeveloperCertificates'].first
    assert_same true, decoded['Entitlements'][Signing::PASSKEY]
    assert_equal validate, Signing.validate_profile(decoded, bundle_id: BUNDLE_ID, now: @now)
    values = { 'escaped<&key' => 'value<&>', 'array' => [false, true, 42, 0.5, '', {}, []] }
    assert_equal values, Signing::Plist.parse(Signing::Plist.dump(values))
  end

  def test_plist_codec_rejects_duplicate_keys
    xml = '<plist><dict><key>capability</key><false/><key>capability</key><true/></dict></plist>'
    assert_raises(Signing::Error) { Signing::Plist.parse(xml) }
  end
end
