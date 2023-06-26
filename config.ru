URLS = {
  :hourly => "https://www.wetter.com/deutschland/%{location}.html",
  :daily => "https://www.wetter.com/wetter_aktuell/wettervorhersage/7_tagesvorhersage/deutschland/%{location}.html",
}

require 'logger'
require 'nokogiri'
require 'typhoeus'

DetailedWeatherBox = Struct.new(:box_document, :scope, :opts) do
  def forecast_hour
    cache :forecast_hour do
      case scope
      when :hourly then box_document.attributes['data-num']&.value&.to_i
      when :daily
        ((period.max.to_f - Time.now.to_f) / 3600.0).ceil
      end
    end
  end

  def description
    cache :description do
      case scope
      when :hourly then content('.swg-col-text')
      when :daily then content('.swg-col-weather-text')
      end
    end
  end

  def icon
    cache :icon do
      box_document.search('.swg-col-icon img').first
        &.attributes
        &.to_h
        &.fetch('data-single-src')
        &.value
    end
  end

  def temperature
    cache :temperature do
      content('.swg-col-temperature span')&.to_i
    end
  end

  def period
    cache :period do
      now = Time.now
      case scope
      when :hourly
        result = content('.swg-col-period').to_s.scan(/\d+/).flatten.map(&:to_i).map do |hour|
          period_hour = Time.new(now.year, now.mon, now.day, hour, 0, 0)
          next period_hour if period_hour > now || forecast_hour == 1

          period_hour + 3600 * 24
        end
        break Range.new(*result) if result.size == 2
      when :daily
        offset = opts.fetch(:index)
        low_clock, high_clock = *content('.swg-col-text').to_s[/\d+ - \d+ Uhr/]
          &.scan(/\d+/)
          &.flatten
          &.map(&:to_i)
        now += offset * (3600 * 24)
        day_bump = 0
        day_bump = 1 if low_clock > high_clock
        Range.new(
          Time.new(now.year, now.mon, now.day, low_clock, 0, 0),
          Time.new(now.year, now.mon, now.day + day_bump, high_clock, 0, 0)
        )
      end
    end
  end

  def precipitation_probability
    cache :precipitation_probability do
      content('.swg-col-wv1')&.to_i
    end
  end

  def rainfall
    cache :rainfall do
      content('.swg-col-wv2').to_s.gsub(',', '.').to_f
    end
  end

  def wind_speed
    cache :wind_speed do
      content('.swg-col-wv3')&.to_i
    end
  end

  def gust_speed
    cache :gust_speed do
      content('.swg-col-wv3').to_s[/B.en (\d+)/,1]&.to_i
    end
  end

  def wind_direction
    cache :wind_direction do
      case content('.swg-col-wi3').to_s[/[NOSW]+/]
      when 'N' then 0
      when 'NO' then 45
      when 'O' then 90
      when 'SO' then 135
      when 'S' then 180
      when 'SW' then 225
      when 'W' then 270
      when 'NW' then 315
      end
    end
  end

  def attributes
    {
      forecast_hour: forecast_hour,
      period: period,
      description: description,
      temperature: temperature,
      precipitation_probability: precipitation_probability,
      wind_speed: wind_speed,
      gust_speed: gust_speed,
      wind_direction: wind_direction,
      rainfall: rainfall,
      icon: icon,
    }
  end

  alias to_h attributes

  def content(css_sel)
    box_document.search(css_sel).first&.text&.gsub(/\s{2,}/, ' ')&.delete("\n")&.strip
  end

  def cache(attribute)
    @cache ||= {}
    return @cache[attribute] if @cache.key?(attribute)
    @cache[attribute] = yield
  end
end

$error_count = 0

