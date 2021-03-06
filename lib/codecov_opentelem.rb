# frozen_string_literal: true

require_relative "codecov_opentelem/version"
require 'codecov_opentelem/coverage_exporter'


# Entrypoint for getting a span processor/span exporter pair to send profiling data to codecov
# @param [String] repository_token The profiling authentication token
# @param [Numeric] sample_rate The sampling rate for codecov, a number from 0 to 1
# @param [Numeric] untracked_export_rate The export rate for codecov for non-sampled spans, a number from 0 to 1
# @param [optional Hash] filters A hash of filters for determining which spans should have its coverage tracked
# @param [optional String] version_identifier The identifier for what software version is being profiled
# @param [optional String] environment The environment name this profiling is running on
# @param [optional Boolean] needs_version_creation Whether the "create this version" needs to be called (one can choose
#     to call it manually beforehand and disable it here)
# @param [optional String] codecov_url For configuring the endpoint in case the user is in enterprise (not
#     supported yet). Default is "https://api.codecov.io/"
# @return [Array<CodecovCoverageGenerator,CoverageExporter>]
def get_codecov_opentelemetry_instances(
  repository_token:,
  sample_rate:,
  untracked_export_rate:,
  code:,
  filters: {},
  version_identifier: nil,
  environment: nil,
  needs_version_creation: true,
  codecov_url: nil
)
  codecov_url = 'https://api.codecov.io' if codecov_url.nil?
  raise UnableToStartProcessorException, 'Codecov profiling needs a code set' if code.nil?

  if needs_version_creation && version_identifier && environment
    res = Net::HTTP.post(URI.join(codecov_url, '/profiling/versions'), {
      'version_identifier' => version_identifier,
      'environment' => environment,
      'code' => code
    }.to_json,
                         'Content-Type' => 'application/json',
                         'Authorization' => "repotoken #{repository_token}")
    raise UnableToStartProcessorException if res.is_a?(Net::HTTPError)
  end
  manager = CodecovCoverageStorageManager.new(filters)
  generator = CodecovCoverageGenerator.new(manager, sample_rate)
  exporter = CoverageExporter.new(
    manager, repository_token, code, codecov_url, untracked_export_rate
  )
  [generator, exporter]
end
