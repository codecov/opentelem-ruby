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
    Coverage.start
    @filters = filters
    @inner = {}
  end

  def start_coverage_for_span(span)
    if !@filters[CoverageSpanFilter::REGEX_NAME].nil? && @filters[CoverageSpanFilter::REGEX_NAME].match(span.name)
      return false
    end

    Coverage.resume unless Coverage.running?
    true
  end

  def stop_coverage_for_span(span)
    span_id = span.span_id
    Coverage.suspend
    @inner[span_id] = Coverage.result(stop: false, clear: true)
  end

  def pop_coverage_for_span(span)
    span_id = span.span_id
    @inner.delete(span_id)
  end
end

class CodecovCoverageGenerator < OpenTelemetry::SDK::Trace::SpanProcessor
  def initialize(cov_storage, sample_rate)
    super()
    @cov_storage = cov_storage
    @sample_rate = sample_rate
  end

  def on_start(span, _parent_context = nil)
    @cov_storage.start_coverage_for_span(span) if rand < @sample_rate
  end

  def on_end(span)
    @cov_storage.stop_coverage_for_span(span)
  end
end

class CoverageExporter < OpenTelemetry::SDK::Trace::Export::SpanExporter
  def initialize(cov_storage, repository_token, code, codecov_url, untracked_export_rate)
    super()
    @cov_storage = cov_storage
    @repository_token = repository_token
    @code = code
    @codecov_url = codecov_url
    @untracked_export_rate = untracked_export_rate
  end

  def export(spans, timeout)
    tracked_spans = []
    untracked_spans = []
    spans.each do |span|
      cov = @cov_storage.pop_coverage_for_span(span)

      span_hash = Hash.new
      span.to_h.each do |k, v|
        v = v.dup.force_encoding("ISO-8859-1").encode("UTF-8") if v.is_a? String
        span_hash[k] = v
      end
      s = span_hash.to_json

      if !cov.nil?
        s['codecov'] = { 'type' => 'bytes', 'coverage' => cov }
        tracked_spans.append(s)
      elsif rand < @untracked_export_rate
        untracked_spans.append(s)
      end
    end
    return OpenTelemetry::SDK::Trace::Export::SUCCESS if !tracked_spans && !untracked_spans

    body = { 'profiling' => @code }.to_json
    res = Net::HTTP.post(
      URI.join(@codecov_url, '/profiling/uploads'),
      { 'profiling' => @code }.to_json,
      'Content-Type' => 'application/json',
      'Authorization' => "repotoken #{@repository_token}"
    )
    return OpenTelemetry::SDK::Trace::Export::FAILURE if res.is_a?(Net::HTTPError)

    location = JSON(res.body)['raw_upload_location']
    uri = URI(location)
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    req = Net::HTTP::Put.new(
      location,
      {
        'Content-Type' => 'text/plain'
      }
    )
    req.body = {
      'spans' => tracked_spans,
      'untracked' => untracked_spans
    }.to_json,
    https.request(req)
    OpenTelemetry::SDK::Trace::Export::SUCCESS
  end
end
