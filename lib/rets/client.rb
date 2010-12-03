require 'digest/md5'
require 'net/http'
require 'uri'
require 'cgi'
require 'parsers/response_parser'
require 'dataobject'
require 'logger'

module RETS
  class Client
    COMPACT_FORMAT = 'COMPACT'
    
    DEFAULT_RETS_VERSION    = '1.7'
    DEFAULT_RETRY           = 2
    
    METHOD_GET  = 'GET'
    METHOD_POST = 'POST'
    METHOD_HEAD = 'HEAD'
    CAPABILITY_LIST   = [
        'Action',
        'ChangePassword',
        'GetObject',
        'Login',
        'LoginComplete',
        'Logout',
        'Search',
        'GetMetadata',
        'Update'
    ]
    
    attr_accessor :mimemap, :logger
    attr_reader   :format
  
    def initialize(url, user_agent, format = COMPACT_FORMAT)
      @format   = format
      @urls     = { 'Login' => URI.parse(url) }
    
      @headers  = {
          'User-Agent'   => user_agent,
          'Accept'       => '*/*',
          'RETS-Version' => "RETS/#{DEFAULT_RETS_VERSION}"
      }
    
      @nc       = 0
      @request_method = METHOD_GET
      @semaphore      = Mutex.new
      @response_parser = RETS::ResponseParser.new
      
      self.mimemap    = {
        'image/jpeg'  => 'jpg',
        'image/gif'   => 'gif'
      }
      
    end
  
    def set_header(name, value)
      if value.nil? then
        @headers.delete(name)
      else
        @headers[name] = value
      end
      
      logger.debug("Set header '#{name}' to '#{value}'") if logger
    end
  
    def get_header(name)
      @headers[name]
    end

    def user_agent=(name)
      set_header('User-Agent', name)
    end

    def user_agent
      get_header('User-Agent')
    end
  
    def rets_version=(version)
      if (SUPPORTED_RETS_VERSIONS.include? version)
        set_header('RETS-Version', "RETS/#{version}")
      else
        raise Unsupported.new("The client does not support RETS version '#{version}'.")
      end
    end
  
    def rets_version
      (get_header('RETS-Version') || "").gsub("RETS/", "")
    end

    def request_method=(method)
      @request_method = method
    end

    def request_method
      # Basic Authentication
      @request_method
    end
  
    def login(username, password)
      @username = username
      @password = password
    
      response = request(@urls['Login'])
      
      # Parse response to get other URLS
      results = @response_parser.parse_key_value(response.body)
    
      if results.success?
        CAPABILITY_LIST.each do |capability|
          next unless results.response[capability]

          uri = URI.parse(results.response[capability])

          if uri.absolute?
            @urls[capability] = uri
          else
            base = @urls['Login'].clone
            base.path = results.response[capability]
            @urls[capability] = base
          end
        end
        logger.debug("Capability URL List: #{@urls.inspect}") if logger
      else
        raise LoginError.new(response.message + "(#{results.reply_code}: #{results.reply_text})")
      end
      
      # Perform the mandatory get request on the action URL.
      results.secondary_response = perform_action_url
            
      # We only yield
      if block_given?
        begin
          yield results
        ensure
          self.logout
        end
      else
        results
      end
    end
    
    def logout()
      #request(@urls['Logout']) if @urls['Logout']
    end
    
    def get_metadata(type = 'METADATA-SYSTEM', id = '*')
      xml = download_metadata(type, id)

      result = @response_parser.parse_metadata(xml, @format, type)

      if block_given?
        yield result
      else
        result
      end
    end
    
    def download_metadata(type, id)
      header = {
        'Accept' => 'text/xml,text/plain;q=0.5'
      }

      data = {
        'Type'   => type,
        'ID'     => id,
        'Format' => @format
      }

      request(@urls['GetMetadata'], data, header).body
    end
    
    def search(search_type, klass, query, options = false)
      header = {}

      # Required Data
      data = {
        'SearchType' => search_type,
        'Class'      => klass,
        'Query'      => query,
        'QueryType'  => 'DMQL2',
        'Format'     => format,
        'Count'      => '0'
      }

      # Options
      #--
      # We might want to switch this to merge!, but I've kept it like this for now because it
      # explicitly casts each value as a string prior to performing the search, so we find out now
      # if can't force a value into the string context. I suppose it doesn't really matter when
      # that happens, though...
      #++
      options.each { |k,v| data[k] = v.to_s } if options
      
      response = request(@urls['Search'], data, header)
      results = @response_parser.parse_results(response.body, @format)

      if block_given?
        yield results
      else
        return results
      end
    end
    
    # Performs a GetObject transaction on the server. For details on the arguments, please see
    # the RETS specification on GetObject requests.
    #
    # This method either returns an Array of DataObject instances, or yields each DataObject
    # as it is created. If a block is given, the number of objects yielded is returned.
    def get_object(resource, type, id, location = 0) #:yields: data_object
      header = {
        'Accept' => mimemap.keys.join(',')
      }

      data = {
        'Resource' => resource,
        'Type'     => type,
        'ID'       => id,
        'Location' => location.to_s
      }

      response = request(@urls['GetObject'], data, header)
      results = block_given? ? 0 : []

      if response['content-type'] && response['content-type'].include?('text/xml')
        # This probably means that there was an error.
        # Response parser will likely raise an exception.
        rr = @response_parser.parse_object_response(response.body)
        return rr
      elsif response['content-type'] && response['content-type'].include?('multipart/parallel')
        content_type = process_content_type(response['content-type'])

