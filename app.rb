require 'sinatra'
require 'json'
require 'line/bot'
require 'mongoid'
require 'bson'
require 'api-ai-ruby'

# for graphing
require 'gruff'
require 'prawn'
require 'prawn/table'
require 'rmagick'

# for image url
require 'imgurapi'

Mongoid.load!("mongoid.yml")

class Patient
  include Mongoid::Document
  field :pid, type: Integer
  field :sex, type: String
  field :age, type: Integer
  field :english_content, type: String
  field :chinese_content, type: String
  field :date_content, type: Array
  field :decision, type: Integer
  field :death, type: Integer
  field :success, type: Integer

  def self.get_english_contents(filters)
    filters[:age] ||= 0..120
    Array.new.tap do |res|
      if filters[:sex] != "female"
        res += Patient.where(filters.merge({ sex: "male" })).map { |doc| doc.english_content }
      end
      if filters[:sex] != "male"
        res += Patient.where(filters.merge({ sex: "female" })).map { |doc| doc.english_content }
      end
    end
  end
end

class Imgur
  def self.client
    Imgurapi::Session.instance(
      client_id: ENV['IMGUR_CLIENT_ID'],
      client_secret: ENV['IMGUR_CLIENT_SECRET'],
      access_token: ENV['IMGUR_ACCESS_TOKEN'], # expires in a month (1.27 reg)
      refresh_token: ENV['IMGUR_REFRESH_TOKEN']
    )
  end

  def self.get_link_of_image(local_image) # NOTE: access token expires monthly, registerd at 1.27
    image = client.image.image_upload(local_image)
    image.link
  end
end

class LineBot
  def self.client
    @@client ||= Line::Bot::Client.new { |config|
      config.channel_secret = ENV['LINE_CHANNEL_SECRET']
      config.channel_token = ENV['LINE_CHANNEL_TOKEN']
    }
  end
end

class AI
  def self.client
    @@client ||= ApiAiRuby::Client.new { |config|
      config.client_access_token = ENV['AI_ACCESS_TOKEN']
    }
  end
end

class Text
  def initialize(text)
    @text = text
  end

  def get_term_count
    return Hash.new { |h, k| h[k] = 0 } if @text.empty?
    Hash.new { |h, k| h[k] = 0 } .tap do |tc|
      @text.split(/\W+/).each do |word|
        tc[word] += 1
      end
    end
  end
end

class Corpus
  def initialize(corpus)
    @corpus = corpus
  end

  def get_term_count_all
    @tcs ||= @corpus.map { |text| Text.new(text).get_term_count }
    @tc_all ||= Hash.new { |h, k| h[k] = 0 } .tap do |h|
      @tcs.each do |tc|
        tc.each do |t, c|
          h[t] += c
        end
      end
    end
  end

  def get_term_frequency
    @tcs ||= @corpus.map { |text| Text.new(text).get_term_count }
    @wcs ||= @tcs.map { |tc| tc.values.sum }
    @tc_all ||= get_term_count_all
    @tf ||= Hash.new { |h, k| h[k] = [] } .tap do |tf|
      @tc_all.each do |term, cnt|
        @tcs.zip(@wcs).each do |tc, dc|
          tf[term] << (tc.include?(term) ? tc[term].to_f / dc : 0)
        end
      end
    end
  end

  def get_term_existence
    @tc_all ||= get_term_count_all
    @te ||= Hash.new { |h, k| h[k] = 0 } .tap do |te|
      @tc_all.each do |term, _| 
        @tcs.each do |tc|
          te[term] += [tc[term], 1].min
        end
      end
    end
  end

  def get_tf_idf
    @tf ||= get_term_frequency
    @te ||= get_term_existence
    @idf = @te.map { |h, k| [h, Math.log(@corpus.size / k)] } .to_h
    @tf_idf = Hash.new { |h, k| h[k] = [] } .tap do |tfidf_by_term|
      @tc_all.each { |term, _|
        @corpus.size.times { |i|
          tfidf_by_term[term] << @tf[term][i] * (@idf[term] || 0)
        }
      }
    end
  end
end

class Graph
  attr_accessor :msg, :filter, :corpus, :args, :error

  def is_useful?(word:)
    return 0 if word.size == 1
    return 0 if %w(he his him boy man male she her girl lady female ml dl mmol item).include?(word.downcase)
    /[^a-zA-Z]/.match?(word) ? 0 : 1
  end

  def get_link_of_image
    return @error unless error.nil?
    Imgur.get_link_of_image(render_image(*@args))
  end
end

