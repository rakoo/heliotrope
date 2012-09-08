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

  class Session

    attr_reader :config
    attr_reader :mail_store
    attr_reader :state, :current_mailbox
    attr_accessor :idle
    alias idle? idle

    def initialize(sock, mail_store, config, imapserver, pre_authenticated = false)
      @sock = sock
      @mail_store = mail_store
      @imapserver = imapserver
      @config = config
      @pre_authenticated = pre_authenticated
      @logout = false
      if pre_authenticated
        @state = IMAP_AUTHENTICATED_STATE
        @max_idle_seconds = IMAP_AUTHENTICATED_MAX_IDLE_SECONDS
      else
        @state = IMAP_NON_AUTHENTICATED_STATE
        @max_idle_seconds = IMAP_NON_AUTHENTICATED_MAX_IDLE_SECONDS
      end
      @current_mailbox = nil
      @read_only = false
      @secure = @sock.kind_of?(OpenSSL::SSL::SSLSocket)
      @queued_responses = {}
      @parser = CommandParser.new self, config
    end

    def start
      puts "; connect: #{@sock.peeraddr}"
      if @pre_authenticated
        send_preauth("heliotrope-imap version %s", IMAPVERSION)
      else
        send_ok("heliotrope-imap version %s", IMAPVERSION)
      end
      begin
        while !@logout
          begin
            cmd = recv_cmd
          rescue StandardError => e
            send_bad("parse error: %s", e)
            next
          end
          break if cmd.nil?
          #puts "; received #{cmd.tag} #{cmd.name} from #{@sock.peeraddr}"
          begin
            cmd.exec
          rescue Errno::EPIPE => e
            p e
            break
          rescue StandardError => e
            send_tagged_no(cmd.tag, "%s failed - %s", cmd.name, e)
            puts e.backtrace
          end
          #puts "; processed #{cmd.tag} #{cmd.name} from #{@sock.peeraddr}"
        end
      rescue Timeout::Error
        #@logger.info("autologout #{@peeraddr}")
        send_data("BYE Autologout; idle for too long")
      rescue TerminateException
        send_data("BYE IMAP server terminating connection")
      end
      @sock.close
      puts "disconnect from #{@sock.peeraddr}"
    end

    def logout
      @state = IMAP_LOGOUT_STATE
      @logout = true
    end

    def login
      @state = IMAP_AUTHENTICATED_STATE
      @max_idle_seconds = IMAP_AUTHENTICATED_MAX_IDLE_SECONDS
    end

    def select(mailbox)
      @current_mailbox = mailbox
      @read_only = false
      @state = IMAP_SELECTED_STATE
    end

    def examine(mailbox)
      @current_mailbox = mailbox
      @read_only = true
      @state = IMAP_SELECTED_STATE
    end

    def get_current_mailbox
			return @mail_store.get_mailbox(@current_mailbox)
    end

    def read_only?
      return @read_only
    end

    def close_mailbox
      cleanup_queued_responses
      @current_mailbox = nil
      @state = IMAP_AUTHENTICATED_STATE
    end

    #def sync
      #@mail_store.write_last_peeked_uids
    #end

    def push_response(mailbox, response)
      if mailbox.nil? || @current_mailbox == mailbox
        @queued_responses[mailbox] ||= []
        @queued_responses[mailbox].push "* " + response
      else
        # noop
      end
    end

    def recv_line
      timeout(@max_idle_seconds) do
        s = @sock.gets
        return s if s.nil?
        line = s.sub(/\r\n\z/n, "")
        #@logger.debug(line.gsub(/^/n, "C: ")) if @config["debug"]
        return line
      end
    end

    def recv_cmd
      timeout(@max_idle_seconds) do
        buf = ""
        loop do
          s = @sock.gets
          break unless s
          s.gsub!(/\r?\n\z/, "\r\n")
          buf.concat(s)
          if len = s.slice(/\{(\d+)\}\r\n/n, 1)
            send_continue_req("Ready for additional command text")
            n = len.to_i
            while n > 0
              tmp = @sock.read(n)
              n -= tmp.length
              buf.concat(tmp)
            end
          else
            break
          end
        end
        return nil if buf.length == 0
        puts
        puts "C: #{buf}"
        return @parser.parse(buf)
      end
    end

    def send_line(line)
      puts line.gsub(/^/, "S: ")
      @sock.print(line + "\r\n")
    end

    def send_tagged_response(tag, name, fmt, *args)
      msg = format(fmt, *args)
      send_line(tag + " " + name + " " + msg)
    end

    def send_tagged_ok(tag, fmt, *args)
      send_tagged_response(tag, "OK", fmt, *args)
    end

    def send_tagged_no(tag, fmt, *args)
      send_tagged_response(tag, "NO", fmt, *args)
    end

    def send_tagged_bad(tag, fmt, *args)
      send_tagged_response(tag, "BAD", fmt, *args)
    end

    def send_queued_responses(exclude = nil)
      queued_responses = []
      if @queued_responses.include?(@current_mailbox) &&
        !@queued_responses[@current_mailbox].empty?
        queued_responses << @queued_responses[@current_mailbox]
      end
      if @current_mailbox &&
        @queued_responses.include?(nil) &&
        !@queued_responses[nil].empty?
        queued_responses << @queued_responses[@current_mailbox]
      end
      queued_responses.each do |qr|
        if exclude
          rest, done = qr.partition do |str|
            exclude =~ str
          end
        else
          rest, done = [], qr
        end
        done.reverse.each do |str|
          send_line str
        end
        qr.replace(rest)
      end
      cleanup_queued_responses
    end

    def send_data(fmt, *args)
      s = format(fmt, *args)
      send_line("* " + s)
    end

    def send_ok(fmt, *args)
      send_data("OK " + fmt, *args)
    end

    def send_no(fmt, *args)
      send_data("NO " + fmt, *args)
    end

    def send_bad(fmt, *args)
      send_data("BAD " + fmt, *args)
    end

    def send_preauth(fmt, *args)
      send_data("PREAUTH " + fmt, *args)
    end

    def send_continue_req(fmt, *args)
      msg = format(fmt, *args)
      send_line("+ " + msg)
    end

    def all_session_on_idle?
      @imapd.all_session_on_idle?
    end

    def push_queued_response(mailbox_name, resp)
      return if @@test && @imapd.nil?
      @imapd.push_response(mailbox_name, resp, self)
    end

    private

    def cleanup_queued_responses
      @queued_responses.delete_if do |mailbox, queued_response|
        mailbox.nil? ?  false : true
      end
    end
  end
end
