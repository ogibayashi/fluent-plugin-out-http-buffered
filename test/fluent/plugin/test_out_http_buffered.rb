require 'helper'
require 'yaml'

class HttpBufferedOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
  end

  CONFIG = %[
    endpoint_url  http://local.endpoint
  ]

  #Used to test invalid method config
  CONFIG_METHOD = %[
    endpoint_url local.endpoint
    http_method  invalid_method
  ]

  CONFIG_TAGTIME = %[
    endpoint_url  http://local.endpoint
    output_include_time false
    output_include_tag false
    include_tag_key true
    include_time_key true
    time_format %s
  ]


  def create_driver(conf = CONFIG)
    Fluent::Test::BufferedOutputTestDriver.new(Fluent::HttpBufferedOutput).configure(conf)
  end

  def test_configure
    d = create_driver
    assert_equal 'http://local.endpoint', d.instance.instance_eval{ @endpoint_url }
    assert_equal "", d.instance.instance_eval{ @http_retry_statuses }
    assert_equal [], d.instance.instance_eval{ @statuses }
    assert_equal 2.0, d.instance.instance_eval{ @http_read_timeout }
    assert_equal 2.0, d.instance.instance_eval{ @http_open_timeout }
  end

  def test_invalid_endpoint
    assert_raise Fluent::ConfigError do
      d = create_driver("endpoint_url \\@3")
    end

    assert_raise Fluent::ConfigError do
      d = create_driver("endpoint_url google.com")
    end
  end

  def test_write_status_retry
    setup_rspec(self)

    d = create_driver(%[
        endpoint_url http://local.endpoint
        http_retry_statuses 500
      ])

    d.emit("abc")

    http = double()
    http.stub(:finish)
    http.stub(:start).and_yield(http)
    http.stub(:request) do
      response = OpenStruct.new
      response.code = "500"
      response
    end

    d.instance.instance_eval{ @http = http }

    assert_raise RuntimeError do
      d.run
    end

    verify_rspec
    teardown_rspec
  end

  def test_write
    setup_rspec(self)

    d = create_driver("endpoint_url http://www.google.com/")

    d.emit("message")
    http = double("Net::HTTP")
    http.stub(:finish)
    http.stub(:start).and_yield(http)
    http.stub(:request) do |request|
      assert(request.body =~ /message/)
      response = OpenStruct.new
      response.code = "200"
      response
    end

    d.instance.instance_eval{ @http = http }

    data = d.run

    verify_rspec
    teardown_rspec
  end

  def test_include_tag_time
    setup_rspec(self)

    d = create_driver(CONFIG_TAGTIME)

    time = Time.parse("2011-01-02 13:14:15 JST").to_i
    record1 = {"f1" => 10, "f2" => 20 }
    record2 = {"f1" => 10, "f2" => 30 }
    d.emit(record1,time)
    d.emit(record2,time)
    http = double("Net::HTTP")
    http.stub(:finish)
    http.stub(:start).and_yield(http)
    http.stub(:request) do |request|
      record1['tag'] = "test"
      record1['time'] = time.to_s
      record2['tag'] = "test"
      record2['time'] = time.to_s
      expected = [record1,record2].to_json
      assert_equal expected, request.body
      response = OpenStruct.new
      response.code = "200"
      response
    end

    d.instance.instance_eval{ @http = http }

    data = d.run

    verify_rspec
    teardown_rspec
  end


end
