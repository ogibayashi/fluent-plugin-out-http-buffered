module Fluent

  class HttpBufferedOutput < Fluent::BufferedOutput
    Fluent::Plugin.register_output('http_buffered', self)
    include SetTagKeyMixin
    include SetTimeKeyMixin

    def initialize
      super
      require 'net/http'
      require 'uri'
    end

    # Endpoint URL ex. localhost.local/api/
    config_param :endpoint_url, :string

    # statuses under which to retry
    config_param :http_retry_statuses, :string, :default => ""

    # read timeout for the http call
    config_param :http_read_timeout, :float, :default => 2.0

    # open timeout for the http call
    config_param :http_open_timeout, :float, :default => 2.0

    # whether 'time' should be sent.
    config_param :output_include_time, :bool, :default => true

    # whether 'tag' should be sent.
    config_param :output_include_tag, :bool, :default => true

    # serializer of messages.
    config_param :serializer, :string, :default => 'json'

    # Retry in case of connect error.
    config_param :retry_on_connect_error, :default => false

    # Addtional HTTP Header
    config_param :additional_headers, :string, :default=> nil

    def configure(conf)
      super

      #Check if endpoint URL is valid
      unless @endpoint_url =~ /^#{URI::regexp}$/
        raise Fluent::ConfigError, "endpoint_url invalid"
      end
      
      begin
        @uri = URI::parse(@endpoint_url)
      rescue URI::InvalidURIError
        raise Fluent::ConfigError, "endpoint_url invalid"
      end

      #Parse http statuses
      @statuses = @http_retry_statuses.split(",").map { |status| status.to_i}

      if @statuses.nil?
        @statuses = []
      end

      @http = Net::HTTP.new(@uri.host, @uri.port)
      @http.read_timeout = @http_read_timeout
      @http.open_timeout = @http_open_timeout

      serializers = ['json','msgpack']
      unless serializers.include?(@serializer)
        raise Fluent::ConfigError, "Invalid serializer: #{@serializer}"
      end

      # Convert string to Hash (Header name => string)
      if @additional_headers
        @additional_headers = Hash[@additional_headers.split(",").map{ |f| f.split("=",2)}]
      end

    end

    def start
      super
    end

    def shutdown
      super
      begin
        @http.finish
      rescue
      end
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      data = []
      chunk.msgpack_each do |(tag,time,record)|
        if (! @output_include_tag ) and (! @output_include_time)
          data << record
        else
          out = []
          out << tag if @output_include_tag
          out << time if @output_include_time
          out << record
          data << out
        end
      end

      request = create_request(data)

      begin
        response = @http.start do |http|
          request = create_request(data)
          http.request request
        end

        if @statuses.include? response.code.to_i
          #Raise an exception so that fluent retries
          raise "Server returned bad status: #{response.code}. Retry sending later."
        elsif ! (/^2\d\d$/ =~ response.code )
          $log.warn "Server returned bad status: #{response.code}. Message was dropped."
        end
      rescue IOError, EOFError, SystemCallError
        # server didn't respond 
        if retry_on_connect_error
          raise "Net::HTTP.#{request.method.capitalize} raises exception: #{$!.class}, '#{$!.message}'"
        else
          $log.warn "Net::HTTP.#{request.method.capitalize} raises exception: #{$!.class}, '#{$!.message}'"
        end
      ensure
        begin
          @http.finish
        rescue
        end
      end
    end

    protected

    def create_request_json(request, data)
      #Headers
      request['Content-Type'] = 'application/json'
      
      #Body
      request.body = JSON.dump(data)
    end

    def create_request_msgpack(request, data)
      #Headers
      request['Content-Type'] = 'application/x-msgpack; charset=x-user-defined'
      
      #Body
      request.body = data.to_msgpack
    end

    def create_request(data)
      request= Net::HTTP::Post.new(@uri.request_uri)
      if @additional_headers 
        @additional_headers.each{|k,v|
          request[k] = v
        }
      end

      case @serializer
      when 'json'
        create_request_json(request,data)
      when 'msgpack'
        create_request_msgpack(request,data)
      end
      request
    end
  end
end
