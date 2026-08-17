require 'test_helper'
require 'rexml/document'
require 'set'

# The profile and the bridge are two halves of one contract, edited in separate
# files and separate languages. This suite reads the shipped XML and checks both
# directions of that contract, so a rename on either side fails here rather than
# silently on the Savant host.
class ProfileContractTest < Minitest::Test
  PROFILE = File.expand_path(
    '../../componentProfiles/heat_n_glo_cosmo_42.xml', __dir__
  )

  # Representative values for the endpoints the profile builds from an action
  # argument, keyed by the literal path prefix in the XML.
  ARGUMENT_SAMPLES = {
    'dimmer/' => '1/50',
    'flame/' => '3',
    'fan/' => '2',
    'light/' => '1',
    'timer/' => '45',
    'thermostat/c/' => '22',
    'thermostat/f/' => '72'
  }.freeze

  def setup
    skip "profile not found at #{PROFILE}" unless File.exist?(PROFILE)

    @doc = REXML::Document.new(File.read(PROFILE))
    @router, @client, = build_stack
  end

  # Every literal path the profile can GET, with parameterized ones completed.
  def profile_endpoints
    REXML::XPath.match(@doc, '//command_string[@http_request_type="GET"]').map do |node|
      path = node.text.to_s.strip
      suffix = ARGUMENT_SAMPLES[path]
      suffix ? "#{path}#{suffix}" : path
    end.uniq
  end

  # Every /none/<field> the profile's JSON parser reads.
  def profile_status_paths
    REXML::XPath.match(@doc, '//root_object[@format="json"]/values').map do |node|
      node.attribute('path').to_s.sub(%r{\A/none/}, '')
    end.uniq
  end

  def test_profile_is_well_formed_and_non_trivial
    assert_operator profile_endpoints.length, :>, 20
    assert_operator profile_status_paths.length, :>, 15
  end

  # Direction 1: everything the profile calls must route.
  def test_every_endpoint_the_profile_calls_is_routable
    unroutable = profile_endpoints.reject do |path|
      status, = @router.call('GET', "/#{path}")
      status == 200
    end

    assert_empty unroutable,
                 "profile calls endpoints the bridge does not serve: #{unroutable.join(', ')}"
  end

  # Direction 2: everything the profile parses must be produced.
  def test_every_status_path_the_profile_reads_is_produced
    _, live = @router.call('GET', '/status')
    missing = profile_status_paths.reject { |field| live.key?(field) }

    assert_empty missing,
                 "profile reads status fields the bridge never emits: #{missing.join(', ')}"
  end

  # Before the first successful poll the bridge answers with the offline
  # document; if that lacks a field, the matching state variable never
  # initializes and the Pro App shows a blank tile.
  def test_offline_document_also_satisfies_every_status_path
    offline = IntellifireBridge::Status.offline
    missing = profile_status_paths.reject { |field| offline.key?(field) }

    assert_empty missing,
                 "offline status document is missing: #{missing.join(', ')}"
  end

  # Each Savant state variable is written from exactly one JSON path, so a typo
  # that points two paths at one variable would make them fight each other.
  def test_no_state_variable_is_written_from_two_paths
    updates = REXML::XPath.match(@doc, '//root_object[@format="json"]//update')
                          .map { |node| node.attribute('state').to_s }
    duplicates = updates.tally.select { |_, count| count > 1 }.keys

    assert_empty duplicates, "state variables written more than once: #{duplicates.join(', ')}"
  end

  # Actions referenced by execute_action_after_delay must actually exist, or the
  # confirming status fetch silently never happens.
  def test_delayed_followup_actions_all_exist
    defined_actions = REXML::XPath.match(@doc, '//action').map { |n| n.attribute('name').to_s }.to_set
    referenced = REXML::XPath.match(@doc, '//execute_action_after_delay')
                             .map { |n| n.attribute('action_name').to_s }.uniq

    missing = referenced.reject { |name| defined_actions.include?(name) }
    assert_empty missing, "execute_action_after_delay targets undefined actions: #{missing.join(', ')}"
  end

  # The dimmer channel numbers are duplicated between the profile's documented
  # Address1 values and the router's channel table; keep them in step.
  def test_dimmer_channels_cover_the_documented_addresses
    %w[1 2 3].each do |address|
      status, = @router.call('GET', "/dimmer/#{address}/50")
      assert_equal 200, status, "dimmer channel #{address} is documented but not routable"
    end
  end
end
