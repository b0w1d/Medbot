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
end

def line_client
  @client ||= Line::Bot::Client.new { |config|
    config.channel_secret = ENV['LINE_CHANNEL_SECRET']
    config.channel_token = ENV['LINE_CHANNEL_TOKEN']
  }
end

def ai_client
  @ai_client ||= ApiAiRuby::Client.new { |config|
    config.client_access_token = ENV['AI_ACCESS_TOKEN']
  }
end

def imgur_client
  Imgurapi::Session.instance(
    client_id: ENV['IMGUR_CLIENT_ID'],
    client_secret: ENV['IMGUR_CLIENT_SECRET'],
    access_token: ENV['IMGUR_ACCESS_TOKEN'], # expires in a month (1.27 reg)
    refresh_token: ENV['IMGUR_REFRESH_TOKEN']
  )
end

def get_english_contents(filters)
  filters[:age] ||= 0..120
  res = []
  sex_is_nil = filters[:sex].nil?
  if filters[:sex] == "male" || sex_is_nil
    filters[:sex] = "male"
    res += Patient.where(filters).map { |doc| doc.english_content }
  end
  if filters[:sex] == "female" || sex_is_nil
    filters[:sex] = "female"
    res += Patient.where(filters).map { |doc| doc.english_content }
  end
  filters[:sex] = nil if sex_is_nil
  res
end

def get_tc(text)
  return Hash.new { |h, k| h[k] = 0 } if text.empty?
  Hash.new { |h, k| h[k] = 0 } .tap do |tc|
    begin
      text.split(/\W+/).each do |word|
        tc[word] += 1
      end
    rescue
    end
  end
end

def get_tc_all(tcs)
  Hash.new { |h, k| h[k] = 0 } .tap { |h|
    tcs.each { |tc|
      tc.each { |t, c| h[t] += c }
    }
  }
end

def get_tf(corpus, tcs: nil, tc_all: nil)
  tcs ||= corpus.map { |doc| get_tc(doc) }
  doc_size = tcs.map { |tc| tc.values.sum }
  tc_all ||= get_tc_all(tcs)
  Hash.new { |h, k| h[k] = [] } .tap do |tf|
    tc_all.each { |term, cnt|
      tcs.zip(doc_size).each { |tc, dc| tf[term] << (tc.include?(term) ? tc[term].to_f / dc : 0) }
    }
  end
end

def get_te(corpus, tcs: nil, tc_all:nil)
  tcs ||= corpus.map { |doc| get_tc(doc) }
  tc_all ||= get_tc_all(tcs)
  Hash.new { |h, k| h[k] = 0 } .tap do |te|
    tc_all.each { |term, _| 
      tcs.each { |tc| te[term] += [tc[term], 1].min }
    } 
  end
end

def get_tf_idf(corpus, tf: nil) # NOTE: returns a hash with a term's highest tf-idf in corpus
  tcs = corpus.map { |doc| get_tc(doc) }
  tc_all = get_tc_all(tcs)
  tf ||= get_tf(corpus, tcs: tcs, tc_all: tc_all)
  te = get_te(corpus, tcs: tcs, tc_all: tc_all)
  idf = te.map { |h, k| [h, Math.log(corpus.size / k)] } .to_h
  Hash.new { |h, k| h[k] = [] } .tap do |tfidf_by_term|
    tc_all.each { |term, _|
      corpus.size.times { |i|
        tfidf_by_term[term] << tf[term][i] * (idf[term] || 0)
      }
    }
  end
end

def get_pie(title, records)
  g = Gruff::Pie.new
  g.title = title
  records.each { |k, v| g.data(k, v) }
  g.write('pie.png')
  'pie.png'
end

def get_table(records)
  Prawn::Document.generate('table.pdf') do |pdf|
    table_data = records.map do |r|
      [Prawn::Table::Cell::Text.new(pdf, [0, 0], content: r[0], inline_format: true), *r[1..-1]]
    end
    pdf.table(table_data, width: 500)
  end
  Magick::Image.read('table.pdf')[0].write('table.jpg')
  'table.jpg'
