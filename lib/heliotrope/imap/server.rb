# encoding: UTF-8


module Heliotrope

  class IMAPServer

    def initialize opts, metaindex, zmbox
      @config = {:port => opts[:imap_port], :user => opts[:imap_user], :password => opts[:imap_pass]}

      @mail_store = MailStore.new metaindex, zmbox
    end

    def run
      server = TCPServer.new @config[:port]
      # Yo dawg, I heard you like Threads and loops
      # Spawn one thread that will be in charge of listening, which
      # means looping. In this loop, create a new thread per client and
      # treat it
      Thread.start do
        loop do
          Thread.start(server.accept) do |sock|
            loop do
              p "open"
              configure_socket(sock)
              Session.new(sock, @mail_store,  @config, self).start
            end
          end
        end
      end
    end

    private

    def configure_socket(sock)
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      if defined?(Fcntl::FD_CLOEXEC)
        sock.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
      end
      if defined?(Fcntl::O_NONBLOCK)
        sock.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
      end
    end

  end

end
