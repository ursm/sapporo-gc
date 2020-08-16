require 'bundler/setup'
Bundler.require

class GarbageCollection
  WDAYS_JA = %w(
    日曜日
    月曜日
    火曜日
    水曜日
    木曜日
    金曜日
    土曜日
  )

  def initialize(name, days: '', wdays: '')
    @name  = name
    @days  = extract_days(days)
    @wdays = extract_wdays(wdays)
  end

  attr_reader :name

  def today?(date)
    @days.include?(date.day) || @wdays.include?(date.wday)
  end

  private

  def extract_days(str)
    str.to_s.scan(/(\d+)日/).map {|day, *|
      Integer(day)
    }
  end

  def extract_wdays(str)
    str.to_s.scan(/.曜日/).map {|wday|
      WDAYS_JA.index(wday)
    }
  end
end

def generate_calendar(group_html)
  re = /
    (?<year>.+?)年(?<month>\d+)月の(?:、|収集日です。)燃やせるごみは、毎週(?<burnable_wday>.+?)です。
    びん・缶・(?:ペ|ヘ゜)ット(?:ボ|ホ゛)トルは毎週(?<bottle_wday>.+?)、容器包装プラスチックは毎週(?<packaging_wday>.+?)です。?、?
    雑+がみは?(?<paper_day>.+?)の(?<paper_wday>.+?)です。
    (?:燃やせないごみは(?<non_burnable_day>.+?)の(?<non_burnable_wday>.+?)です。|(?:\d+月は)?燃やせないごみの収集はありません。)
    (?:枝・葉・草は?(?<branch_day>.+?)の(?<branch_wday>.+?)です。|(?:\d+月[はの]?)?枝・葉・草の収集はありませんん?。)
  /x

  matches = group_html.xpath('//*[@id="tmp_contents"]//p[a[@id]]/text()').each_with_object([]) {|node, memo|
    line = node.text.strip

    next if line.empty?

    if match = re.match(line)
      memo << match
    else
      warn "unmatched line: #{line.inspect}"
    end
  }

  calendar = Icalendar::Calendar.new
  calendar.append_custom_property 'X-WR-CALNAME', "札幌市ごみ収集日カレンダー #{group_html.css('#tmp_contents h1').text.strip}"

  matches.each do |match|
    collections = [
      GarbageCollection.new('燃やせるごみ',             wdays: match[:burnable_wday]),
      GarbageCollection.new('びん・かん・ペットボトル', wdays: match[:bottle_wday]),
      GarbageCollection.new('容器包装プラスチック',     wdays: match[:packaging_wday]),
      GarbageCollection.new('雑がみ',                   days:  match[:paper_day]),
      GarbageCollection.new('燃やせないごみ',           days:  match[:non_burnable_day]),
      GarbageCollection.new('枝・葉・草',               days:  match[:branch_day]),
    ]

    begin_of_month = Wareki::Date.parse("#{match[:year].sub('平成31令和2', '令和2')}年 #{match[:month]}月 1日").to_date
    end_of_month   = Date.civil(begin_of_month.year, begin_of_month.month, -1)

    begin_of_month.upto end_of_month do |date|
      collections.each do |collection|
        next unless collection.today?(date)

        calendar.event do |event|
          event.summary = collection.name
          event.dtstart = Icalendar::Values::Date.new(date)
        end
      end
    end
  end

  calendar
end

require 'pathname'

HTML_ROOT   = Pathname.new('tmp/html')
PUBLIC_ROOT = Pathname.new('public')

if ENV['FETCH_HTML']
  wget_flags = %W(
    --accept=html
    --directory-prefix=#{HTML_ROOT}
    --mirror
    --no-host-directories
    --no-parent
    --wait=5
  )

  unless system('wget', *wget_flags, 'http://www.city.sapporo.jp/seiso/kaisyu/yomiage/index.html')
    exit 1
  end
end

PUBLIC_ROOT.join('ics').mkpath
toc = Hash.new {|h, k| h[k] = {} }

index_html = HTML_ROOT.join('seiso/kaisyu/yomiage/index.html').open(&Nokogiri::HTML.method(:parse))

index_html.css('#tmp_contents a[href^="/seiso/kaisyu/yomiage/"]').each do |ward_link|
  ward_html = HTML_ROOT.join(ward_link[:href].delete_prefix('/')).open(&Nokogiri::HTML.method(:parse))

  groups = ward_html.css('#tmp_contents a[href^="/seiso/kaisyu/yomiage/carender/"]').map {|link|
    [link, "ics/#{File.basename(link[:href], '.html')}.ics"]
  }

  groups.uniq {|link, ics_path|
    link[:href]
  }.each do |link, ics_path|
    group_html = HTML_ROOT.join(link[:href].delete_prefix('/')).open(&Nokogiri::HTML.method(:parse))

    PUBLIC_ROOT.join(ics_path).write generate_calendar(group_html).to_ical
  end

  groups.each do |link, ics_path|
    toc[ward_link.text][link.text] = ics_path
  end
end

PUBLIC_ROOT.join('index.html').write Haml::Engine.new(<<~'HAML').render Object.new, toc: toc
  !!!

  %html
    %head
      %meta(charset='utf-8')
      %title 札幌市ごみ収集日カレンダー

    %body
      %h1 札幌市ごみ収集日カレンダー

      - toc.each do |ward, groups|
        %h2= ward

        %ul
          - groups.each do |group, ics_path|
            %li
              %a(href=ics_path)= group
HAML