class PieGraph < Graph
  def initialize(message:, filter: {})
    @msg = message
    @filter = filter
    @corpus = Corpus.new(Patient.get_english_contents(@filter))
    tf_idf = @corpus.get_tf_idf
    @args = ['Term count', tf_idf.sort_by { |t, f| is_useful?(word: t) * -(f.sum) } .first(20).map { |t, f| [t, tc[t]] }]
  end

  def self.render_image(title, records)
    g = Gruff::Pie.new
    g.title = title
    records.each { |k, v| g.data(k, v) }
    g.write('pie.png')
    'pie.png'
  end
end

class TableGraph < Graph
  def initialize(message:, filter: {})
    @msg = message
    @filter = filter
    @corpus = Corpus.new(Patient.get_english_contents(@filter))
    tf_idf = @corpus.get_tf_idf
    @args = [[['Words' 'Times']] + tf_idf.sort_by { |t, f| is_useful?(word: t) * -(f.sum) } .first(20).map { |t, f| [t, tc[t]] }]
  end

  def self.render_image(records)
    Prawn::Document.generate('table.pdf') do |pdf|
      table_data = records.map do |r|
        [Prawn::Table::Cell::Text.new(pdf, [0, 0], content: r[0], inline_format: true), *r[1..-1]]
      end
      pdf.table(table_data, width: 500)
    end
    Magick::Image.read('table.pdf')[0].write('table.jpg')
    'table.jpg'
  end
end

class LineGraph < Graph
  def initialize(message:, filter: {})
    @msg = message
    xname = /(?:x\s*|axis|around)+\s*(?::|\-|upon|is|in|on|by|at|for|with|as|\s*)\s*([^\s]+)\s*/i.match(@msg)[1] rescue nil
    xname = Format.normalize_label(xname)
    return @error = "If you want to render a line graph, please also tell me which attribute the x-axis will be around. Note that for now only x for date is available." if xname.nil?
    xlabels = []
    case xname
    when :date
      dcss = Patient.where(@filter).map { |pt| pt.date_content }
      dcss = dcss.map { |dcs| dcs.sort_by { |dc| dc[0] * 13 * 50 + dc[1] * 50 + dc[2] } .map { |dc| dc[3] || "" } }
      dn = [dcss.map(&:size).max, 10].min
      dcss += [[""] * dn] * [dn - dcss.size, 0].max
      dcss = dcss.map { |dcs| dcs = dcs.first(dn); dcs += [""] * [(dcss.size - dcs.size), 0].max }
      ecs = dcss.transpose.map { |ds| ds.join(' ') } .first(dn)
      xlabels = (1..dn).to_a
    end
    @corpus = Corpus.new(ecs)
    tf = @corpus.get_term_frequency
    tf_idf = @corpus.get_tf_idf
    records = tf_idf.sort_by { |t, f| is_useful?(word: t) * -(f.sum) } .first(10).map(&:first).map { |t, f| [t, *tf[t]] }
    @args = ["Term frequency over #{xname}", xlabels, records]
  end

  def self.render_image(title, xlabels, records)
    g = Gruff::Line.new(800)
    g.title = title
    g.theme = {
      colors: %w(red blue yellow cyan green purple grey pink brown orange),
      font_color: 'white',
      background_colors: 'black'
    }
    g.labels = (0...(xlabels.size)).zip(xlabels).to_h
    records.each { |r| g.data(r[0], r[1..-1]) }
    g.write('line.png')
    'line.png'
  end
end

class BarGraph < Graph
  def initialize(message:, filter: {})
    @msg = message
    xname = /(?:group|bar\s*|categorize|categorized)+\s*(?:by|on|\s*)\s*([^\s]+)\s*/i.match(@msg)[1] rescue nil
    xname = Format.normalize_label(xname)
    return @error = "If you want to render a bar graph, please also tell me which attribute you want to categorize on. Note that for now only grouping by sex or age is available." if xname.nil?
    xlabels = []
    case xname
    when :sex
      ecs = [Patient.get_english_contents(@filter.merge({ sex: 'male' })).join(' '), Patient.get_english_contents(@filter.merge({ sex: 'female' })).join(' ')]
      xlabels = [:male, :female]
    when :age
      age_range = @filter[:age] || (0..120)
      st = age_range.first
      gap_len = [age_range.size / 10, 1].max
      gn = (age_range.size + gap_len - 1) / gap_len
      ecs = (0...gn).map { |g| Patient.get_english_contents(@filter.merge({ age: (st + g * gap_len)...(st + (g + 1) * gap_len) })).join(' ') }
      xlabels = (0...gn).map { |g| (st + g * gap_len).to_s + ?~ }
    end
    @corpus = Corpus.new(ecs)
    tf = @corpus.get_term_frequency
    tf_idf = @corpus.get_tf_idf
    records = tf_idf.sort_by { |t, f| is_useful?(word: t) * -(f.sum) } .first(10).map(&:first).map { |t, f| [t, *tf[t]] }
    @args = ["Term frequency over #{xname}", xlabels, records]
  end

  def self.render_image(title, xlabels, records)
    g = Gruff::Bar.new(800)
    g.title = title
    g.theme = {
      colors: %w(red blue yellow cyan green purple grey pink brown orange),
      font_color: 'white',
      background_colors: 'black'
    }
    g.labels = (0...(xlabels.size)).zip(xlabels).to_h
    records.each { |r| g.data(r[0], r[1..-1]) }
    g.write('bar.png')
    'bar.png'
  end
