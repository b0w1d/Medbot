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

# for summarizing
require 'summarize'

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

  def self.get_english_contents(filters = {}, keyword = nil)
    filters[:age] ||= 0..120
    Array.new.tap do |res|
      if filters[:sex] != "female"
        res << Patient.where(filters.merge({ sex: "male" })).map { |doc| doc.english_content }
      end
      if filters[:sex] != "male"
        res << Patient.where(filters.merge({ sex: "female" })).map { |doc| doc.english_content }
      end
    end.inject(:+).select { |t| t.match?(/#{keyword}/i) }
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
    return 0 if word.size <= 1
    return 0 if word.match?(/[^a-zA-Z]/)
    return 0 if %w(and with of he his him boy man male she her girl lady female ml dl mmol item and with of to for was on the mg time or is are they them their doctor hospital in no under below above status at days without).include?(word.downcase)
    /[^a-zA-Z]/.match?(word) ? 0 : 1
  end

  def get_link_of_image
    return @error unless error.nil?
    Imgur.get_link_of_image(render_image(*@args))
  end
end

class PieGraph < Graph
  def initialize(message:, filter: {}, keyword:)
    @msg = message
    @filter = filter
    @corpus = Corpus.new(Patient.get_english_contents(@filter, keyword))
    tc = @corpus.get_term_count_all
    tf_idf = @corpus.get_tf_idf
    suffix = " with #{@filter.to_s.tr('{:}\"', '').gsub('=>', ': ')}"
    @args = ["Term count#{suffix}", tf_idf.sort_by { |t, f| is_useful?(word: t) * -(f.sum) } .first(20).map { |t, f| [t, tc[t]] }]
  end

  def render_image(title, records)
    g = Gruff::Pie.new
    g.title = title
    records.each { |k, v| g.data(k, v) }
    g.write('pie.png')
    'pie.png'
  end
end

class TableGraph < Graph
  def initialize(message:, filter: {}, keyword:)
    @msg = message
    @filter = filter
    @corpus = Corpus.new(Patient.get_english_contents(@filter, keyword))
    tc = @corpus.get_term_count_all
    tf_idf = @corpus.get_tf_idf
    suffix = " with #{@filter.to_s.tr('{:}\"', '').gsub('=>', ': ')}"
    @args = [[["Words#{suffix}", 'Times']] + tf_idf.sort_by { |t, f| is_useful?(word: t) * -(f.sum) } .first(20).map { |t, f| [t, tc[t]] } .sort_by { |t, f| -f }]
  end

  def render_image(records)
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
  def initialize(message:, filter: {}, keyword:)
    @msg = message
    @filter = filter
    xname = /(?:x\s*|axis|around)+\s*(?::|\-|upon|is|in|on|by|at|for|with|as|\s*)\s*([^\s]+)\s*/i.match(@msg)[1] rescue nil
    xname = Format.normalize_label(xname)
    return @error = "If you want to render a line graph, please also tell me which attribute the x-axis will be around. Note that for now only x for date is available." if xname.nil?
    xlabels = []
    case xname
    when :date
      dcss = Patient.where(@filter).map do |pt|
        pt.date_content.map do |x|
          x[3] = "" unless x[3].match?(/#{keyword}/i)
          x
        end
      end
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
    suffix = " with #{@filter.to_s.tr('{:}\"', '').gsub('=>', ': ')}"
    @args = ["TF over #{xname}#{suffix}", xlabels, records]
  end

  def render_image(title, xlabels, records)
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
  def initialize(message:, filter: {}, keyword:)
    @msg = message
    @filter = filter
    xname = /(?:group|bar\s*|categorize|categorized|graph\s*)+\s*(?:by|on|\s*)\s*([^\s]+)\s*/i.match(@msg)[1] rescue nil
    xname = Format.normalize_label(xname)
    return @error = "If you want to render a bar graph, please also tell me which attribute you want to categorize on. Note that for now only grouping by sex or age is available." if xname.nil?
    xlabels = []
    case xname
    when :sex
      ecs = [Patient.get_english_contents(@filter.merge({ sex: 'male' }), keyword).join(' '), Patient.get_english_contents(@filter.merge({ sex: 'female' }), keyword).join(' ')]
      xlabels = [:male, :female]
    when :age
      age_range = @filter[:age] || (0..120)
      st = age_range.first
      gap_len = [age_range.size / 10, 1].max
      gn = (age_range.size + gap_len - 1) / gap_len
      ecs = (0...gn).map { |g| Patient.get_english_contents(@filter.merge({ age: (st + g * gap_len)...(st + (g + 1) * gap_len) }), keyword).join(' ') }
      xlabels = (0...gn).map { |g| (st + g * gap_len).to_s + ?~ }
    end
    @corpus = Corpus.new(ecs)
    tf = @corpus.get_term_frequency
    tf_idf = @corpus.get_tf_idf
    records = tf_idf.sort_by { |t, f| is_useful?(word: t) * -(f.sum) } .first(10).map(&:first).map { |t, f| [t, *tf[t]] }
    suffix = " with #{@filter.to_s.tr('{:}\"', '').gsub('=>', ': ')}"
    @args = ["TF over #{xname}#{suffix}", xlabels, records]
  end

  def render_image(title, xlabels, records)
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
  extend self

  def parse_sex(s)
    m_key = %w(man male his him himself he boy)
    f_key = %w(woman female her herself she girl)
    mcnt, fcnt = 0, 0
    s.split(/\W+/).each do |w|
      mcnt += m_key.include?(w) ? 1 : 0
      fcnt += f_key.include?(w) ? 1 : 0
    end
    mcnt == fcnt ? nil : mcnt > fcnt ? "male" : "female"
  end

  def parse_age(s)
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
  extend self

  def normalize_label(name)
    return nil if name.nil?
    name = name.match(/[a-zA-Z]+/)[0]
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
        graph = eval("#{graph_type.capitalize}Graph.new(message: @msg, filter: @filter, keyword: (@msg.match(/keyword.*(?:is|:)\s*([a-z]+)/i)[1] rescue nil))")
        return graph.get_link_of_image
      end
    end
    'If you want to render some graph for term frequency, please specify which kind of graph is desired. Line graph, pie graph, bar graph, and table is available'
  end
  
  def process_effect_query
    words = @msg.downcase.split(/\W+/)
    return nil if words.none? { |w| w.start_with?('result') || w.start_with?('after') || w.start_with?('effect') }
    keyword = @msg.match(/keyword.*(?:is|:)\s*([a-z]+)/i)[1] rescue nil
    return nil if keyword.nil?
=begin
    dcss = Patient.where({}).map do |pt|
      pt.date_content.map do |x|
        x[3] = "" unless x[3].match?(/#{keyword}/i)
        x
      end
    end
    dcss = dcss.map { |dcs| dcs.sort_by { |dc| dc[0] * 13 * 50 + dc[1] * 50 + dc[2] } .map { |dc| dc[3] || "" } }
    dn = [dcss.map(&:size).max, 10].min
    dcss += [[""] * dn] * [dn - dcss.size, 0].max
    dcss = dcss.map { |dcs| dcs = dcs.first(dn); dcs += [""] * [(dcss.size - dcs.size), 0].max }
    ecs = dcss.transpose.map { |ds| ds.join(' ') } .first(dn)
    @corpus = Corpus.new(ecs)
    tf_idf = @corpus.get_tf_idf
    g = Graph.new
    res = tf_idf.sort_by { |t, f| (g.is_useful?(word: t) & (t == keyword ? 0 : 1))* -(f.sum) } .first(5).map(&:first).map { |t, f| t }
=end
    kc = Hash.new { |h, k| h[k] = 0 }
    g = Graph.new
    dcss = Patient.where({}).map do |pt|
      pt.date_content.each do |x|
        x[3].split(/\./).each do |s|
          if s.match?(/#{keyword}/)
            s.split(/[\s]/).each do |w|
              kc[w] += 1 if g.is_useful?(word: w) > 0
            end
          end
        end
      end
    end
    res = kc.to_a.sort_by { |k, v| -v } .reject { |k, v| k == keyword } .first(5).map(&:first)
    "These things might occur as result, relating to the keyword #{keyword}: " + res.join(', ') + ?.
  end

  def process_help_query
    words = @msg.downcase.split(/\W+/)
    return nil if words.none? { |w| w.start_with?('help') }
    <<-EOS
usage: 

- You can ask me to predict results by keyword:
e.g., "Tell me what would happen as result, the keyword is cancer"

- You can ask me to render a graph or table for term frequency analysis:
e.g., "Term frequency table graph where x is date, for male, age from 60 to 70. Keyword is PO"
e.g., "Term frequency line graph where x is date, female, age 60 to 70"
e.g., "Term frequency bar graph, group by gender, keyword is aortic"
e.g., "Term frequency pie chart, age between 50 to 60"
    EOS
  end

  def process_message(message)
    @msg = message
    @filter = { sex: Parser.parse_sex(@msg), age: Parser.parse_age(@msg) } .compact

    reply_frequency_query ||= process_frequency_query
    return reply_frequency_query unless reply_frequency_query.nil?

    reply_effect_query ||= process_effect_query
    return reply_effect_query unless reply_effect_query.nil?

    reply_help_query ||= process_help_query
    return reply_help_query unless reply_help_query.nil?

    # return "I don't know what you are talking about. You can submit 'help' to know more about what I can do."

    # fallback by dialogflow
    
    ai_res = AI.client.text_request(@msg)
    actions = (ai_res[:result][:action] + ?;).split(?;)
    rep_msg = nil
    until actions.empty?
      action = actions.shift
      case action
      when "show_info"; rep_msg = "Filters are: #{@filter.values.join(", ") rescue "None"}."
      when "unknown"; rep_msg = "Did you say: #{@msg}?"
      end
    end
    rep_msg || ai_res[:result][:fulfillment][:speech]
  end
end

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