end

def get_line(title, xlabels, records)
  g = Gruff::Line.new(800)
  g.title = title
  g.theme = {
    :colors => %w(red blue yellow cyan green purple grey pink brown orange),
    :font_color => 'white',
    :background_colors => 'black'
  }
  g.labels = (0...(xlabels.size)).zip(xlabels).to_h
  records.each { |r| g.data(r[0], r[1..-1]) }
  g.write('line.png')
  'line.png'
end

def get_bar(title, xlabels, records)
  g = Gruff::Bar.new(800)
  g.title = title
  g.theme = {
    :colors => %w(red blue yellow cyan green purple grey pink brown orange),
    :font_color => 'white',
    :background_colors => 'black'
  }
  g.labels = (0...(xlabels.size)).zip(xlabels).to_h
  records.each { |r| g.data(r[0], r[1..-1]) }
  g.write('bar.png')
  'bar.png'
end

def is_word?(word)
  return 0 if %w(he his him boy man male she her girl lady female).include?(word.downcase)
  /[^a-zA-Z]/.match?(word) ? 0 : 1
end

def get_args_freq_pie(options = {})
  ecs = get_english_contents($filter_info)
  tc = get_tc(ecs.join(' '))
  ['Term count', get_tf_idf(ecs).sort_by { |t, f| is_word?(t) * -(f.sum) } .first(20).map { |t, f| [t, tc[t]] }]
end

def get_args_freq_table(options = {})
  ecs = get_english_contents($filter_info)
  tc = get_tc(ecs.join(' '))
  [[['Words' 'Times']] + get_tf_idf(ecs).sort_by { |t, f| is_word?(t) * -(f.sum) } .first(20).map { |t, f| [t, tc[t]] }]
end

def get_args_freq_line(options = {})
  xname = /(?:x|axis|around)*\s*(?::|\-|upon|is|in|on|by|at|for|with|as|\s*)\s*([^\s]+)\s*/i.match(options[:msg])[1] rescue nil
  xname = format_label(xname)
  return "If you want to render a line graph, please also tell me which attribute the x-axis will be around. Note that for now only x for date is available." if xname.nil?
  xlabels = []
  case xname
  when :date
    dcss = Patient.where($filter_info).map { |pt| pt.date_content }
    dcss = dcss.map { |dcs| dcs.sort_by { |dc| dc[0] * 13 * 50 + dc[1] * 50 + dc[2] } .map { |dc| dc[3] || "" } }
    dn = [dcss.map(&:size).max, 10].min
    dcss = dcss.map { |dcs| dcs = dcs.first(dn); dcs += [""] * [(dcss.size - dcs.size), 0].max }
    dcss += [[""] * dn] * [dn - dcss.size, 0].max
    ecs = dcss.transpose.map { |ds| ds.join(' ') } .first(dn)
    xlabels = (1..dn).to_a
  end
  tf = get_tf(ecs)
  records = get_tf_idf(ecs, tf: tf).sort_by { |t, f| is_word?(t) * -(f.sum) } .first(10).map(&:first).map { |t, f| [t, *tf[t]] }
  ["Term frequency over #{xname}", xlabels, records]
end

