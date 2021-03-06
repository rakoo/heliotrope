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

module Heliotrope

  class Command
    attr_reader :session
    attr_accessor :tag, :name

    def initialize
      @session = nil
      @tag = nil
      @name = nil
    end

    def session=(session)
      @session = session
      @mail_store = session.mail_store
    end

    def send_tagged_ok(code = nil)
      if code.nil?
        @session.send_tagged_ok(@tag, "%s completed", @name)
      else
        @session.send_tagged_ok(@tag, "[%s] %s completed", code, @name)
      end
    end
  end

  class NullCommand < Command
    def exec
      @session.send_queued_responses
      @session.send_bad("Null command")
    end
  end

  class MissingCommand < Command
    def exec
      @session.send_queued_responses
      @session.send_tagged_bad(@tag, "Missing command")
    end
  end

  class UnrecognizedCommand < Command
    def exec
      msg = "Command unrecognized"
      if @session.state == IMAP_NON_AUTHENTICATED_STATE
        msg.concat("/login please")
      end
      @session.send_queued_responses
      @session.send_tagged_bad(@tag, msg)
    end
  end

  class CapabilityCommand < Command
    def exec
      capa = "CAPABILITY IMAP4REV1 IDLE"
      @session.send_data(capa)
      send_tagged_ok
    end
  end

  class NoopCommand < Command
    def exec
      @session.send_queued_responses
      send_tagged_ok
    end
  end

  class LogoutCommand < Command
    def exec
      @mail_store.logout_session(self.object_id)
      @session.send_data("BYE IMAP server terminating connection")
      send_tagged_ok
      @session.logout
    end
  end

  class AuthenticatePlainCommand < Command
    def exec
      line = @session.recv_line
    end
  end

  class LoginCommand < Command
    def initialize(userid, password)
      @userid = userid
      @password = password
    end

    def exec
      # don't use secure session for now
			if @userid == @session.config[:user] && @password == @session.config[:password]
        @session.login
        send_tagged_ok
      else
        @session.send_tagged_no(@tag, "LOGIN failed")
      end
    end
  end

  class MailboxCheckCommand < Command
    def initialize(mailbox_name)
      @mailbox_name = mailbox_name
    end

    def exec
      begin

        mailbox_status = @mail_store.get_mailbox_status @mailbox_name

        @session.send_data("%d EXISTS", mailbox_status[:messages])
        @session.send_data("%d RECENT", mailbox_status[:recent])
        @session.send_ok("[UIDVALIDITY %d] UIDs valid", mailbox_status[:uidvalidity])
        @session.send_ok("[UIDNEXT %d] Predicted next UID", mailbox_status[:uidnext])
        @session.send_data("FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)")
        @session.send_ok("[PERMANENTFLAGS (\\Answered \\Flagged \\Draft \\Seen \\Deleted \\*)] Limited")
        @session.send_queued_responses
        send_tagged_response
      rescue MailboxError => e
        @session.send_tagged_no(@tag, "%s", e)
      end
    end

    private

    def send_tagged_response
      raise SubclassResponsibilityError.new
    end
  end

  class SelectCommand < MailboxCheckCommand
    private

    def send_tagged_response
      @session.select(@mailbox_name)
      @session.send_queued_responses
      send_tagged_ok("READ-WRITE")
    end
  end

  class ExamineCommand < MailboxCheckCommand
    private

    def send_tagged_response
      @session.examine(@mailbox_name)
      @session.send_queued_responses
      send_tagged_ok("READ-ONLY")
    end
  end

  class CreateCommand < Command
    def initialize(mailbox_name)
      @mailbox_name = mailbox_name
    end

    def exec
      begin
        @mail_store.create_mailbox(@mailbox_name, self.object_id)
        @session.send_queued_responses
        send_tagged_ok
      rescue InvalidQueryError
        @session.send_tagged_no(@tag, "invalid query")
      end
    end
  end

  class DeleteCommand < Command
    def initialize(mailbox_name)
      @mailbox_name = mailbox_name
    end

    def exec
      if /\A(INBOX|ml|queries)\z/ni.match(@mailbox_name)
        @session.send_tagged_no(@tag, "can't delete %s", @mailbox_name)
        return
      end
      @mail_store.delete_mailbox(@mailbox_name)
      @session.send_queued_responses
      send_tagged_ok
    end
  end

  class RenameCommand < Command
    def initialize(mailbox_name, new_mailbox_name)
      @mailbox_name = mailbox_name
      @new_mailbox_name = new_mailbox_name
    end

    def exec
      if /\A(INBOX|ml|queries)\z/ni.match(@mailbox_name)
        @session.send_tagged_no(@tag, "can't rename %s", @mailbox_name)
        return
      end
      begin
        @mail_store.rename_mailbox(@mailbox_name, @new_mailbox_name)
        @session.send_queued_responses
        send_tagged_ok
      rescue Exception => e
        case e
        when InvalidQueryError
          msg = "invalid query"
        when MailboxExistError
          msg = e.message || "mailbox already exists"
        when NoMailboxError
          msg = e.message || "mailbox does not exist"
        else
          raise
        end
        @session.send_queued_responses
        @session.send_tagged_no(@tag, msg)
      end
    end
  end

  class ListCommand < Command
    include DataFormat

    def initialize(reference_name, mailbox_name)
      @reference_name = reference_name
      @mailbox_name = mailbox_name
    end

    def exec
      unless @reference_name.empty?
        @session.send_tagged_no(@tag, "%s failed", @name)
        return
      end
      if @mailbox_name.empty?
        @session.send_data("%s (\\Noselect) \"/\" \"\"", @name)
        send_tagged_ok
        return
      end
      pat = @mailbox_name.gsub(/\*|%|[^*%]+/n) do |s|
        case s
        when "*"
          ".*"
        when "%"
          "[^/]*"
        else
          Regexp.quote(s)
        end
      end
      re = Regexp.new("\\A" + pat + "\\z", nil, "n")


      # The result should look like
      # [
      #   [folder1, FLAGS for folder1],
      #   [folder2, FLAGS for folder2]
      # ]
      @mail_store.mailboxes.sort_by { |i| i[0] }.each do |name, flags|
        @session.send_data("%s (%s) \"/\" %s",
                           @name, flags, quoted(name))
      end
      @session.send_queued_responses
      send_tagged_ok
    end
  end

  class StatusCommand < Command
    include DataFormat

    def initialize(mailbox_name, atts)
      @mailbox_name = mailbox_name
      @atts = atts
    end

    def exec
      status = @mail_store.get_mailbox_status(@mailbox_name)
      s = @atts.collect do |att|
        format("%s %d", att, status[att.downcase.to_sym])
      end.join(" ")
			puts "; atts in command : #{s}"
      @session.send_data("STATUS %s (%s)", quoted(@mailbox_name), s)
      @session.send_queued_responses
      send_tagged_ok
    end
  end

  class AppendCommand < Command
    def initialize(mailbox_name, flags, datetime, message)
      @mailbox_name = mailbox_name
      @flags = flags
      @datetime = datetime
      @message = message
    end

    # only with UIDPLUS. Maybe one day.
    #def send_tagged_ok_append
			#uidvalidity = @mail_store.get_mailbox_status(@mailbox_name)[:uidvalidity]
			#@session.send_tagged_ok(@tag, "[APPENDUID %s %s]", uidvalidity, @response[:uid])
    #end

    def exec
      @mail_store.append_mail(@message, @mailbox_name, @flags)
      count = @mail_store.get_mailbox_status(@mailbox_name)[:messages]
      @session.push_queued_response(@mailbox_name, "#{count} EXISTS")
      @session.send_queued_responses
      #send_tagged_ok_append
      send_tagged_ok
    end
  end

  class IdleCommand < Command
    def exec
      @session.send_continue_req("Waiting for DONE")
      th = Thread.start do
        begin
          begin
            @session.idle = true
            @session.sync
            #@mail_store.mailbox_db.transaction do
            #@mail_store.plugins.fire_event(:on_idle)
            #if @session.all_session_on_idle?
            #@mail_store.plugins.fire_event(:on_idle_all)
            #end
            #end
          ensure
            @session.idle = false
          end
        rescue IdleTerminated
          # OK
        end
      end
      send_queued_responses_th = Thread.start do
        begin
          loop do
            sleep 1
            @session.send_queued_responses
          end
        rescue IdleTerminated
          # OK
        end
      end
      until @session.recv_line == "DONE"
        @session.send_bad("Waiting for DONE") # XXX: OK?
      end
      th.raise(IdleTerminated) if th.alive?
      th.join
      send_queued_responses_th.raise(IdleTerminated) if send_queued_responses_th.alive?
      send_queued_responses_th.join
      @session.send_queued_responses
      send_tagged_ok
    end
  end

  class CloseCommand < Command
    def exec
      mailbox = @session.get_current_mailbox
      uids = mailbox.uid_search(mailbox.query&FlagQuery.new("\\Deleted"))
      deleted_mails = mailbox.uid_fetch(uids).reverse
      # no
      #@mail_store.delete_mails(deleted_mails)
      @session.send_queued_responses
      @session.close_mailbox
      send_tagged_ok
    end
  end

  class ExpungeCommand < Command
    def exec
      @mailbox = @session.get_current_mailbox

      @mail_store.expunge(@mailbox).each do |ret|
        @session.send_data("%d EXPUNGE", ret)
      end
      @session.send_queued_responses
      send_tagged_ok
    end
  end

  class AbstractSearchCommand < Command
    def initialize(query)
      @query = query
    end

    def exec
      mailbox = @session.get_current_mailbox
      uids = @mail_store.uid_search(@query)
      result = create_result(mailbox, uids)
      if result.empty?
        @session.send_data("SEARCH")
      else
        @session.send_data("SEARCH %s", result.join(" "))
      end
      @session.send_queued_responses
      send_tagged_ok
    end

    private

    def create_result(uids)
      raise SubclassResponsibilityError.new
    end
  end

  class SearchCommand < AbstractSearchCommand
    private

    def create_result(mailbox, uids)
      uids.map{|uid| @mail_store.get_seqno(mailbox, uid)}
    end
  end

  class UidSearchCommand < AbstractSearchCommand
    private

    def create_result(mailbox, uids)
      return uids
    end
  end

  class AbstractFetchCommand < Command
    def initialize(sequence_set, atts)
      @sequence_set = sequence_set
      @atts = atts
    end

    def exec
      mailbox = @session.get_current_mailbox
      mails = fetch(mailbox)
      mails.each do |mail|
        data = @atts.collect do |att|
          att.fetch(mail)
        end.join(" ")
        send_fetch_response(mail, data)
      end
      @session.send_queued_responses(/\A\d+ EXPUNGE\z/)
      send_tagged_ok
    end

    private

    def fetch(mailbox)
      raise SubclassResponsibilityError.new
    end

    def send_fetch_response(mail, flags)
      raise SubclassResponsibilityError.new
    end
  end

  class FetchCommand < AbstractFetchCommand
    private

    def fetch(mailbox)
      @mail_store.fetch_mails(mailbox, @sequence_set, :seq)
    end

    def send_fetch_response(mail, data)
      @session.send_data("%d FETCH (%s)", mail.seqno_in(@session.get_current_mailbox), data)
    end
  end

  class UidFetchCommand < FetchCommand
    def initialize(sequence_set, atts)
      super(sequence_set, atts)
      unless @atts[0].kind_of?(UidFetchAtt)
        @atts.unshift(UidFetchAtt.new)
      end
    end

    private

    def fetch(mailbox)
      @mail_store.fetch_mails(mailbox, @sequence_set, :uid)
    end

  end

  class EnvelopeFetchAtt
    def fetch(mail)
      format("ENVELOPE %s", mail.envelope)
    end
  end

  class FlagsFetchAtt
    def fetch(mail)
      format("FLAGS (%s)", mail.flags.sort.join(" "))
    end
  end

  class InternalDateFetchAtt
    include DataFormat

    def fetch(mail)
      indate = mail_store.fetch_date(mail[:message_id]).strftime("%d-%b-%Y %H:%M:%S %z")
      format("INTERNALDATE %s", quoted(indate))
    end
  end

  class RFC822FetchAtt
    include DataFormat

    def fetch(mail)
      format("RFC822 %s", literal(mail.to_s))
    end
  end

  class RFC822HeaderFetchAtt
    include DataFormat

    def fetch(mail)
      format("RFC822.HEADER %s", literal(mail.get_header.fields.map do |f|
				"#{f.name}: #{f.value}"
			end.join("\r\n")))
    end
  end

  class RFC822SizeFetchAtt
    def fetch(mail)
      format("RFC822.SIZE %s", mail.size)
    end
  end

  class RFC822TextFetchAtt
    def fetch(mail)
			s = mail.body
			format("RFC822.TEXT {%d}\r\n%s", s.size, s)
    end
  end

  class BodyFetchAtt
    def fetch(mail)
      format("BODY %s", mail.body_structure(false))
    end
  end

  class BodyStructureFetchAtt
    def fetch(mail)
      format("BODYSTRUCTURE %s", mail.body_structure(true))
    end
  end

  class UidFetchAtt
    def fetch(mail)
      format("UID %s", mail.uid)
    end
  end

  class BodySectionFetchAtt
    include DataFormat

    def initialize(section, partial, peek)
      @section = section
      @partial = partial
      @peek = peek
    end

    def fetch(mail)
      if @section.nil? || @section.text.nil?
        if @section.nil?
          #part = nil
          result = format_data(mail.rawbody)
        else
          #part = @section.part
          raise NotImplementedError, "trying to fetch #{@section.text}, not supported"
        end
        #result = format_data(mail.mime_body(part))
        unless @peek
          flags = mail.flags.join(" ")
          flags += "\\Seen" unless /\\Seen\b/ni.match(flags)
          mail.flags = flags
          result += format(" FLAGS (%s)", flags.join(" "))
        end
        return result
      end
      case @section.text
      when "MIME"
        #s = mail.mime_header(@section.part)
        s = mail_store.mime_header(@section.part, mail[:message_id])
        return format_data(s)
      when "HEADER"
        #s = mail.get_header(@section.part)
        return format_data(s)
      when "HEADER.FIELDS"
        #s = mail.get_header_fields(@section.header_list, @section.part)
        s = mail_store.fetch_header_fields(@section.header_list, @section.part, mail[:message_id])
        return format_data(s)
			when "TEXT"
        #s = mail.body
        s = mail_store.fetch_body(mail[:message_id])
				return format_data(s)
      else
        @session.send_tagged_no @tag, "unrecognized section : #{@section.text}"
      end
    end

    private
    
    def format_data(data)
      if @section.nil?
        section = ""
      else
        if @section.text.nil?
          section = @section.part
        else
          if @section.part.nil?
            section = @section.text
          else
            section = @section.part + "." + @section.text
          end
          if @section.text == "HEADER.FIELDS"
            section += " (" + @section.header_list.collect { |i|
              quoted(i)
            }.join(" ") + ")"
          end
        end
      end
      if @partial
        s = data[@partial.offset, @partial.size]
        return format("BODY[%s]<%d> %s", section, @partial.offset, literal(s))
      else
        return format("BODY[%s] %s", section, literal(data))
      end
    end
  end

  Section = Struct.new(:part, :text, :header_list)

  class AbstractStoreCommand < Command
    def initialize(sequence_set, att)
      @sequence_set = sequence_set
      @att = att
    end

    def exec
      mailbox = @session.get_current_mailbox
      mails = fetch(mailbox)
      mails.each do |mail|
        flags = @att.get_new_flags(mail)
        mail.flags = flags
        flags = mail.flags
        unless @att.silent?
          send_fetch_response(mail, flags)
        end
        queue_fetch_response(mail, flags)
      end
      @session.send_queued_responses(/\A\d+ EXPUNGE\z/)
      send_tagged_ok
    end

    private

    def fetch(mailbox)
      raise SubclassResponsibilityError.new
    end

    def send_fetch_response(mail, flags)
      raise SubclassResponsibilityError.new
    end
  end

  class StoreCommand < AbstractStoreCommand
    private

    def fetch(mailbox)
      @mailbox = mailbox
      @mail_store.fetch_mails(mailbox, @sequence_set, :seq)
    end

    def send_fetch_response(mail, flags)
      @session.send_data("%d FETCH (FLAGS (%s))", mail.seqno, flags.join(" "))
    end

    def queue_fetch_response(mail, flags)
      @session.push_queued_response(@session.current_mailbox, "#{mail.seqno} FETCH (FLAGS (#{flags.join(' ')}))")
    end
  end

  class UidStoreCommand < AbstractStoreCommand
    private

    def fetch(mailbox)
      @mailbox = mailbox
      @mail_store.fetch_mails(mailbox, @sequence_set, :uid)
    end

    def send_fetch_response(mail, flags)
      @session.send_data("%d FETCH (FLAGS (%s) UID %d)",
                         mail.seqno_in(@mailbox), flags.join(" "), mail.uid)
    end

    def queue_fetch_response(mail, flags)
      @session.push_queued_response(@session.current_mailbox, "#{mail.seqno_in(@mailbox)} FETCH (FLAGS (#{flags.join(' ')}) UID #{mail.uid})")
    end
  end

  class FlagsStoreAtt
    def initialize(flags, silent = false)
      @flags = flags
      @silent = silent
    end

    def silent?
      return @silent
    end

    def get_new_flags(mail)
      raise SubclassResponsibilityError.new
    end

  end

  class SetFlagsStoreAtt < FlagsStoreAtt
    def get_new_flags(mail)
			# IMAP clients will only set message state, not heliotrope labels.
			# We can separate them
			flags_labels_list = mail.flags - MailStore::MESSAGE_STATE.to_a
			flags_return = flags_labels_list + @flags

			# remove ~unread if flags_return contains \Seen
			flags_return -= ["\~unread"] if flags_return.include?('\\Seen')

      flags_return
    end
  end

  class AddFlagsStoreAtt < FlagsStoreAtt

		def initialize(flags, silent = false, session)
			super(flags, silent)
			@session = session
		end

    def get_new_flags(mail)
			flags_return = mail.flags
      flags_return |= @flags

			# remove ~unread if flags_return contains \Seen
			flags_return -= ["\~unread"] if @flags.include?('\\Seen')

      flags_return
    end
  end

  class RemoveFlagsStoreAtt < FlagsStoreAtt
    def get_new_flags(mail)
      flags_return = mail.flags
      flags_return -= @flags

			# add ~unread if we want to remove \Seen
			flags_return.push("~unread") if @flags.include?("\\Seen")
      return flags_return
    end
  end

  class AbstractCopyCommand < Command
    def initialize(sequence_set, mailbox_name)
      @sequence_set = sequence_set
      @mailbox_name = mailbox_name
    end

		def format_seqsets_to_output(sequence_sets)
			puts "seq : #{sequence_sets}"
			sequence_sets.flatten!

			out = ""

			sequence_sets.each do |s|
				out << "," unless sequence_sets.first == s
				case s
				when Range, Array
					out << s.first.to_s << ":" << s.last.to_s
				when String, Integer
					out << s.to_s
				else
					out << format_seqsets_to_output(s)
				end
			end

			out
		end
					

		## supersede to be conform to UIDPLUS
    #def send_tagged_ok_copy
			#mailbox_status = @mail_store.get_mailbox_status(@mailbox_name)
			#uidvalidity = mailbox_status.uidvalidity
			#seq_before = @sequence_set

			#sequence_set_before_copy = format_seqsets_to_output(seq_before)
			#sequence_set_after_copy = format_seqsets_to_output(@seq_after)
			#@session.send_tagged_ok(@tag, "[COPYUID #{uidvalidity} #{sequence_set_before_copy} #{sequence_set_after_copy}] Done")
    #end

    def exec
      mailbox = @session.get_current_mailbox
      mails = fetch_mails(mailbox, @sequence_set)

      @metaindex.load_messageinfo(message_id.to_i) or raise Sinatra::NotFound, "can't find message #{message_id.inspect}"
      @metaindex.update_message_state(message_id, state)

      dest_mailbox = @mail_store.get_mailbox(@mailbox_name)

      @seq_after = @mail_store.copy_mails_to_mailbox(mails, dest_mailbox)

      n = @mail_store.get_mailbox_status(@mailbox_name, true).messages
      @session.push_queued_response(@mailbox_name, "#{n} EXISTS")
      send_tagged_ok_copy
    end

    private
    
    def fetch_mails(mailbox, sequence_set)
      raise SubclassResponsibilityError.new
    end
  end

  class CopyCommand < AbstractCopyCommand
    private

    def fetch_mails(mailbox, sequence_set)
      return mailbox.fetch(sequence_set)
    end
  end

  class UidCopyCommand < AbstractCopyCommand
    private

    def fetch_mails(mailbox, sequence_set)
      return mailbox.uid_fetch(sequence_set)
    end
  end

  class CommandParser
    def initialize(session, config)
      @session = session
      @config = config
      @str = nil
      @pos = nil
      @lex_state = nil
      @token = nil
    end

    def parse(str)
      @str = str
      @pos = 0
      @lex_state = EXPR_BEG
      @token = nil
      return command
    end

    private

    EXPR_BEG          = :EXPR_BEG
    EXPR_DATA         = :EXPR_DATA
    EXPR_TEXT         = :EXPR_TEXT
    EXPR_RTEXT        = :EXPR_RTEXT
    EXPR_CTEXT        = :EXPR_CTEXT

    T_SPACE   = :SPACE
    T_NIL     = :NIL
    T_NUMBER  = :NUMBER
    T_ATOM    = :ATOM
    T_QUOTED  = :QUOTED
    T_LPAR    = :LPAR
    T_RPAR    = :RPAR
    T_BSLASH  = :BSLASH
    T_STAR    = :STAR
    T_LBRA    = :LBRA
    T_RBRA    = :RBRA
    T_LITERAL = :LITERAL
    T_PLUS    = :PLUS
    T_PERCENT = :PERCENT
    T_CRLF    = :CRLF
    T_EOF     = :EOF
    T_TEXT    = :TEXT

    BEG_REGEXP = /\G(?:\
(?# 1:  SPACE   )( )|\
(?# 2:  NIL     )(NIL)(?=[\x80-\xff(){ \x00-\x1f\x7f%*"\\\[\]+])|\
(?# 3:  NUMBER  )(\d+)(?=[\x80-\xff(){ \x00-\x1f\x7f%*"\\\[\]+])|\
(?# 4:  ATOM    )([^\x80-\xff(){ \x00-\x1f\x7f%*"\\\[\]+]+)|\
(?# 5:  QUOTED  )"((?:[^\x00\r\n"\\]|\\["\\])*)"|\
(?# 6:  LPAR    )(\()|\
(?# 7:  RPAR    )(\))|\
(?# 8:  BSLASH  )(\\)|\
(?# 9:  STAR    )(\*)|\
(?# 10: LBRA    )(\[)|\
(?# 11: RBRA    )(\])|\
(?# 12: LITERAL )\{(\d+)\}\r\n|\
(?# 13: PLUS    )(\+)|\
(?# 14: PERCENT )(%)|\
(?# 15: CRLF    )(\r\n)|\
(?# 16: EOF     )(\z))/ni

    DATA_REGEXP = /\G(?:\
(?# 1:  SPACE   )( )|\
(?# 2:  NIL     )(NIL)|\
(?# 3:  NUMBER  )(\d+)|\
(?# 4:  QUOTED  )"((?:[^\x00\r\n"\\]|\\["\\])*)"|\
(?# 5:  LITERAL )\{(\d+)\}\r\n|\
(?# 6:  LPAR    )(\()|\
(?# 7:  RPAR    )(\)))/ni

    TEXT_REGEXP = /\G(?:\
(?# 1:  TEXT    )([^\x00\r\n]*))/ni

    RTEXT_REGEXP = /\G(?:\
(?# 1:  LBRA    )(\[)|\
(?# 2:  TEXT    )([^\x00\r\n]*))/ni

    CTEXT_REGEXP = /\G(?:\
(?# 1:  TEXT    )([^\x00\r\n\]]*))/ni

    Token = Struct.new(:symbol, :value)

    UNIVERSAL_COMMANDS = [
      "CAPABILITY",
      "STARTTLS",
      "NOOP",
      "LOGOUT"
    ]
    NON_AUTHENTICATED_STATE_COMMANDS = UNIVERSAL_COMMANDS + [
      "AUTHENTICATE",
      "LOGIN"
    ]
    AUTHENTICATED_STATE_COMMANDS = UNIVERSAL_COMMANDS + [
      "SELECT",
      "EXAMINE",
      "CREATE",
      "DELETE",
      "RENAME",
      "SUBSCRIBE",
      "UNSUBSCRIBE",
      "LIST",
      "LSUB",
      "STATUS",
      "APPEND",
      "IDLE"
    ]
    SELECTED_STATE_COMMANDS = AUTHENTICATED_STATE_COMMANDS + [
      "CHECK",
      "CLOSE",
      "EXPUNGE",
      "SEARCH",
      "UID SEARCH",
      "FETCH",
      "UID FETCH",
      "STORE",
      "UID STORE",
      "COPY",
      "UID COPY"
    ]
    LOGOUT_STATE_COMMANDS = []
    COMMANDS = {
      IMAP_NON_AUTHENTICATED_STATE => NON_AUTHENTICATED_STATE_COMMANDS,
      IMAP_AUTHENTICATED_STATE => AUTHENTICATED_STATE_COMMANDS,
      IMAP_SELECTED_STATE => SELECTED_STATE_COMMANDS,
      IMAP_LOGOUT_STATE => LOGOUT_STATE_COMMANDS
    }

    def command
      result = NullCommand.new
      token = lookahead
      if token.symbol == T_CRLF || token.symbol == T_EOF
        result = NullCommand.new
      else
        tag = atom
        token = lookahead
        if token.symbol == T_CRLF || token.symbol == T_EOF
          result = MissingCommand.new
        else
          match(T_SPACE)
          name = atom.upcase
          if name == "UID"
            match(T_SPACE)
            name += " " + atom.upcase
          end
          if COMMANDS[@session.state].include?(name)
            result = send(name.tr(" ", "_").downcase)
            result.name = name
            match(T_CRLF)
            match(T_EOF)
          else
            result = UnrecognizedCommand.new
          end
        end
        result.tag = tag
      end
      result.session = @session
      return result
    end

    def capability
      return CapabilityCommand.new
    end

    def starttls
      return StarttlsCommand.new
    end

    def noop
      return NoopCommand.new
    end

    def logout
      return LogoutCommand.new
    end

    def authenticate
      match(T_SPACE)
      auth_type = atom.upcase
      case auth_type
      when "CRAM-MD5"
        return AuthenticateCramMD5Command.new
      when "PLAIN"
        return AuthenticatePlainCommand.new
      else
        raise format("unknown auth type: %s", auth_type)
      end
    end

    def login
      match(T_SPACE)
      userid = astring
      match(T_SPACE)
      password = astring
      return LoginCommand.new(userid, password)
    end

    def select
      match(T_SPACE)
      mailbox_name = mailbox
      return SelectCommand.new(mailbox_name)
    end

    def examine
      match(T_SPACE)
      mailbox_name = mailbox
      return ExamineCommand.new(mailbox_name)
    end

    def create
      match(T_SPACE)
      mailbox_name = mailbox
      return CreateCommand.new(mailbox_name)
    end

    def delete
      match(T_SPACE)
      mailbox_name = mailbox
      return DeleteCommand.new(mailbox_name)
    end

    def rename
      match(T_SPACE)
      mailbox_name = mailbox
      match(T_SPACE)
      new_mailbox_name = mailbox
      return RenameCommand.new(mailbox_name, new_mailbox_name)
    end

    def subscribe
      match(T_SPACE)
      mailbox_name = mailbox
      return NoopCommand.new
    end

    def unsubscribe
      match(T_SPACE)
      mailbox_name = mailbox
      return NoopCommand.new
    end

    def list
      match(T_SPACE)
      reference_name = mailbox
      match(T_SPACE)
      mailbox_name = list_mailbox
      return ListCommand.new(reference_name, mailbox_name)
    end

    def lsub
      match(T_SPACE)
      reference_name = mailbox
      match(T_SPACE)
      mailbox_name = list_mailbox
      return ListCommand.new(reference_name, mailbox_name)
    end

    def list_mailbox
      token = lookahead
      if string_token?(token)
        s = string
        if /\AINBOX\z/ni.match(s)
          return "INBOX"
        else
          return s
        end
      else
        result = ""
        loop do
          token = lookahead
          if list_mailbox_token?(token)
            result.concat(token.value)
            shift_token
          else
            if result.empty?
              parse_error("unexpected token %s", token.symbol)
            else
              if /\AINBOX\z/ni.match(result)
                return "INBOX"
              else
                return result
              end
            end
          end
        end
      end
    end

    LIST_MAILBOX_TOKENS = [
      T_ATOM,
      T_NUMBER,
      T_NIL,
      T_LBRA,
      T_RBRA,
      T_PLUS,
      T_STAR,
      T_PERCENT
    ]

    def list_mailbox_token?(token)
      return LIST_MAILBOX_TOKENS.include?(token.symbol)
    end

    def status
      match(T_SPACE)
      mailbox_name = mailbox
      match(T_SPACE)
      match(T_LPAR)
      atts = []
      atts.push(status_att)
      loop do
        token = lookahead
        if token.symbol == T_RPAR
          shift_token
          break
        end
        match(T_SPACE)
        atts.push(status_att)
      end
      return StatusCommand.new(mailbox_name, atts)
    end

    def status_att
      att = atom.upcase
      unless /\A(MESSAGES|RECENT|UIDNEXT|UIDVALIDITY|UNSEEN)\z/.match(att)
        parse_error("unknown att `%s'", att)
      end
      return att
    end

    def mailbox
      result = astring
      if /\AINBOX\z/ni.match(result)
        return "INBOX"
      else
        return result
      end
    end

    def append
      match(T_SPACE)
      mailbox_name = mailbox
      match(T_SPACE)
      token = lookahead
      if token.symbol == T_LPAR
        flags = flag_list
        match(T_SPACE)
        token = lookahead
      else
        flags = []
      end
      if token.symbol == T_QUOTED
        shift_token
        datetime = token.value
        match(T_SPACE)
      else
        datetime = nil
      end
      token = match(T_LITERAL)
      message = token.value
      return AppendCommand.new(mailbox_name, flags, datetime, message)
    end

    def idle
      return IdleCommand.new
    end

    def check
      return NoopCommand.new
    end

    def close
      return CloseCommand.new
    end

    def expunge
      return ExpungeCommand.new
    end

    def search
      return parse_search(SearchCommand)
    end

    def uid_search
      return parse_search(UidSearchCommand)
    end

    def parse_search(command_class)
      match(T_SPACE)
      token = lookahead
      if token.value == "CHARSET"
        shift_token
        match(T_SPACE)
        charset = astring
        match(T_SPACE)
      else
        charset = "us-ascii"
      end
      mailbox = @session.get_current_mailbox
      return command_class.new(search_keys(charset))
    end

    def search_keys(charset)
      result = NullQuery.new
      token = lookahead
      if token.symbol == T_ATOM && token.value.upcase == "NOT"
        shift_token
        match(T_SPACE)
        result = @current_mailbox_query - search_key(charset)
      else
        result &= search_key(charset)
      end
      loop do
        token = lookahead
        if token.symbol != T_SPACE
          break
        end
        shift_token
        token = lookahead
        if token.symbol == T_ATOM && token.value.upcase == "NOT"
          shift_token
          match(T_SPACE)
          result -= search_key(charset)
        else
          result &= search_key(charset)
        end
      end
      return result
    end

    def search_key(charset)
      token = lookahead
      if /\A(\d+|\*)/.match(token.value)
        raise NotImplementedError.new("sequence number search is not implemented")
      elsif token.symbol == T_LPAR
        shift_token
        result = search_keys(charset)
        match(T_RPAR)
        return result
      end

      name = tokens([T_ATOM, T_NUMBER, T_NIL, T_PLUS, T_STAR])
      case name.upcase
      when "UID"
        match(T_SPACE)
        return uid_search_key(sequence_set)
      when "BODY", "TEXT"
        match(T_SPACE)
        return TermQuery.new(utf8_astring(charset))
      when "HEADER"
        match(T_SPACE)
        header_name = astring.downcase
        match(T_SPACE)
        case header_name
        when "x-ml-name", "x-mail-count"
          return PropertyEqQuery.new(header_name, utf8_astring(charset))
        else
          return PropertyPeQuery.new(header_name, utf8_astring(charset))
        end
      when "SUBJECT"
        match(T_SPACE)
        return PropertyPeQuery.new("subject", utf8_astring(charset))
      when "FROM"
        match(T_SPACE)
        return PropertyPeQuery.new("from", utf8_astring(charset))
      when "TO"
        match(T_SPACE)
        return PropertyPeQuery.new("to", utf8_astring(charset))
      when "CC"
        match(T_SPACE)
        return PropertyPeQuery.new("cc", utf8_astring(charset))
      when "BCC"
        match(T_SPACE)
        return PropertyPeQuery.new("bcc", utf8_astring(charset))
      when "BEFORE"
        match(T_SPACE)
        return PropertyLeQuery.new("internal-date", iso8601_date(date))
      when "ON"
        match(T_SPACE)
        d = date
        next_d = d + 1
        return AndQuery.new([
          PropertyGeQuery.new("internal-date", iso8601_date(d)),
          PropertyLtQuery.new("internal-date", iso8601_date(next_d))
        ])
      when "SINCE"
        match(T_SPACE)
        return PropertyGeQuery.new("internal-date", iso8601_date(date + 1))
      when "SENTBEFORE"
        match(T_SPACE)
        return PropertyLeQuery.new("date", iso8601_date(date))
      when "SENTON"
        match(T_SPACE)
        d = date
        next_d = d + 1
        return AndQuery.new([
          PropertyGeQuery.new("date", iso8601_date(d)),
          PropertyLtQuery.new("date", iso8601_date(next_d))
        ])
      when "SENTSINCE"
        match(T_SPACE)
        return PropertyGeQuery.new("date", iso8601_date(date + 1))
      when "LARGER"
        match(T_SPACE)
        return PropertyGtQuery.new("size", number)
      when "SMALLER"
        match(T_SPACE)
        return PropertyLtQuery.new("size", number)
      when "ANSWERED"
        return FlagQuery.new("\~Answered")
      when "DELETED"
        return FlagQuery.new("\~deleted")
      when "DRAFT"
        return FlagQuery.new("\~draft")
      when "FLAGGED"
        return FlagQuery.new("\~Flagged")
      when "RECENT", "NEW"
        return FlagQuery.new("\~Recent")
      when "SEEN"
        return DiffQuery.new & FlagQuery.new("\~unread")
      when "KEYWORD"
        match(T_SPACE)
        return FlagQuery.new(atom)
      when "UNANSWERED"
        return DiffQuery.new & FlagQuery.new("\~Answered")
      when "UNDELETED"
        return DiffQuery.new & FlagQuery.new("\~deleted")
      when "UNDRAFT"
        return DiffQuery.new & FlagQuery.new("\~draft")
      when "UNFLAGGED"
        return DiffQuery.new & FlagQuery.new("\~Flagged")
      when "UNSEEN"
        return FlagQuery.new("\~unread")
      when "OLD"
        return DiffQuery.new & FlagQuery.new("\~Recent")
      when "UNKEYWORD"
        match(T_SPACE)
        return TermQuery.new(atom)
      when "OR"
        match(T_SPACE)
        q1 = search_key(charset)
        match(T_SPACE)
        q2 = search_key(charset)
        return OrQuery.new([q1, q2])
      when "NOT"
        match(T_SPACE)
        return @current_mailbox_query - search_key(charset)
      else
        return NullQuery.new
      end
    end

    def uid_search_key(sequence_set)
      result = NullQuery.new
      for i in sequence_set
        case i
        when Range
          if i.last == -1
            q = PropertyGeQuery.new("uid", i.first)
          else
            q = AndQuery.new([
              PropertyGeQuery.new("uid", i.first),
              PropertyLeQuery.new("uid", i.last)
            ])
          end
        else
          q = PropertyEqQuery.new("uid", i)
        end
        result |= q
      end
      return result
    end

    def utf8_astring(charset)
      return Iconv.conv("utf-8", charset, astring)
    end

    def date
      begin
        return DateTime.strptime(astring, "%d-%b-%Y")
      rescue ArgumentError
        raise InvalidQueryError.new("invalid date string #{date_str}")
      end
    end

    def iso8601_date(d)
      return d.strftime("%Y-%m-%dT%H:%M:%S")
    end

    def fetch
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      atts = fetch_atts
      return FetchCommand.new(seq_set, atts)
    end

    def uid_fetch
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      atts = fetch_atts
      return UidFetchCommand.new(seq_set, atts)
    end

    def fetch_atts
      token = lookahead
      if token.symbol == T_LPAR
        shift_token
        result = []
        result.push(fetch_att)
        loop do
          token = lookahead
          if token.symbol == T_RPAR
            shift_token
            break
          end
          match(T_SPACE)
          result.push(fetch_att)
        end
        return result
      else
        case token.value
        when "ALL"
          shift_token
          result = []
          result.push(FlagsFetchAtt.new)
          result.push(InternalDateFetchAtt.new)
          result.push(RFC822SizeFetchAtt.new)
          result.push(EnvelopeFetchAtt.new)
          return result
        when "FAST"
          shift_token
          result = []
          result.push(FlagsFetchAtt.new)
          result.push(InternalDateFetchAtt.new)
          result.push(RFC822SizeFetchAtt.new)
          return result
        when "FULL"
          shift_token
          result = []
          result.push(FlagsFetchAtt.new)
          result.push(InternalDateFetchAtt.new)
          result.push(RFC822SizeFetchAtt.new)
          result.push(EnvelopeFetchAtt.new)
          result.push(BodyFetchAtt.new)
          return result
        else
          return [fetch_att]
        end
      end
    end

    def fetch_att
      token = match(T_ATOM)
      case token.value
      when /\A(?:ENVELOPE)\z/ni
        return EnvelopeFetchAtt.new
      when /\A(?:FLAGS)\z/ni
        return FlagsFetchAtt.new
      when /\A(?:RFC822)\z/ni
        return RFC822FetchAtt.new
      when /\A(?:RFC822\.HEADER)\z/ni
        return RFC822HeaderFetchAtt.new
      when /\A(?:RFC822\.SIZE)\z/ni
        return RFC822SizeFetchAtt.new
      when /\A(?:RFC822\.TEXT)\z/ni
        return RFC822TextFetchAtt.new
      when /\A(?:BODY)?\z/ni
        token = lookahead
        if token.symbol != T_LBRA
          return BodyFetchAtt.new
        end
        return BodySectionFetchAtt.new(section, opt_partial, false)
      when /\A(?:BODY\.PEEK)\z/ni
        return BodySectionFetchAtt.new(section, opt_partial, true)
      when /\A(?:BODYSTRUCTURE)\z/ni
        return BodyStructureFetchAtt.new
      when /\A(?:UID)\z/ni
        return UidFetchAtt.new
      when /\A(?:INTERNALDATE)\z/ni
        return InternalDateFetchAtt.new
      else
        parse_error("unknown attribute `%s'", token.value)
      end
    end

    def section
      match(T_LBRA)
      token = lookahead
      if token.symbol != T_RBRA
        s = tokens([T_ATOM, T_NUMBER, T_NIL, T_PLUS])
        case s
        when /\A(?:(?:([0-9.]+)\.)?(HEADER|TEXT))\z/ni
          result = Section.new($1, $2.upcase)
        when /\A(?:(?:([0-9.]+)\.)?(HEADER\.FIELDS(?:\.NOT)?))\z/ni
          match(T_SPACE)
          result = Section.new($1, $2.upcase, header_list)
        when /\A(?:([0-9.]+)\.(MIME))\z/ni
          result = Section.new($1, $2.upcase)
        when /\A([0-9.]+)\z/ni
          result = Section.new($1)
        else
          parse_error("unknown section `%s'", s)
        end
      end
      match(T_RBRA)
      return result
    end

    def header_list
      result = []
      match(T_LPAR)
      result.push(astring.upcase)
      loop do
        token = lookahead
        if token.symbol == T_RPAR
          shift_token
          break
        end
        match(T_SPACE)
        result.push(astring.upcase)
      end
      return result
    end

    def opt_partial
      token = lookahead
      if m = /<(\d+)\.(\d+)>/.match(token.value)
        shift_token
        return Partial.new(m[1].to_i, m[2].to_i)
      end
      return nil
    end
    Partial = Struct.new(:offset, :size)

    def store
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      att = store_att_flags
      return StoreCommand.new(seq_set, att)
    end

    def uid_store
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      att = store_att_flags
      return UidStoreCommand.new(seq_set, att)
    end

    def store_att_flags
      item = atom
      match(T_SPACE)
      token = lookahead
      if token.symbol == T_LPAR
        flags = flag_list
      else
        flags = []
        flags.push(flag)
        loop do
          token = lookahead
          if token.symbol != T_SPACE
            break
          end
          shift_token
          flags.push(flag)
        end
      end
      case item
      when /\AFLAGS(\.SILENT)?\z/ni
        return SetFlagsStoreAtt.new(flags, !$1.nil?)
      when /\A\+FLAGS(\.SILENT)?\z/ni
        return AddFlagsStoreAtt.new(flags, !$1.nil?, @session)
      when /\A-FLAGS(\.SILENT)?\z/ni
        return RemoveFlagsStoreAtt.new(flags, !$1.nil?)
      else
        parse_error("unkown data item - `%s'", item)
      end
    end

    FLAG_REGEXP = /\
(?# FLAG        )(\\[^\x80-\xff(){ \x00-\x1f\x7f%"\\]+)|\
(?# ATOM        )([^\x80-\xff(){ \x00-\x1f\x7f%*"\\]+)/n

    def flag_list
      match(T_LPAR)
      if @str.index(/([^)]*)\)/ni, @pos)
        @pos = $~.end(0)
        return $1.scan(FLAG_REGEXP).collect { |flag, atom|
          atom || flag
        }
      else
        parse_error("invalid flag list")
      end
    end

    EXACT_FLAG_REGEXP = /\A\
(?# FLAG        )\\([^\x80-\xff(){ \x00-\x1f\x7f%"\\]+)|\
(?# ATOM        )([^\x80-\xff(){ \x00-\x1f\x7f%*"\\]+)\z/n

    def flag
      result = atom
      unless EXACT_FLAG_REGEXP.match(s)
        parse_error("invalid flag")
      end
      return result
    end

    def sequence_set
      s = ""
      loop do
        token = lookahead
        break if !atom_token?(token) && token.symbol != T_STAR
        shift_token
        s.concat(token.value)
      end
      return s.split(/,/n).collect { |i|
        x, y = i.split(/:/n)
        if y.nil?
          parse_seq_number(x)
        else
          parse_seq_number(x) .. parse_seq_number(y)
        end
      }
    end

    def parse_seq_number(s)
      if s == "*"
        return -1
      else
        return s.to_i
      end
    end

    def copy
      return parse_copy(CopyCommand)
    end

    def uid_copy
      return parse_copy(UidCopyCommand)
    end

    def parse_copy(command_class)
      match(T_SPACE)
      seq_set = sequence_set
      match(T_SPACE)
      mailbox_name = mailbox
      return command_class.new(seq_set, mailbox_name)
    end

    def astring
      token = lookahead
      if string_token?(token)
        return string
      else
        return atom
      end
    end

    def string
      token = lookahead
      if token.symbol == T_NIL
        shift_token
        return nil
      end
      token = match(T_QUOTED, T_LITERAL)
      return token.value
    end

    STRING_TOKENS = [T_QUOTED, T_LITERAL, T_NIL]

    def string_token?(token)
      return STRING_TOKENS.include?(token.symbol)
    end

    def case_insensitive_string
      token = lookahead
      if token.symbol == T_NIL
        shift_token
        return nil
      end
      token = match(T_QUOTED, T_LITERAL)
      return token.value.upcase
    end

    def tokens(tokens)
      result = ""
      loop do
        token = lookahead
        if tokens.include?(token.symbol)
          result.concat(token.value)
          shift_token
        else
          if result.empty?
            parse_error("unexpected token %s", token.symbol)
          else
            return result
          end
        end
      end
    end

    ATOM_TOKENS = [
      T_ATOM,
      T_NUMBER,
      T_NIL,
      T_LBRA,
      T_RBRA,
      T_PLUS
    ]

    def atom
      return tokens(ATOM_TOKENS)
    end

    def atom_token?(token)
      return ATOM_TOKENS.include?(token.symbol)
    end

    def number
      token = lookahead
      if token.symbol == T_NIL
        shift_token
        return nil
      end
      token = match(T_NUMBER)
      return token.value.to_i
    end

    def nil_atom
      match(T_NIL)
      return nil
    end

    def match(*args)
      token = lookahead
      unless args.include?(token.symbol)
        parse_error('unexpected token %s (expected %s)',
                    token.symbol.id2name,
                    args.collect {|i| i.id2name}.join(" or "))
      end
      shift_token
      return token
    end

    def lookahead
      unless @token
        @token = next_token
      end
      return @token
    end

    def shift_token
      @token = nil
    end

    def next_token
      case @lex_state
      when EXPR_BEG
        if @str.index(BEG_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_SPACE, $+)
          elsif $2
            return Token.new(T_NIL, $+)
          elsif $3
            return Token.new(T_NUMBER, $+)
          elsif $4
            return Token.new(T_ATOM, $+)
          elsif $5
            return Token.new(T_QUOTED,
                             $+.gsub(/\\(["\\])/n, "\\1"))
          elsif $6
            return Token.new(T_LPAR, $+)
          elsif $7
            return Token.new(T_RPAR, $+)
          elsif $8
            return Token.new(T_BSLASH, $+)
          elsif $9
            return Token.new(T_STAR, $+)
          elsif $10
            return Token.new(T_LBRA, $+)
          elsif $11
            return Token.new(T_RBRA, $+)
          elsif $12
            len = $+.to_i
            val = @str[@pos, len]
            @pos += len
            return Token.new(T_LITERAL, val)
          elsif $13
            return Token.new(T_PLUS, $+)
          elsif $14
            return Token.new(T_PERCENT, $+)
          elsif $15
            return Token.new(T_CRLF, $+)
          elsif $16
            return Token.new(T_EOF, $+)
          else
            parse_error("[ximapd BUG] BEG_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_DATA
        if @str.index(DATA_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_SPACE, $+)
          elsif $2
            return Token.new(T_NIL, $+)
          elsif $3
            return Token.new(T_NUMBER, $+)
          elsif $4
            return Token.new(T_QUOTED,
                             $+.gsub(/\\(["\\])/n, "\\1"))
          elsif $5
            len = $+.to_i
            val = @str[@pos, len]
            @pos += len
            return Token.new(T_LITERAL, val)
          elsif $6
            return Token.new(T_LPAR, $+)
          elsif $7
            return Token.new(T_RPAR, $+)
          else
            parse_error("[ximapd BUG] BEG_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_TEXT
        if @str.index(TEXT_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_TEXT, $+)
          else
            parse_error("[ximapd BUG] TEXT_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_RTEXT
        if @str.index(RTEXT_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_LBRA, $+)
          elsif $2
            return Token.new(T_TEXT, $+)
          else
            parse_error("[ximapd BUG] RTEXT_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos)
          parse_error("unknown token - %s", $&.dump)
        end
      when EXPR_CTEXT
        if @str.index(CTEXT_REGEXP, @pos)
          @pos = $~.end(0)
          if $1
            return Token.new(T_TEXT, $+)
          else
            parse_error("[ximapd BUG] CTEXT_REGEXP is invalid")
          end
        else
          @str.index(/\S*/n, @pos) #/
          parse_error("unknown token - %s", $&.dump)
        end
      else
        parse_error("illegal @lex_state - %s", @lex_state.inspect)
      end
    end

    def parse_error(fmt, *args)
      puts "@str: #{@str.inspect}"
      puts "@pos: #{@pos}"
      puts "@lex_state: #{@lex_state}"
      if @token && @token.symbol
        puts "@token.symbol: #{@token.symbol}"
        puts "@token.value: #{@token.value.inspect}"
      end
      raise CommandParseError, format(fmt, *args)
    end
  end

  class CommandParseError < StandardError
  end
end
