require 'heliotrope-client'
require 'trollop'
require 'psych'

class Rule 

  # Map Gmail's matching capabilities to heliotrope's
  # https://developers.google.com/google-apps/email-settings/#manage_filters
  MATCHING_CAPABILITIES = {
    "from"                => "from",
    "to"                  => "to",
    "subject"             => "subject",
    "hasTheWord"          => "body",
    "doesNotHaveTheWord"  => nil,
    "hasAttachment"       => nil
  }

  # Map Gmail's action capabilities to heliotrope's
  ACTION_CAPABILITIES = {
    "shouldArchive"     =>  {"labels" =>  ["-inbox"]},
    "shouldMarkAsRead"  =>  {"state"  =>  ["-unread"]},
    "shouldStar"        =>  {"state"  =>  ["starred"]},
    "label"             =>  {"labels" =>  []},
    "forwardTo"         =>  nil,
    "shouldTrash"       =>  {"state"  =>  ["deleted"]},
    "shouldNeverSpam"   =>  {"state"  =>  ["-spam"]}
  }

  def initialize
    @criterias = {}
    @actions = {}
  end

  def add_raw_criteria pre_field, pre_value
    if ["from", "to", "subject"].include? pre_field
      add_matching_criteria pre_field, pre_value
    elsif pre_field == "body" || pre_field == "hasTheWord"
      add_generic_criteria pre_value
    else
      raise "Unknown field : #{pre_field}"
    end
  end

  def add_action name, value
    real_action = Marshal.load(Marshal.dump ACTION_CAPABILITIES[name])
    if real_action["labels"]
      if name == "label"
        real_action["labels"].push value 
      end
      real_action["labels"].uniq!
    end

    real_action["state"].uniq! if real_action["state"]
    @actions = real_action
  end

  private

  def add_matching_criteria field, string
    proper_string =string.gsub(/\"/,'')
    if @criterias[field]
      @criterias[field].push proper_string
      @criterias[field].uniq!
    else
      @criterias[field] = [proper_string]
    end
  end

  # splits with OR, and manages the list:, contains: and whatnots
  def add_generic_criteria string
    string.split(/OR/).each do |substring|
      substring.strip!
      case substring

      when /^list:/ # a mailing-list
        raise "Multi rule !"

      when /^from:/ # a from field
        replacement = substring.sub(/^from:/,'')
        add_matching_criteria "from", replacement
        
      when /^to:/ # a to field
        replacement = substring.sub(/^to:/,'')
        add_matching_criteria "to", replacement

      when /^contains:/ # a contains, which is just a body: for heliotrope
        replacement = substring.sub(/^contains:/,'')
        add_matching_criteria "body", replacement

      else # it's already a usable string
        add_matching_criteria "body", substring

      end

    end
  end

end


class Filter
  SEARCHABLE_FIELDS = Set.new %w(from to subject date body)

  def initialize opts
    @hc = HeliotropeClient.new "http://localhost:8042"
    @conf = Psych.load_file (opts.check || File.join(opts.dir, "filtering_rules.yml"))
    @gmail_filters_file = opts[:import]
  end

  def manual_heliotrope_run
    puts "---------------"
    @conf.each do |conf|

      # FROM HELIOTROPE side
      # we use a query which is of the form
      #   from:bob@test.com to:bob@test2.org subject:yeah


      # step 1 : get the matching threads
      query = ""

      matches = conf["criterias"]
      SEARCHABLE_FIELDS.each do |field|
        unless matches[field].nil? || matches[field].empty?
          if matches[field].respond_to? 'each'
            matches[field].each {|param| query << "#{field}:#{param} " }
          elsif matches[field].respond_to? '+'
            query << "#{field}:#{matches[field]}"
          end
        end
      end

      expected_labels = Set.new(conf["actions"]["labels"])
      expected_state = Set.new(conf["actions"]["state"])
      puts "looking for '#{query.strip}', should be labels:#{expected_labels.to_a} and state:#{expected_state.to_a}"
      results = @hc.search query.strip

      # step 2 : verify the labels and the state

      results.each do |r|
        actual_labels = Set.new(r["labels"])
        actual_state = Set.new(r["state"])

        is_erroneous_labels = !actual_labels.superset?(expected_labels)
        is_erroneous_state = !actual_state.superset?(expected_state)
        if is_erroneous_labels
          puts "-- pb on thread #{r["thread_id"]}: labels #{actual_labels.to_a} should contain #{expected_labels.to_a}"
          # @hc.set_labels! r["thread_id"], expected_labels.to_a
        end
        if is_erroneous_state
          puts "-- pb on thread #{r["thread_id"]}: state #{actual_state.to_a} should contain #{expected_state.to_a}"
          # TODO: we have to verify state for each message -- maybe later
        end
      end
      puts "------------------"
    end
  end

  def import
    require 'nokogiri'

    # Map Gmail's matching capabilities to heliotrope's
    # https://developers.google.com/google-apps/email-settings/#manage_filters
    matching_capabilities = Set.new %w(from to subject hasTheWord doesNotHaveTheWord hasAttachment)

    action_capabilities = Set.new %w(shouldArchive shouldMarkAsRead shouldStar label forwardTo shouldTrash shouldNeverSpam)

    final_file = []

    gmail_filters = Nokogiri::Slop(File.open(@gmail_filters_file))
    gmail_filters.xpath("//entry").each do |entry|

      rules = []
      entry.xpath("./property").each do |prop|

        match = matching_capabilities.include? prop.attributes["name"].to_s
        if match
          if prop.attributes["value"].to_s.match /^list:/
            replacement = prop.attributes["value"].to_s.sub(/^list:/,'').sub(/\./,'@').gsub(/<(\S+?@\S+?)>/, '\1')
            tmprule1 = Rule.new
            tmprule1.add_raw_criteria "from", replacement
            rules.push tmprule1

            tmprule2 = Rule.new
            tmprule2.add_raw_criteria "to", replacement
            rules.push tmprule2
          else
            tmprule = Rule.new
            tmprule.add_raw_criteria prop.attributes["name"].to_s, prop.attributes["value"].to_s
            rules.push tmprule
          end
        end


        action = action_capabilities.include? prop.attributes["name"].to_s
        if action
          action_name = prop.attributes["name"].to_s
          action_value = prop.attributes["value"].to_s
          rules.each {|rule| rule.add_action action_name, action_value}
        end

      end
      rules.each {|rule| final_file.push rule}
      #puts rules.inspect
      #puts "------------------"
      #rules.clear

    end
    puts Psych.dump(final_file)
  end

end

opts = Trollop::options do
  opt :dir, "Base directory for the rules file", :default => "."
  opt :check, "Run a manual check of this file's rules", :type => :string
  opt :import, "Import from gmail's XML export file", :type => :string
end

v = Filter.new opts

v.import if opts[:import]
v.manual_heliotrope_run if opts[:check]
