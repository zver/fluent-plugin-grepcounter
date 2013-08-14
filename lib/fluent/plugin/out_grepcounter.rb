# encoding: UTF-8
class Fluent::GrepCounterOutput < Fluent::Output
  Fluent::Plugin.register_output('grepcounter', self)

  config_param :input_key, :string
  config_param :regexp, :string, :default => nil
  config_param :count_interval, :time, :default => 5
  config_param :exclude, :string, :default => nil
  config_param :threshold, :integer, :default => 1
  config_param :comparator, :string, :default => '>='
  config_param :output_tag, :string, :default => nil
  config_param :add_tag_prefix, :string, :default => 'count'
  config_param :output_with_joined_delimiter, :string, :default => nil
  config_param :aggregate, :string, :default => 'tag'
  config_param :replace_invalid_sequence, :bool, :default => false
  config_param :store_file, :string, :default => nil

  attr_accessor :matches
  attr_accessor :last_checked

  def configure(conf)
    super

    @count_interval = @count_interval.to_i
    @input_key = @input_key.to_s
    @regexp = Regexp.compile(@regexp) if @regexp
    @exclude = Regexp.compile(@exclude) if @exclude
    @threshold = @threshold.to_i

    unless ['>=', '<='].include?(@comparator)
      raise Fluent::ConfigError, "grepcounter: comparator allows >=, <="
    end

    unless ['tag', 'all'].include?(@aggregate)
      raise Fluent::ConfigError, "grepcounter: aggregate allows tag/all"
    end

    case @aggregate
    when 'all'
      raise Fluent::ConfigError, "grepcounter: output_tag must be specified with aggregate all" if @output_tag.nil?
    when 'tag'
      # raise Fluent::ConfigError, "grepcounter: add_tag_prefix must be specified with aggregate tag" if @add_tag_prefix.nil?
    end

    if @store_file
      f = Pathname.new(@store_file)
      if (f.exist? && !f.writable_real?) || (!f.exist? && !f.parent.writable_real?)
        raise Fluent::ConfigError, "#{@store_file} is not writable"
      end
    end

    @matches = {}
    @counts  = {}
    @mutex = Mutex.new
  end

  def start
    super
    load_from_file
    @watcher = Thread.new(&method(:watcher))
  end

  def shutdown
    super
    @watcher.terminate
    @watcher.join
    store_to_file
  end

  # Called when new line comes. This method actually does not emit
  def emit(tag, es, chain)
    count = 0; matches = []
    # filter out and insert
    es.each do |time,record|
      value = record[@input_key]
      next unless match(value.to_s)
      matches << value
      count += 1
    end
    # thread safe merge
    @counts[tag] ||= 0
    @matches[tag] ||= []
    @mutex.synchronize do
      @counts[tag] += count
      @matches[tag] += matches
    end

    chain.next
  rescue => e
    $log.warn "grepcounter: #{e.class} #{e.message} #{e.backtrace.first}"
  end

  # thread callback
  def watcher
    # instance variable, and public accessable, for test
    @last_checked = Fluent::Engine.now
    while true
      sleep 0.5
      begin
        if Fluent::Engine.now - @last_checked >= @count_interval
          now = Fluent::Engine.now
          flush_emit(now - @last_checked)
          @last_checked = now
        end
      rescue => e
        $log.warn "grepcounter: #{e.class} #{e.message} #{e.backtrace.first}"
      end
    end
  end

  # This method is the real one to emit
  def flush_emit(step)
    time = Fluent::Engine.now
    flushed_counts, flushed_matches, @counts, @matches = @counts, @matches, {}, {}

    if @aggregate == 'all'
      count = 0; matches = []
      flushed_counts.keys.each do |tag|
        count += flushed_counts[tag]
        matches += flushed_matches[tag]
      end
      output = generate_output(count, matches)
      Fluent::Engine.emit(@output_tag, time, output) if output
    else
      flushed_counts.keys.each do |tag|
        count = flushed_counts[tag]
        matches = flushed_matches[tag]
        output = generate_output(count, matches, tag)
        tag = @output_tag ? @output_tag : "#{@add_tag_prefix}.#{tag}"
        Fluent::Engine.emit(tag, time, output) if output
      end
    end
  end

  def generate_output(count, matches, tag = nil)
    return nil if count.nil?
    return nil if count == 0 # ignore 0 because standby nodes receive no message usually
    return nil unless eval("#{count} #{@comparator} #{@threshold}")
    output = {}
    output['count'] = count
    output['message'] = @output_with_joined_delimiter.nil? ? matches : matches.join(@output_with_joined_delimiter)
    if tag
      output['input_tag'] = tag
      output['input_tag_last'] = tag.split('.').last
    end
    output
  end

  def match(string)
    begin
      return false if @regexp and !@regexp.match(string)
      return false if @exclude and @exclude.match(string)
    rescue ArgumentError => e
      unless e.message.index("invalid byte sequence in") == 0
        raise
      end
      string = replace_invalid_byte(string)
      return false if @regexp and !@regexp.match(string)
      return false if @exclude and @exclude.match(string)
    end
    return true
  end

  def replace_invalid_byte(string)
    replace_options = { invalid: :replace, undef: :replace, replace: '?' }
    original_encoding = string.encoding
    temporal_encoding = (original_encoding == Encoding::UTF_8 ? Encoding::UTF_16BE : Encoding::UTF_8)
    string.encode(temporal_encoding, original_encoding, replace_options).encode(original_encoding)
  end

  def store_to_file
    return unless @store_file

    begin
      Pathname.new(@store_file).open('wb') do |f|
        Marshal.dump({
          :counts           => @counts,
          :matches          => @matches,
          :regexp           => @regexp,
          :exclude          => @exclude,
          :input_key        => @input_key,
        }, f)
      end
    rescue => e
      $log.warn "out_grepcounter: Can't write store_file #{e.class} #{e.message}"
    end
  end

  def load_from_file
    return unless @store_file
    return unless (f = Pathname.new(@store_file)).exist?

    begin
      f.open('rb') do |f|
        stored = Marshal.load(f)
        if stored[:regexp] == @regexp and
          stored[:exclude] == @exclude and
          stored[:input_key]  == @input_key
          @counts = stored[:counts]
          @matches = stored[:matches]
        else
          $log.warn "out_grepcounter: configuration param was changed. ignore stored data"
        end
      end
    rescue => e
      $log.warn "out_grepcounter: Can't load store_file #{e.class} #{e.message}"
    end
  end

end