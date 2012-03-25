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
  end

  def manual_heliotrope_run
    puts "---------------"
    @conf.each do |conf|

      # FROM HELIOTROPE side
      # we use a query which is of the form
      #   from:bob@test.com to:bob@test2.org subject:yeah

      # step 1 : get the matching threads
      if conf.keys.size > 1 || conf.values.size > 1
        raise "Rule is malformed : #{conf}" 
      end
      query = conf.keys[0].dup

      expected_labels =  return_set_from_conf conf.values[0]["labels"]
      expected_state = return_set_from_conf conf.values[0]["state"]

      # I don't like side-effects functions
      query_1 = add_set_to_query query, expected_labels
      new_query = add_set_to_query query_1, expected_state
          
      puts "looking for '#{new_query}'"
      results = @hc.search new_query

      # step 2 : verify the labels and the state

      results.each do |r|

        treat_labels_or_state Set.new(r["labels"]), expected_labels, r["thread_id"]
        treat_labels_or_state Set.new(r["state"]), expected_state, r["thread_id"]

      end
      puts "------------------"
    end
  end

  def import filename
    require 'nokogiri'

    # Map Gmail's matching capabilities to heliotrope's
    # https://developers.google.com/google-apps/email-settings/#manage_filters
    matching_capabilities = Set.new %w(from to subject hasTheWord doesNotHaveTheWord hasAttachment)

    action_capabilities = Set.new %w(shouldArchive shouldMarkAsRead shouldStar label forwardTo shouldTrash shouldNeverSpam)

    final_file = []

    gmail_filters = Nokogiri::Slop(File.open(filename))
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

  private

  def add_set_to_query string, set
    ret = string.dup.sub(/$/,' ')
      set.each do |l|
        case l
        when /^-/
          ret << "~#{l.sub(/^-/,'')} "
        when /^(\+|\w)/
          ret << "-~#{l.sub(/^\+/,'')} "
        else
          raise "#{l} is malformed"
        end
      end
   return ret.strip
  end

  def return_set_from_conf string
    Set.new(
      case string
      when String
        [string]
      when Array
        string
      when nil
        nil
      else
        raise "state are not properly formed for this rule : #{string}"
      end
    )
  end

  def treat_labels_or_state actual_set, expected_set, thread_id
    # classify labels. should have labels that look like
    #   +label
    #   label
    # but should not have label that look like -label
    #
    # It's exactly the same thing for state. If you don't understand
    # what is below at first read, replace 'set' with 'labels' or
    # 'state'
    superset = expected_set.classify {|l| l.start_with? '-'}
    should_have_set = Set.new(superset[false]).collect! {|el| el.sub(/^\+/,'')}
    should_not_have_set = Set.new(superset[true]).collect! {|el| el.sub(/^\-/,'')}

    is_correct_set = actual_set.superset?(should_have_set) &&
      (actual_set & (should_not_have_set)).empty?

    unless is_correct_set
      puts "-- pb on thread #{thread_id}: #{actual_set.to_a} should match #{expected_set.to_a}"
      puts "-- putting #{(actual_set + should_have_set -  should_not_have_set).to_a}"
      # @hc.set_labels! r["thread_id"], (actual_set + should_have_set -
      # should_not_have_set).to_a
    end
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
