#!/usr/bin/ruby
#
# This is an example of how to use the RETS client to log in and out of a server.
#
# You will need to set the necessary variables below.
#
#############################################################################################
# Settings

require 'yaml'
require 'active_support/core_ext/hash'
settings_file = File.expand_path(File.join(File.dirname(__FILE__), "settings.yml"))
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
              puts item["LongName"] + " - " + item["SystemName"]
            end
          end
          
      rescue
          puts "Unable to get metadata: '#{$!}'"
      end
      
      # Now perform search for these fields
      #options = {'Select' => "(#{sys_ids.join(',')})"}
      options = {}
      query = "(#{prop_f['Status']}=|A,AC,PB),(#{prop_f['Modified']}=2010-11-14T00:00:00+),(#{prop_f['List Price']}=0+)"
      begin
        client.search('Property', '4', query, options) do |result|
          result.response.each do |row|
              #puts row.inspect
              puts "-----------------------"
              puts "sysid: " + row[prop_f['sysid']]
              puts "# Images: " + row[prop_f['Number of Images']]
              puts "-----------------------"
              
              # Now get images for properties
              if row[prop_f['Number of Images']].to_i > 0
                photo_index = 1
                row[prop_f['Number of Images']].to_i.times do
                  client.get_object('Property', 'Photo', "#{row[prop_f['sysid']]}:#{photo_index}", 0) do |photo|
                    #handle_object(photo)
                    case photo.info['Content-Type']
                      when 'image/jpeg' then extension = 'jpg'
                      when 'image/gif'  then extension = 'gif'
                      when 'image/png'  then extension = 'png'
                      else extension = 'unknown'
                    end
                    
                    puts photo.info

                    File.open("#{photo.info['Content-ID']}_#{photo.info['Object-ID']}.#{extension}", 'w') do |f|
                      f.write(photo.data)
                    end
                  end
                  photo_index = photo_index + 1
                end
              end
          end
        end
      rescue
        puts "Unable to get search results: '#{$!}'"
      end
      
      # figure out how to get rid of old properties
      # thinking pull all mls #s and store in db then flag properties that don't exist in this table
      query = "(#{prop_f['Status']}=|A,AC,PB),(#{prop_f['List Price']}=0+)"
      options = {'Select' => "(sysid)"}
      begin
        client.search('Property', '4', query, options) do |result|
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
