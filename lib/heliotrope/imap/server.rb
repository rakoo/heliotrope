# encoding: UTF-8


module Heliotrope

  class IMAPServer

    def initialize opts, metaindex, zmbox
      @port = opts[:imap_port]
      @user = opts[:imap_user]
      @pass = opts[:imap_pass]

      @metaindex = metaindex
      @zmbox = zmbox
    end

    def run
      begin
        trap("INT", "IGNORE")
        Signal.trap("TERM", &method(:terminate))
        Signal.trap("INT", &method(:terminate))
        @mail_store = MailStore.new(@config)
        start_server @port
      rescue Exception => e
        STDERR.printf("imaptrope: %s\n", e)
        unless e.kind_of?(StandardError)
          raise
        end
        exit(1)
      end
    end

    private

    def start_server(port)
      server = TCPServer.new port
      begin
        loop do
          sock = server.accept
          configure_socket(sock)
          if @sessions.length >= @max_clients
            reject_client(sock)
            next
          end
          start_session(sock)
        end
      ensure
        server.close
      end
    end

    def configure_socket(sock)
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      if defined?(Fcntl::FD_CLOEXEC)
        sock.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      end
      if defined?(Fcntl::O_NONBLOCK)
        sock.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
      end
    end

    def start_session(socket)
      session = Session.new(@config, socket, @mail_store, self)
      @sessions[Thread.current] = session
      begin
        session.start
      ensure
        @sessions.delete(Thread.current)
      end
    end

end
