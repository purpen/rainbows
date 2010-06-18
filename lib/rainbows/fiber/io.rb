# -*- encoding: binary -*-
module Rainbows
  module Fiber

    # A partially complete IO wrapper, this exports an IO.select()-able
    # #to_io method and gives users the illusion of a synchronous
    # interface that yields away from the current Fiber whenever
    # the underlying IO object cannot read or write
    class IO < Struct.new(:to_io, :f)

      # for wrapping output response bodies
      def each(&block)
        begin
          yield readpartial(16384)
        rescue EOFError
          break
        end while true
        self
      end

      def close
        fileno = to_io.fileno
        RD[fileno] = WR[fileno] = nil
        to_io.close unless to_io.closed?
      end

      def wait_readable
        fileno = to_io.fileno
        RD[fileno] = self
        ::Fiber.yield
        RD[fileno] = nil
      end

      def wait_writable
        fileno = to_io.fileno
        WR[fileno] = self
        ::Fiber.yield
        WR[fileno] = nil
      end

      def write(buf)
        begin
          (w = to_io.write_nonblock(buf)) == buf.size and return
          buf = buf[w..-1]
        rescue Errno::EAGAIN
          wait_writable
          retry
        end while true
      end

      # used for reading headers (respecting keepalive_timeout)
      def read_timeout
        expire = nil
        begin
          to_io.read_nonblock(16384)
        rescue Errno::EAGAIN
          return if expire && expire < Time.now
          expire ||= Time.now + G.kato
          wait_readable
          retry
        end
      end

      def readpartial(length, buf = "")
        begin
          to_io.read_nonblock(length, buf)
        rescue Errno::EAGAIN
          wait_readable
          retry
        end
      end

    end
  end
end