def get_args_freq_bar(options = {})
  xname = /(?:group|bar|categorize|categorized)*\s*(?:by|on|\s*)\s*([^\s]+)\s*/i.match(options[:msg])[1] rescue nil
  xname = format_label(xname)
  return "If you want to render a bar graph, please also tell me which attribute you want to categorize on. Note that for now only grouping by sex or age is available." if xname.nil?
  xlabels = []
  case xname
  when :sex
    ecs = [get_english_contents($filter_info.merge({ sex: 'male' })).join(' '),
           get_english_contents($filter_info.merge({ sex: 'female' })).join(' ')]
    xlabels = [:male, :female]
  when :age
    age_range = $filter_info[:age] || (0..120)
    st = age_range.first
    gap_len = [age_range.size / 10, 1].max
    gn = (age_range.size + gap_len - 1) / gap_len
    ecs = (0...gn).map { |g| get_english_contents($filter_info.merge({ age: (st + g * gap_len)...(st + (g + 1) * gap_len) })).join(' ') }
    xlabels = (0...gn).map { |g| (st + g * gap_len).to_s + ?~ }
  end
  tf = get_tf(ecs)
  records = get_tf_idf(ecs, tf: tf).sort_by { |t, f| is_word?(t) * -(f.sum) } .first(10).map(&:first).map { |t, f| [t, *tf[t]] }
  ["Term frequency over #{xname}", xlabels, records]
end

def get_link_of_image(local_image) # NOTE: access token expires every month, registerd at 1.27
  image = imgur_client.image.image_upload(local_image)
  image.link
end

def parse_sex(s)
  m_key = %w(man male his him himself he boy)
  f_key = %w(woman female her herself she girl)
  mcnt, fcnt = 0, 0
  s.split(/[^\w]/).each do |w|
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

$filter_info = {}
 
def freq_process(msg)
  words = msg.downcase.split(/[^\w]/)
  return nil if words.none? { |w| w.start_with?('freq') || w.start_with?('tf') }
  $filter_info = { sex: parse_sex(msg), age: parse_age(msg) } .compact
  {
    line: %w(relation relates relating related line plot plots),
    table: %w(table list listed lists),
    pie: %w(pie chart charts picture pictures pictured picturing),
    bar: %w(bar group groups grouped grouping categorize categorizes categorized categorizing)
  } .each do |graph_type, keys|
    if words.any? { |w| keys.include?(w) }
      args = send("get_args_freq_#{graph_type}", msg: msg) rescue nil
      return args if args.is_a?(String)
      img = send("get_#{graph_type}", *args) rescue nil
      return img if (img[-1] rescue nil) == ?.
      img_link = get_link_of_image(img) rescue nil
      return img_link unless img_link.nil?
    end
  end
  'If you want to render some graph for term frequency, please specify which kind of graph is desired. Line graph, pie graph, bar graph, and table is available'
end

def process_message(msg)
  freq ||= freq_process(msg)
  return freq unless freq.nil?

  # fallback by dialogflow
  
  ai_res = ai_client.text_request(msg)
  actions = (ai_res[:result][:action] + ?;).split(?;)
  any_useful = false
  rep_msg = nil
  until actions.empty?
    action = actions.shift
    case action
    when "show_info"
      rep_msg = "Filters are: #{$filter_info.values.join(", ")}"
    when "unknown"
      rep_msg = "Did you say: " + msg + ??
    end
  end
  rep_msg || ai_res[:result][:fulfillment][:speech]
end

def format_label(name)
  return nil if name.nil?
  return :sex if %w(sex gender).include? name
  return :age if %w(age year old).include? name
  return :date if %w(time date day days).include? name
end

def format_reply(reply)
  if /^https?:\/\/(i\.)?imgur\.com\/.*\.(png|jpg)$/.match?(reply)
    { type: 'image', originalContentUrl: reply, previewImageUrl: reply }
  else
    { type: 'text', text: reply }
  end
end

post '/callback' do
  body = request.body.read

  signature = request.env['HTTP_X_LINE_SIGNATURE']
  unless line_client.validate_signature(body, signature)
    error 400 do 'Bad Request' end
  end

  events = line_client.parse_events_from(body)
  events.each do |event|
    case event
    when Line::Bot::Event::Message
      case event.type
      when Line::Bot::Event::MessageType::Text
        msg_from_user = event.message['text']
        reply = process_message(msg_from_user)
        line_client.reply_message(event['replyToken'], format_reply(reply))
      when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
        response = line_client.get_message_content(event.message['id'])
        Tempfile.open("content").write(response.body)
      end
    end
  end

  'OK'
end
