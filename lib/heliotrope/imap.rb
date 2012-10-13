module Heliotrope

  module DataFormat
    module_function

    def quoted(s)
      if s.nil?
        return "NIL"
      else
        return format('"%s"', s.to_s.gsub(/[\r\n]/, "").gsub(/[\\"]/n, "\\\\\\&"))
      end
    end

    def literal(s)
      return format("{%d}\r\n%s", s.to_s.length, s)
    end
  end

  IMAP_NON_AUTHENTICATED_STATE = :NON_AUTHENTICATED_STATE
  IMAP_AUTHENTICATED_STATE = :AUTHENTICATED_STATE
  IMAP_SELECTED_STATE = :SELECTED_STATE
  IMAP_LOGOUT_STATE = :LOGOUT_STATE

  IMAP_NON_AUTHENTICATED_MAX_IDLE_SECONDS = 10
  IMAP_AUTHENTICATED_MAX_IDLE_SECONDS = 30 * 60

  IMAPVERSION = 0.1

  require "heliotrope/imap/server"
  require "heliotrope/imap/session"
  require "heliotrope/imap/command"
  require "heliotrope/imap/error"
  require "heliotrope/imap/query"
  require "heliotrope/imap/mailstore"
  require "heliotrope/imap/imapmessage"

end