app = Rack::Builder.new do
  map '/metrics' do
    block = lambda do |env|
      loc = Rack::Utils.parse_nested_query(env['QUERY_STRING'])['target']
      if loc.nil?
	break error("target param not found")
      end

      def uniq_types
        @uniq_types ||= []
      end

      def metric(name, value, type: :gauge, **labels)
        t = "#TYPE #{name} #{type}"
        <<~METRIC.tap {uniq_types << t }
          #{t unless uniq_types.include?(t) }
          wettercom_#{name}{#{labels.map{ "#{_1}=#{_2.to_s.inspect}"}.join(',')}} #{value.to_f}
        METRIC
      end

      def logger
	@logger ||= ::Logger.new(STDERR).tap do
	  _1.level = ::Logger::INFO
	end
      end

      def error(message)
	logger.error(message)
	metrics << metric('error_count', $error_count += 1, type: :counter)
	[
	  500,
	  { 'content-type' => 'text/plain' },
	  StringIO.new(message)
	]
      end

      status = 200
      def metrics
	@metrics ||= []
      end

      documents = URLS.to_h do |mode, link|
	logger.debug "looking up weather data (#{mode})"
	resp = Typhoeus.get(link % {location: loc}, followlocation: 5)
	unless resp.success?
	  return error("failed loading today's weather data (#{resp.request.base_url}) return_code: #{resp.return_code} (#{resp.code})")
	end

	logger.debug "parsing html document #{link} (#{resp.body.bytes.size} bytes)"
	[mode, Nokogiri::HTML(resp.body)]
      end

      logger.debug "loading hourly boxes"
      hourly_boxes = documents[:hourly]
	.xpath('//*[@id="uebersicht"]')
	.flat_map do
	  _1.children
	    .select{ |element| element.attributes['class']&.to_s&.include?('row-wrapper') }
	end

      if hourly_boxes.size != 24
	break error("invalid amount of hourly boxes found (got: #{hourly_boxes.size}, expected: 24)")
      end

      parsed_hourly_boxes = hourly_boxes.map { DetailedWeatherBox.new(_1, :hourly, {}) }

      logger.debug "loading daily boxes"
      daily_boxes = documents[:daily]
	.search('.spaces-weather-grid .swg-row-wrapper')
	.each_slice(5)
	.to_a

      if daily_boxes.flatten.size != 35
	break error("invalid amount of daily boxes found (got: #{daily_boxes.size}, expected: 35)")
      end

      parsed_daily_boxes = daily_boxes.flat_map.with_index do |day_boxes, index|
	day_boxes[1..-1].map do
	  DetailedWeatherBox.new(_1, :daily, { index: index })
	end
      end

      parsed_daily_boxes.each do |box|
        forecast_hour = box.forecast_hour
        metrics << metric("daily_forcast_info", 1, level: forecast_hour, desc: box.description) 
        metrics << metric("daily_forcast_temperature", box.temperature, level: forecast_hour) 
        metrics << metric("daily_forcast_period_start_timestamp", box.period.first.to_f, level: forecast_hour) 
        metrics << metric("daily_forcast_period_end_timestamp", box.period.last.to_f, level: forecast_hour) 
        metrics << metric("daily_forcast_precipitation_probability_percentage", box.precipitation_probability, level: forecast_hour) 
        metrics << metric("daily_forcast_rainfall_liters", box.rainfall, level: forecast_hour) 
        metrics << metric("daily_forcast_wind_speed_kmh", box.wind_speed, level: forecast_hour) 
        metrics << metric("daily_forcast_gust_speed_kmh", box.gust_speed, level: forecast_hour) 
        metrics << metric("daily_forcast_wind_direction", box.wind_direction, level: forecast_hour) 
      end
      
      parsed_hourly_boxes.each do |box|
        forecast_hour = box.forecast_hour
        metrics << metric("hourly_forcast_info", 1, level: forecast_hour, desc: box.description) 
        metrics << metric("hourly_forcast_temperature", box.temperature, level: forecast_hour) 
        metrics << metric("hourly_forcast_period_start_timestamp", box.period.first.to_f, level: forecast_hour) 
        metrics << metric("hourly_forcast_period_end_timestamp", box.period.last.to_f, level: forecast_hour) 
        metrics << metric("hourly_forcast_precipitation_probability_percentage", box.precipitation_probability, level: forecast_hour) 
        metrics << metric("hourly_forcast_rainfall_liters", box.rainfall, level: forecast_hour) 
        metrics << metric("hourly_forcast_wind_speed_kmh", box.wind_speed, level: forecast_hour) 
        metrics << metric("hourly_forcast_gust_speed_kmh", box.gust_speed, level: forecast_hour) 
        metrics << metric("hourly_forcast_wind_direction", box.wind_direction, level: forecast_hour) 
      end

      [
        status,
        { 'content-type' => 'text/plain' },
        StringIO.new(metrics.join)
      ]
    rescue StandardError => err
      error("unknown error occured: #{err}\n#{err.backtrace.join("\n")}")
    ensure
      @metrics = nil
      @uniq_types = nil
    end
    run block
  end
end.to_app

run app

