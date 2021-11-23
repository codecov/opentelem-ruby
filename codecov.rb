# frozen_string_literal: true

require 'json'
require 'uri'
require 'net/http'

require 'opentelemetry/sdk'
require 'coverage'

module CoverageSpanFilter
  REGEX_NAME = 'name_regex'
  SPAN_KIND = 'span_kind'
end

class CodecovCoverageStorageManager
  def initialize(filters)
    @filters = filters
    @inner = {}
  end

  def start_coverage_for_span(span)
    if !@filters[CoverageSpanFilter::REGEX_NAME].nil? && @filters[CoverageSpanFilter::REGEX_NAME].match(span.name)
      return false
    end

    Coverage.resume
    true
  end

  def stop_coverage_for_span(_span)
    span_id = span.context.span_id
    Coverage.suspend
    @inner[span_id] = Coverage.result(stop: false, clear: true)
  end

  def pop_coverage_for_span(_span)
    span_id = span.context.span_id
    @inner.delete(span_id)
  end
end

class CodecovCoverageGenerator < SpanProcessor
  def initialize(cov_storage, sample_rate)
    super()
    @cov_storage = cov_storage
    @sample_rate = sample_rate
  end

  def on_start(span, _parent_context = nil)
    @cov_storage.possibly_start_cov_for_span(span) if rand < @sample_rate
  end

  def on_end(span)
    @cov_storage.stop_coverage_for_span(span)
  end
end

class CoverageExporter < SpanExporter
  def initialize(cov_storage, repository_token, code, codecov_url, untracked_export_rate)
    super()
    @cov_storage = cov_storage
    @repository_token = repository_token
    @code = code
    @codecov_url = codecov_url
    @untracked_export_rate = untracked_export_rate
  end

  def export(spans)
    tracked_spans = []
    untracked_spans = []
    spans.each do |span|
      cov = cov_storage.pop_cov_for_span(span)
      s = JSON.parse(span)
      if !cov.nil?
        s['codecov'] = { 'type' => 'bytes', 'coverage' => cov }
        tracked_spans.append(s)
      elsif rand < @untracked_export_rate
        untracked_spans.append(s)
      end
    end
    return SpanExportResult.SUCCESS if !tracked_spans && !untracked_spans

    res = Net::HTTP.post(URI.join(@codecov_url, '/profiling/uploads'),
                         { 'code' => @code }.to_json,
                         'Content-Type' => 'application/json',
                         'Authorization' => "repotoken #{@repository_token}")
    return SpanExportResult.FAILURE if res.is_a?(Net::HTTPError)

    location = res.body.raw_upload_location
    Net::HTTP.put(URI(location),
                  { 'spans' => tracked_spans,
                    'untracked' => untracked_spans }.to_json,
                  'Content-Type' => 'text/plain')
    SpanExportResult.SUCCESS
  end
end

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
  manager = CodecovCoverageStorageManager(filters)
  generator = CodecovCoverageGenerator(manager, sample_rate)
  exporter = CoverageExporter(
    manager, repository_token, code, codecov_url, untracked_export_rate
  )
  [generator, exporter]
end
