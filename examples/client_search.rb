#!/usr/bin/ruby
#
# This is an example of how to use the RETS client to log in and out of a server.
#
# You will need to set the necessary variables below.
#
#############################################################################################
# Settings

require 'yaml'
require_relative '../lib/rets/core-ext/hash/keys.rb'
settings_file = File.expand_path(File.join(File.dirname(__FILE__), "settings.yml"))
ENV['LISTING_ENV'] ||= 'development'
settings = YAML.load_file(settings_file)[ENV['LISTING_ENV']].symbolize_keys

#############################################################################################

$:.unshift '../lib'

require_relative '../lib/rets.rb'

client = RETS::Client.new(settings[:url], settings[:user_agent])

client.login(settings[:username], settings[:password]) do |login_result|
  if login_result.success?
      puts "We successfully logged into the RETS server!"
      prop_f = Hash.new
      sys_ids = Array.new
      
      begin
          metadata = client.get_metadata("METADATA-TABLE","Property:4")
          metadata.response.each do |item|
            if settings[:lookup_values].include? item[settings[:lookup]]
              prop_f[item["LongName"]] = item["SystemName"]
              sys_ids.push item["SystemName"]
            end
          end
          
      rescue
          puts "Unable to get metadata: '#{$!}'"
      end
      
      # Now perform search for these fields
      options = {}
      query = "(#{prop_f['Status']}=|A,AC,PB),(#{prop_f['List Price']}=0+)"
      options = {'Select' => "#{prop_f['MLS #']}"}
      begin
        client.search('Property', '4', query, options) do |result|
          result.response.each do |row|
              puts row.inspect
          end
        end
      rescue
        puts "Unable to get search results: '#{$!}'"
      end

      client.logout

      puts "We just logged out of the server."
  else
      puts "We were unable to log into the RETS server."
      puts "Please check that you have set the login variables correctly."
  end
end
