# encoding: UTF-8

require 'mail'
require 'digest/md5'
require 'json'
require 'timeout'

module Mail
  class Message

    # a common interface that matches all the field
    # IMPORTANT : if not existing, it must return nil
    def fetch_header field
      sym = field.to_sym
      self[sym] ? self[sym].to_s : nil
    end

    # Make sure the message has valid message ids for the message, and
    # fetch them
    def fetch_message_ids field
      self[field] ? self[field].message_ids || [self[field].message_id] : []
    end

  end
end

module Heliotrope
class InvalidMessageError < StandardError; end
class Message
  def initialize rawbody
    @rawbody = rawbody
    @mime_parts = {}
  end

  def parse!
    @m = Mail.read_from_string @rawbody

    # Mail::MessageIdField.message_id returns the msgid with < and >, which is not correct
    unless @m.message_id
      @m.message_id = "<#{Time.now.to_i}-defaulted-#{munge_msgid @m.header.to_s}@heliotrope>"
    end
    @msgid = @m.message_id
    @safe_msgid = munge_msgid @msgid

    @from = Person.from_string @m.fetch_header(:from)

    @sender = begin
      # Mail::SenderField.sender returns an array, not a String
      Person.from_string @m.fetch_header(:sender)
      rescue InvalidMessageError
        ""
    end

    @date = (@m.date || Time.now).to_time.to_i

    @to = Person.many_from_string(@m.fetch_header(:to))
    @cc = Person.many_from_string(@m.fetch_header(:cc))
    @bcc = Person.many_from_string(@m.fetch_header(:bcc))
    @subject =  (@m.subject || "")
    @reply_to = Person.from_string(@m.fetch_header(:reply_to))

    # same as message_id : we must use message_ids to get them without <
    # and >
    begin
      @refs = @m.fetch_message_ids(:references)
      in_reply_to = @m.fetch_message_ids(:in_reply_to)
    rescue Mail::Field::FieldError => e
      raise InvalidMessageError, e.message
    end
    @refs += in_reply_to unless @refs.member?(in_reply_to.first)
    @safe_refs = @refs.nil? ? [] : @refs.compact.map { |r| munge_msgid(r) }

    ## various other headers that you don't think we will need until we
    ## actually need them.

    ## this is sometimes useful for determining who was the actual target of
    ## the email, in the case that someone has aliases
    @recipient_email = @m.fetch_header(:envelope_to) || @m.fetch_header(:x_original_to) || @m.fetch_header(:delivered_to)

    @list_subscribe = @m.fetch_header(:list_subscribe)
    @list_unsubscribe = @m.fetch_header(:list_unsubscribe)
    @list_post = @m.fetch_header(:list_post) || @m.fetch_header(:x_mailing_list)

    self
  end

  attr_reader :msgid, :from, :to, :cc, :bcc, :subject, :date, :refs, :recipient_email, :list_post, :list_unsubscribe, :list_subscribe, :list_id, :reply_to, :safe_msgid, :safe_refs

  def is_list_or_automated_email?
    list_post || list_id || (from.email =~ /=|reply|postmaster|bounce/)
  end

  ## we don't encode any non-text parts here, because json encoding of
  ## binary objects is crazy-talk, and because those are likely to be
  ## big anyways.
  def to_h message_id, preferred_type
    parts = mime_parts(preferred_type).map do |type, fn, cid, content, size|
      if type =~ /^text\//
        { :type => type, :filename => fn, :cid => cid, :content => content, :here => true }
      else
        { :type => type, :filename => fn, :cid => cid, :size => content.size, :here => false }
      end
    end.compact

    { :from => (from ? from.to_email_address : ""),
      :to => to.map(&:to_email_address),
      :cc => (cc || []).map(&:to_email_address),
      :bcc => (bcc || []).map(&:to_email_address),
      :subject => subject,
      :date => date,
      :refs => refs,
      :parts => parts,
      :message_id => message_id,
      :snippet => snippet,
      :reply_to => (reply_to ? reply_to.to_email_address : ""),

      :recipient_email => recipient_email,
      :list_post => list_post,
      :list_subscribe => list_subscribe,
      :list_unsubscribe => list_unsubscribe,

      :email_message_id => @msgid,
    }
  end

  def direct_recipients; to end
  def indirect_recipients; (cc || []) + (bcc || []) end
  def recipients; (direct_recipients || []) + (indirect_recipients || []) end

  def indexable_text
    @indexable_text ||= begin
      v = ([from.indexable_text] +
        recipients.map { |r| r.indexable_text } +
        [subject] +
        mime_parts("text/plain").map do |type, fn, id, content|
          if fn
            fn
          elsif type =~ /text\//
            content
          end
        end
      ).flatten.compact.join(" ")

      v.gsub(/\s+[\W\d_]+(\s|$)/, " "). # drop funny tokens
        gsub(/\s+/, " ")
    end
  end

  SIGNED_MIME_TYPE = %r{multipart/signed;.*protocol="?application/pgp-signature"?}m
  ENCRYPTED_MIME_TYPE = %r{multipart/encrypted;.*protocol="?application/pgp-encrypted"?}m
  SIGNATURE_ATTACHMENT_TYPE = %r{application\/pgp-signature\b}

  def snippet
    mime_parts("text/plain").each do |type, fn, id, content|
      if (type =~ /text\//) && fn.nil?
        head = content[0, 1000].split "\n"
        head.shift while !head.empty? && head.first.empty? || head.first =~ /^\s*>|\-\-\-|(wrote|said):\s*$/
        snippet = head.join(" ").gsub(/^\s+/, "").gsub(/\s+/, " ")[0, 100]
        return snippet
      end
    end
    ""
  end

  def has_attachment?
    @m.has_attachments? # defined in the mail gem
  end

  def signed?
    @signed ||= mime_part_types.any? { |t| t =~ SIGNED_MIME_TYPE }
  end

  def encrypted?
    @encrypted ||= mime_part_types.any? { |t| t =~ ENCRYPTED_MIME_TYPE }
  end

  def mime_parts preferred_type
    @mime_parts[preferred_type] ||= decode_mime_parts @m, preferred_type
  end

private

  ## hash the fuck out of all message ids. trust me, you want this.
  def munge_msgid msgid
    Digest::MD5.hexdigest msgid
  end

  def mime_part_types part=@m
    ptype = part.fetch_header(:content_type)
    [ptype] + (part.multipart? ? part.body.parts.map { |sub| mime_part_types sub } : [])
  end

  ## unnests all the mime stuff and returns a list of [type, filename, content]
  ## tuples.
  ##
  ## for multipart/alternative parts, will only return the subpart that matches
  ## preferred_type. if none of them, will only return the first subpart.
  def decode_mime_parts part, preferred_type, level=0
    if part.multipart?
      if mime_type_for(part) =~ /multipart\/alternative/
        target = part.body.parts.find { |p| mime_type_for(p).index(preferred_type) } || part.body.parts.first
        if target # this can be nil
          decode_mime_parts target, preferred_type, level + 1
        else
          []
        end
      else # decode 'em all
        part.body.parts.compact.map { |subpart| decode_mime_parts subpart, preferred_type, level + 1 }.flatten 1
      end
    else
      type = mime_type_for part
      filename = mime_filename_for part
      id = mime_id_for part
      content = mime_content_for part, preferred_type
      [[type, filename, id, content]]
    end
  end

private

  def validate_field what, thing
    raise InvalidMessageError, "missing '#{what}' header" if thing.nil?
    thing = thing.to_s.strip
    raise InvalidMessageError, "blank '#{what}' header: #{thing.inspect}" if thing.empty?
    thing
  end

  def mime_type_for part
    (part.fetch_header(:content_type) || "text/plain").gsub(/\s+/, " ").strip.downcase
  end

  def mime_id_for part
    header = part.fetch_header(:content_id)
    case header
      when /<(.+?)>/; $1
      else header
    end
  end

  ## a filename, or nil
  def mime_filename_for part
    cd = part.fetch_header(:content_disposition)
    ct = part.fetch_header(:content_type)

    ## RFC 2183 (Content-Disposition) specifies that disposition-parms are
    ## separated by ";". So, we match everything up to " and ; (if present).
    filename = if ct && ct =~ /name="?(.*?[^\\])("|;|\z)/im # find in content-type
      $1
    elsif cd && cd =~ /filename="?(.*?[^\\])("|;|\z)/m # find in content-disposition
      $1
    end

    ## filename could be RFC2047 encoded
    filename.chomp if filename
  end

  CONVERSIONS = {
    ["text/html", "text/plain"] => :html_to_text
  }

  ## the content of a mime part itself. if the content-type is text/*,
  ## it will be converted to utf8. otherwise, it will be left in the
  ## original encoding
  def mime_content_for mime_part, preferred_type
    return "" unless mime_part.body # sometimes this happens. not sure why.

    content_type = mime_part.fetch_header(:content_type) || "text/plain"
    source_charset = mime_part.charset || "US-ASCII"

    content = mime_part.decoded
    converted_content, converted_charset = if(converter = CONVERSIONS[[content_type, preferred_type]])
      send converter, content, source_charset
    else
      [content, source_charset]
    end

    if content_type =~ /^text\//
      Decoder.transcode "utf-8", converted_charset, converted_content
    else
      converted_content
    end
  end

  require 'locale'
  SYSTEM_CHARSET = Locale.charset
  HTML_CONVERSION_CMD = "html2text"
  HTML_CONVERSION_TIMEOUT = 10 # seconds... this thing can be slow
  def html_to_text html, charset
    ## ignore charset. html2text produces output in the system charset.
    #puts "; forced to decode html. running #{HTML_CONVERSION_CMD} on #{html.size}b mime part..."
    content = begin
      Timeout.timeout(HTML_CONVERSION_TIMEOUT) do
        Heliotrope.popen3(HTML_CONVERSION_CMD) do |inn, out, err|
          inn.print html
          inn.close
          out.read
        end
      end
    rescue Timeout::Error
      $stderr.puts "; warning: timeout when converting message from html to text"
      "[html conversion failed on this command (htmlconversionfailure)]"
    end
    [content, SYSTEM_CHARSET]
  end
end
end
