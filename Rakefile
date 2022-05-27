# frozen_string_literal: true

require "bundler/gem_tasks"
require_relative "lib/codecov_opentelem/version"

task default: %i[]


task :compare_versions, [:github_ref] do |t, args|
    unless args.github_ref.end_with?(CodecovOpentelem::VERSION)
        abort("version mismatch between GITHUB_REF=#{args.github_ref} and gem veriosn=#{CodecovOpentelem::VERSION}")
    else
        puts "gem version #{CodecovOpentelem::VERSION} matched with GITHUB_REF"
    end 
end


task :get_version do |t|
    puts CodecovOpentelem::VERSION
end