#        TODO: log this
#        puts "SPLIT ON #{content_type['boundary']}"
        boundary = content_type['boundary']
        if boundary =~ /\s*'([^']*)\s*/
          boundary = $1
        end
        parts = response.body.split("\r\n--#{boundary}")

        parts.shift # Get rid of the initial boundary

#        TODO: log this
#        puts "GOT PARTS #{parts.length}"

        parts.each do |part|
          (raw_header, raw_data) = part.split("\r\n\r\n")

#          TODO: log this
#          puts raw_data.nil?
          next unless raw_data

          data_header = process_header(raw_header)
          data_object = RETS::DataObject.new(data_header, raw_data)

          if block_given?
            yield data_object
            results += 1
          else
            results << data_object
          end
        end
      else
        info = {
          'content-type' => response['content-type'], # Compatibility shim.  Deprecated.
          'Content-Type' => response['content-type'],
          'Object-ID'    => response['Object-ID'],
          'Content-ID'   => response['Content-ID']
        }

        if response['Transfer-Encoding'].to_s.downcase == "chunked" || response['Content-Length'].to_i > 100 then
          data_object = RETS::DataObject.new(info, response.body)
          if block_given?
            yield data_object
            results += 1
          else
            results << data_object
          end
        end
      end

      results
    end
  
    def request(url, data = {}, header = {}, method = @request_method, retry_auth = DEFAULT_RETRY)
      response = ''
      
      @semaphore.lock
    
      http = Net::HTTP.new(url.host, url.port)
      http.read_timeout = 600
      
      if logger && logger.debug?
        http.set_debug_output HTTPDebugLogger.new(logger)
      end
        
      http.start do |http|
        begin
          uri = url.path
          if !data.empty? && method == METHOD_GET
            uri += "?#{create_query_string(data)}"
          end
        
          headers = @headers
          headers.merge(header) unless header.empty?
          
          logger.debug(headers.inspect) if logger
        
          @semaphore.unlock
        
          post_data = data.map {|k,v| "#{CGI.escape(k.to_s)}=#{CGI.escape(v.to_s)}" }.join('&') if method == METHOD_POST
                    
          response  = method == METHOD_POST ? http.post(uri, post_data, headers) : http.get(uri, headers)
          
          @semaphore.lock
          
          if response.code == '401'
            # Authentication is required
            raise AuthRequired
          elsif response.code.to_i >= 300
            # We have a non-successful response that we cannot handle
            @semaphore.unlock if @semaphore.locked?
            raise HTTPError.new(response)
          else
            cookies = []
            if set_cookies = response.get_fields('set-cookie') then
              set_cookies.each do |cookie|
                cookies << cookie.split(";").first
              end
            end
            set_header('Cookie', cookies.join("; ")) unless cookies.empty?
            set_header('RETS-Session-ID', response['RETS-Session-ID']) if response['RETS-Session-ID']
          end
        rescue AuthRequired
          @nc += 1

          if retry_auth > 0
            retry_auth -= 1
            auth = Auth.authenticate(response,
                                     @username,
                                     @password,
                                     url.path,
                                     method,
                                     @headers['RETS-Request-ID'],
                                     user_agent,
                                     @nc)
            set_header('Authorization', auth)
            retry
          else
            @semaphore.unlock if @semaphore.locked?
            raise LoginError.new(response.message)
          end
        end
        
        logger.debug(response.body) if logger
      end
      
      @semaphore.unlock if @semaphore.locked?
      
      return response
    end
    
    # Given a hash, it returns a URL encoded query string.
    def create_query_string(hash)
      parts = hash.map {|key,value| "#{CGI.escape(key)}=#{CGI.escape(value)}"}
      return parts.join('&')
    end
    
    # If an action URL is present in the URL capability list, it calls that action URL and returns the
    # raw result. Throws a generic RETSException if it is unable to follow the URL.
    def perform_action_url
      begin
        if @urls.has_key?('Action')
          return request(@urls['Action'], {}, {}, METHOD_GET)
        end
      rescue
        raise RETSException.new("Unable to follow action URL: '#{$!}'.")
      end
    end
    
    # Provides a proxy class to allow for net/http to log its debug to the logger.
    class HTTPDebugLogger
      def initialize(logger)
        @logger = logger
      end

      def <<(data)
        @logger.debug(data)
      end
    end
    
        # A general RETS level exception was encountered. This would include HTTP and RETS
    # specification level errors as well as informative mishaps such as authentication being
    # required for access.
    class RETSException < RuntimeError
    end

    # There was a problem with logging into the RETS server.
    class LoginError < RETSException
    end

    # For internal client use only, it is thrown when the a RETS request is made but a password
    # is prompted for.
    class AuthRequired < RETSException
    end
  end
end