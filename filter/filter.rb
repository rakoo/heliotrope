require 'heliotrope-client'
require 'trollop'
require 'psych'

class Filter
  SEARCHABLE_FIELDS = Set.new %w(from to subject date body)

  def initialize opts
    @hc = HeliotropeClient.new "http://localhost:8042"
    @conf = Psych.load_file File.join(opts.dir, "filtering_rules.yml")
  end

  def manual_heliotrope_run
    puts "---------------"
    @conf.each do |conf|

      # FROM HELIOTROPE
      # we use a query which is of the form
      #   from:bob@test.com to:bob@test2.org subject:yeah


      # step 1 : get the matching threads
      query = ""

      matches = conf["Matches"]
      SEARCHABLE_FIELDS.each do |field|
        unless matches[field].nil? || matches[field].empty?
          if matches[field].respond_to? 'each'
            matches[field].each {|param| query << "#{field}:#{param} " }
          elsif matches[field].respond_to? '+'
            query << "#{field}:#{matches[field]}"
          end
        end
      end

      expected_labels = Set.new(conf["Do this"]["labels"])
      expected_state = Set.new(conf["Do this"]["state"])
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
          # we have to verify state for each message -- maybe later
        end
      end
      puts "------------------"
    end

  end

end

opts = Trollop::options do
  opt :dir, "Base directory for all index files", :default => "."
end

v = Filter.new opts
v.manual_heliotrope_run