end

module Parser
  def self.parse_sex(s)
    m_key = %w(man male his him himself he boy)
    f_key = %w(woman female her herself she girl)
    mcnt, fcnt = 0, 0
    s.split(/\W+/).each do |w|
      mcnt += m_key.include?(w) ? 1 : 0
      fcnt += f_key.include?(w) ? 1 : 0
    end
    mcnt == fcnt ? nil : mcnt > fcnt ? "male" : "female"
  end

  def self.parse_age(s)
    age_low, age_high = nil, nil
    [
      /(\d+)[^\d]{1,20}(\d+)[^\d]{1,20}year/i, /(\d+)[^\d]{1,20}year/i,
      /age[^\d]{1,20}(\d+)[^\d]{1,20}(\d+)/i, /age[^\d]{1,20}(\d+)/i
    ] .each do |reg|
      age_low, age_high = reg.match(s)[1..-1] rescue nil
      break unless age_low.nil?
    end
    return 0..120 if age_low.nil?
    age_high ||= age_low
    age_low = age_low.to_i
    age_high = age_high.to_i
    age_low, age_high = age_high, age_low if age_low > age_high
    age_low..age_high
  end
end

module Format
  def normalize_label(name)
    return nil if name.nil?
    return :sex if %w(sex gender).include? name
    return :age if %w(age year old).include? name
    return :date if %w(time date day days).include? name
  end

  def normalize_reply(reply)
    if /^https?:\/\/(i\.)?imgur\.com\/.*\.(png|jpg)$/.match?(reply)
      { type: 'image', originalContentUrl: reply, previewImageUrl: reply }
    else
      { type: 'text', text: reply }
    end
  end
end

class Processor
  attr_accessor :msg, :filter

  def process_frequency_query
    words = @msg.downcase.split(/\W+/)
    return nil if words.none? { |w| w.start_with?('freq') || w.start_with?('tf') }
    {
      line: %w(relation relates relating related line plot plots),
      table: %w(table list listed lists),
      pie: %w(pie chart charts picture pictures pictured picturing),
      bar: %w(bar group groups grouped grouping categorize categorizes categorized categorizing)
    } .each do |graph_type, keys|
      if words.any? { |w| keys.include?(w) }
        graph = send("#{graph_type.capitalize}Graph.new", message: @msg, filter: @filter)
        return graph.get_link_of_image
      end
    end
    'If you want to render some graph for term frequency, please specify which kind of graph is desired. Line graph, pie graph, bar graph, and table is available'
  end

  def process_message(message)
    @msg = message
    @filter = { sex: Parser.parse_sex(@msg), age: Parser.parse_age(@msg) } .compact

    reply_frequency_query ||= process_frequency_query
    return reply_frequency_query unless reply_frequency_query.nil?

    # fallback by dialogflow
    
    ai_res = AI.client.text_request(msg)
    actions = (ai_res[:result][:action] + ?;).split(?;)
    rep_msg = nil
    until actions.empty?
      action = actions.shift
      case action
      when "show_info"; rep_msg = "Filters are: #{$filter_info.values.join(", ")}"
      when "unknown"; rep_msg = "Did you say: " + msg + ??
      end
    end
    rep_msg || ai_res[:result][:fulfillment][:speech]
  end
end

$processors = {}
 
post '/callback' do
  body = request.body.read

  signature = request.env['HTTP_X_LINE_SIGNATURE']
  unless LineBot.client.validate_signature(body, signature)
    error 400 do 'Bad Request' end
  end

  events = LineBot.client.parse_events_from(body)
  events.each do |event|
    case event
    when Line::Bot::Event::Message
      case event.type
      when Line::Bot::Event::MessageType::Text
        msg_from_user = event.message['text']
        reply = Processor.new.process_message(msg_from_user)
        LineBot.client.reply_message(event['replyToken'], Format.normalize_reply(reply))
      when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
        response = line_client.get_message_content(event.message['id'])
        Tempfile.open("content").write(response.body)
      end
    end
  end

  'OK'
end
