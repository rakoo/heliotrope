# $Id$
# Copyright (C) 2005  Shugo Maeda <shugo@ruby-lang.org>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

require "set"
require "json"
require "leveldb"
require "lrucache"

module Heliotrope

  class MailStore

		MESSAGE_IMMUTABLE_STATE = Set.new %w(attachment signed encrypted draft)

		MESSAGE_MUTABLE_STATE_HASH = {
			"\\Starred"	=>	"starred",
			"\\Seen"	=>	nil,
			"\\Deleted"	=>	"deleted",
			nil	=>	"unread"
		}
	
		MESSAGE_STATE = Set.new(MESSAGE_MUTABLE_STATE_HASH.values) + MESSAGE_IMMUTABLE_STATE

		SPECIAL_MAILBOXES = MESSAGE_MUTABLE_STATE_HASH.merge( 
		{
			"\\Answered" => nil,
		 	"\\Draft" => "draft",
			"Sent"	=> "sent",
		 	"All Mail" => nil,
		 	"INBOX" => "inbox"
		})
		# misses \Answered \Seen (the latter is problematic)
		# this Hash relates IMAP keywords with their Heliotrope
		# counterparts

    def initialize(metaindex, zmbox)
      #@logger = @config[:logger]

      # When creating a mailbox, it doesn't exist as a label. We add it
      # to the fakemailboxes so that it can be selected by the client,
      # but it should be deleted afterwards (not done yet)
			@fakemailboxes = []

			#@current_mailbox = ""

      @metaindex = metaindex
      @zmbox = zmbox
      @cache = LRUCache.new :max_size => 100
    end

    def mailboxes
			labels = @metaindex.all_labels

			#Format to return:
			#[
			# ["label1", "FLAGS for label1"],
			# ["label2", "FLAGS for label2"],
			#]

			out = []
			labels.each do |label|
				out << [SPECIAL_MAILBOXES.key(label) || "\~" + label, ""]
			end

			@fakemailboxes.each do |m|
				out << m
			end

			out.uniq
    end

    def create_mailbox(name, query = nil)
			all_mailboxes = mailboxes
			validate_imap_format!(name)
			unless all_mailboxes.assoc(name).nil?
				raise MailboxExistError.new("#{name} already exists")
			end
			@fakemailboxes << [name, ""]
    end




    def delete_mailbox(name)
			validate_imap_format!(name)
			raise MailboxError.new("Can't delete a special mailbox") if (SPECIAL_MAILBOXES.key?(name) or MESSAGE_IMMUTABLE_STATE.include?(name))

			all_mailboxes = mailboxes
			if all_mailboxes.assoc(name).nil?
				raise MailboxExistError.new("#{name} doesn't exist")
			end

			#TODO : cannot delete if there is the \Noselect label or if there are
			#sublabels
			hlabel = format_label_from_imap_to_heliotrope name
			
			threadinfos = search_in_heliotrope name
			threadinfos.each do |m|
				new_labels = m["labels"]
			  new_labels -= [hlabel] 
				puts "old labels : #{m["labels"]}"
				puts "new labels : #{new_labels} "
				@heliotropeclient.set_labels!  m["thread_id"], new_labels
			end

			# prune when all is done
			@heliotropeclient.prune_labels!
    end




    def rename_mailbox(name, new_name)
			# TODO if a label has sublabels, there is a special treatment

		 	if (SPECIAL_MAILBOXES.key?(name) or SPECIAL_MAILBOXES.key?(new_name) or MESSAGE_IMMUTABLE_STATE.subset?(Set.new [name, new_name]))
				raise MailboxError.new("Can't rename a special mailbox")
			end

			all_mailboxes = mailboxes
			if all_mailboxes.assoc(name).nil? # mailbox "name" doesn't exist
				raise NoMailboxError.new("Can't rename #{name} to #{new_name} : #{name} doesn't exist")
			end
			unless all_mailboxes.assoc(new_name).nil? # mailbox "new_name" already exists
				raise MailboxExistError.new("Can't rename #{name} to #{new_name} : #{new_name} already exists")
			end

			puts "rename label #{name} to #{new_name}"

			hname = format_label_from_imap_to_heliotrope name
			hnew_name = format_label_from_imap_to_heliotrope new_name

			thread_infos = []
			count = @heliotropeclient.count name
			threadinfos = search_in_heliotrope name
			threadinfos.each do |m|
				new_labels = m["labels"]
				new_labels += [hnew_name]
			  new_labels -= [hname] unless hname == "inbox" # if the old label is inbox, duplicate instead of moving : RFC
				@heliotropeclient.set_labels!  m["thread_id"], new_labels.flatten
			end

			# prune labels
			@heliotropeclient.prune_labels!
    end

    def get_mailbox_status(mailbox_name, read_only = false)

			validate_imap_format!(mailbox_name)

			# http://www.faqs.org/rfcs/rfc3501.html : mailbox status has these
			# fields : 
			# - MESSAGES : counts the number of messages in this mailbox
			# - RECENT : number of messages with the \Recent FLAG
			# - UIDNEXT : uid that will be assigned to the next mail to be stored
			# - UIDVALIDITY : int. If it has changed between 2 sessions, it means
			# the mailbox isn't valid, and the client needs to redownload messages
			# from the beginning
			# - UNSEEN : number of messages without the \Seen FLAG

      {
        :recent => 0,
        :uidnext => @metaindex.size + 1,
        :count => mailbox_name == "All Mail" ? @metaindex.size : messages_count(mailbox_name),
        :unseen => messages_count(mailbox_name, true),
        :uidvalidity => 1 #FIXME
      }
    end

    def get_mailbox(name)
			validate_imap_format!(name)

      # [["label", "FLAGS"]] becomes {"label" => "FLAGS"}
      hashed_mailboxes = Hash[mailboxes]

			if hashed_mailboxes[name].nil? # mailbox doesn't exist
				raise MailboxExistError.new("Can't select #{name} : this mailbox doesn't exist")
			elsif /\\Noselect/.match(hashed_mailboxes[name]) # mailbox isn't selectable
				raise NotSelectableMailboxError.new("Can't select #{name} : not a selectable mailbox")
			end

      # simply return mailbox's name because there is no "Mailbox"
      # object
      name
    end

    def delete_mail(mailbox, seqno)
			puts "; trying to delete mail seq #{seqno} in #{mailbox.name}"
			ret = mailbox.delete_seqno(seqno)
			ret
    end

		def copy_mails_to_mailbox(mails, mailbox)
			out = []

			mailbox_name = mailbox.name
			validate_imap_format!(mailbox_name)
			all_mailboxes = mailboxes
			raise MailboxExistError.new("[TRYCREATE] #{mailbox_name} doesn't exist") if
		 		all_mailboxes.assoc(mailbox_name).nil?
			raise NotSelectableMailboxError.new("#{mailbox_name} is not selectable") if
				all_mailboxes.assoc(mailbox_name).include?("\\Noselect")

			puts "copy mails to #{mailbox_name}"

			dst_mailbox = get_mailbox(mailbox_name)

			hlabel = format_label_from_imap_to_heliotrope mailbox_name
			mails.each do |m|
				response = dst_mailbox.append_mail(m)
				out << response[:uid]
			end

			out
		end


		def append_mail(message, mailbox_name, flags)
			all_mailboxes = mailboxes
			validate_imap_format! mailbox_name
			raise MailboxExistError.new("[TRYCREATE] #{mailbox_name} doesn't exist") if
		 		all_mailboxes.assoc(mailbox_name).nil?

			get_mailbox(mailbox_name).append_mail_to_mailbox message, flags
		end

    def get_next_mailbox_id
      return @mailbox_id_seq.next
    end

		def fetch_labels_and_flags_for_message_id(message_id)
			out = []
			minfos = 	@heliotropeclient.messageinfos(message_id)
			out << minfos["labels"] << minfos["state"]
			out = out.flatten.map do |l|
				if SPECIAL_MAILBOXES.value?(l)
					SPECIAL_MAILBOXES.key(l)
				else
					"~" + l
				end
			end

			out << "\\Seen" unless out.include?("~unread")
			out.compact.uniq
		end

		def set_labels_and_flags_for_message_id(message_id, flags)
			messageinfos = @heliotropeclient.messageinfos(message_id)
			thread_id = messageinfos["thread_id"]
			message_id = messageinfos["message_id"]

			flags.map! do |f|
				format_label_from_imap_to_heliotrope f
			end.compact!

			# separate flags between labels and state
			state = flags.select{|f| MESSAGE_STATE.member?(f)}
			labels = flags - state

			@heliotropeclient.set_labels! thread_id, labels
			@heliotropeclient.set_state! message_id, state

			@heliotropeclient.messageinfos message_id
		end

		def fetch_date_for_uid(uid)
			Time.at(@heliotropeclient.messageinfos(uid).fetch("date"))
		end

		def next_uid key; @uid_store.member?(key) ?  Marshal.load(@uid_store[key]).to_i : 1 end
		def increment_next_uid key, value; @uid_store[key] = Marshal.dump(value.to_i) end
		def get_uids key; @uid_store.member?(key) ? Marshal.load(@uid_store[key]).to_hash : {} end
		def write_uids key, value; @uid_store[key] = Marshal.dump(value.to_hash) end

    def fetch_mails_seq(mailbox_name, sequence_set)

      # sequence_set can contain any mix of arrays, ranges and integer.
      # Transform it to something usable
			seq_ids = sequence_set.map do |atom|
				if atom.respond_to?(:last) && atom.respond_to?(:first)
					# transform Range to Array
					begin
						if atom.last == -1 # fetch all
							atom.first .. messages_count(mailbox_name)
						else
							atom
						end
					end.to_a
        elsif atom.respond_to?(:to_a)
					atom.to_a
        elsif atom.integer?
          [atom]
        else
          raise "unknown atom : #{atom}"
				end
			end.flatten

      message_ids = seq_ids.map {|id| build_sequence_set(mailbox_name)[id]}

      fetch_internal(message_ids).map do |message|
        message.merge({
          :flags => (message[:state] + message[:labels]).map do |flag|
            SPECIAL_MAILBOXES.key(flag) || "\~" + flag
          end,
          :seqno => message_ids.index(message[:message_id])
        })
      end
    end

		private

    # returns mails as hashes
    def fetch_internal message_ids
      message_ids.map do |id|
        @metaindex.load_messageinfo(id.to_i) or raise MailboxError, "can't find message #{id.inspect}"
      end
    end

    # Build an array that lists message_ids in this mailbox in ascending
    # order like ["shift", 47, 52, 312]
    # "shift" is used in order to be able to use sequential numbers,
    # which start at 1
    def build_sequence_set mailbox_name
      seq = @cache[["sequence_set", mailbox_name]]
      return seq unless seq.nil?

      mails = search_messages(mailbox_name).map{|mail| mail[:message_id]}.sort.unshift "shift"
      @cache[["sequence_set", mailbox_name]] ||= mails
    end

		def messages_count mailbox_name, with_unread=false
      search_label = with_unread ? "~unread " + mailbox_name : mailbox_name
      search_messages(search_label).size
		end

    # search for a name and return messages associated to this query
    # query can be a label (~label, with the tilde), or a complex query.
    def search_messages query
      query = Heliotrope::Query.new "body", query
      @metaindex.set_query query
      #@metaindex.get_some_results(@metaindex.size).map do |thread|
        ## discard the level, which is the second elem of the
        ## load_thread_messageinfos. After that, we have a 1-elem array,
        ## so we take it
        #@metaindex.load_thread_messageinfos(thread[:thread_id]).map(&:first)[0]
      #end
      @metaindex.get_some_results @metaindex.size, :messages
    end


		def validate_imap_format!(label)
			unless /^\~/.match(label) or SPECIAL_MAILBOXES.key?(label)
				raise NoMailboxError.new("#{label} doesn't exist or is invalid")
			end
		end


		def format_label_from_imap_to_heliotrope ilabel
			if SPECIAL_MAILBOXES.key?(ilabel)
				return SPECIAL_MAILBOXES.fetch(ilabel)
			elsif /^\\/.match(ilabel)
				raise NoMailboxError.new("#{ilabel} is not a valid name!")
			else
				return ilabel.gsub(/^\~/,"") # remove ~ from the beginning of the label
			end
		end

    def extract_query(mailbox_name)
      s = mailbox_name.slice(/\Aqueries\/(.*)/u, 1)
      return nil if s.nil?
      query = Net::IMAP.decode_utf7(s)
      begin
        open_backend do |backend|
          result = backend.try_query(query)
        end
        return query
      rescue
        raise InvalidQueryError.new("invalid query")
      end
    end

    def get_next_uid
      return @uid_seq.next
    end

    def extract_body(mail)
      if mail.multipart?
        return mail.body.collect { |part|
          extract_body(part)
        }.join("\n")
      else
        case mail.header.content_type("text/plain")
        when "text/plain"
          return decode_body(mail)
        when "text/html", "text/xml"
          return decode_body(mail).gsub(/<.*?>/um, "")
        else
          return ""
        end
      end
    end

    def decode_body(mail)
      charset = mail.header.params("content-type", {})["charset"] ||
        @default_charset
      return to_utf8(mail.decode, charset)
    end

    def to_utf8(src, charset)
      begin
        return Iconv.conv("utf-8", charset, src)
      rescue
        return NKF.nkf("-m0 -w", src)
      end
    end

    def guess_list_name(fname, mail)
      ret = nil

      if mail.header.include?(fname)
        value = mail.header[fname]
        ret = value
        case fname
        when 'list-id'
          ret = $1 if /<([^<>]+)>/ =~ value
        when 'x-ml-address'
          ret = $& if /\b[^<>@\s]+@[^<>@\s]+\b/ =~ value
        when 'x-mailing-list', 'mailing-list'
          ret = $1 if /<([^<>@]+@[^<>@]+)>/ =~ value
        when 'x-ml-name'
          # noop
        when 'sender'
          if /\bowner-([^<>@\s]+@[^<>@\s]+)\b/ =~ value
            ret = $1
          else
            ret = nil
          end
        when 'x-loop'
          ret = $& if /\b[^<>@\s]+@[^<>@\s]+\b/ =~ value
        end
      end

      ret
    end

    def extract_properties(mail, properties, override)
      for field in ["subject", "from", "to", "cc", "bcc"]
        properties[field] = get_header_field(mail, field)
      end
      begin
        properties["date"] = DateTime.parse(mail.header["date"].to_s).to_time.getlocal.strftime("%Y-%m-%dT%H:%M:%S")
      rescue Exception => e
        @logger.log_exception(e, "failed to parse date - `#{mail.header["date"].to_s}'", Logger::WARN)
      end
      s = nil
      @ml_header_fields.each do |field_name|
        s = guess_list_name(field_name, mail)
        break if s
      end
      properties["x-ml-name"] = decode_encoded_word(s.to_s)
      properties["x-mail-count"] = mail.header["x-mail-count"].to_s.to_i
      return properties.merge(override)
    end

    def get_header_field(mail, field)
      return decode_encoded_word(mail.header[field].to_s)
    end

    def decode_encoded_word(s)
      return NKF.nkf("-w", s)
    end
  end
end
