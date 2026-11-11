{% skip_file unless flag?(:darwin) %}

require "socket"
require "../fd_passing"
require "../interface_name"
require "../protocol/common"
require "../protocol/error"

module Tunnelgeist
  class Handler
    # One request line as it arrived and the descriptors that came with it
    # (RF1.1, RF1.2). The handler reads every request this way, so a
    # descriptor sent with any request is received and closed, and a change
    # pins its device with the one it carries (RF1.3). Owns the descriptors
    # until `close`.
    class RequestLine
      # The most bytes one read takes.
      private CHUNK_SIZE = 4_096

      # The line, without its newline.
      getter text : String

      # The descriptors that arrived with the line, open until `close`;
      # `FdPassing.receive` closed any beyond the first of one read.
      @descriptors : Array(Int32)
      # How many descriptors arrived, the ones `FdPassing.receive` closed
      # included.
      @descriptor_count : Int32

      private def initialize(@text : String, *, @descriptors : Array(Int32), @descriptor_count : Int32)
      end

      # Reads the line from *socket*: up to the first newline, under one
      # deadline *timeout* away for the whole line, so a client that drips
      # bytes cannot hold the connection open. Every read is a `recvmsg`
      # that takes the descriptors of its bytes, so none that came with the
      # line is missed. Reads at most one byte over `Protocol::MAX_REQUEST`,
      # which tells a line at the limit from a longer one. Bytes after the
      # newline are ignored, with any descriptor that came after them: they
      # stay in the socket, and the kernel closes such descriptors with it.
      # End of stream ends the line.
      #
      # Raises `IO::TimeoutError` at the deadline, `Protocol::Error` for a
      # line that is empty or too long and `IO::Error` when a read fails;
      # the descriptors that arrived are closed then.
      def self.read(socket : UNIXSocket, *, timeout : Time::Span) : RequestLine
        deadline = Time.instant + timeout
        line = IO::Memory.new
        chunk = Bytes.new(CHUNK_SIZE)
        descriptors = [] of Int32
        count = 0
        begin
          loop do
            remaining = deadline - Time.instant
            raise IO::TimeoutError.new("Read timed out") unless remaining.positive?

            socket.read_timeout = remaining
            room = Protocol::MAX_REQUEST + 1 - line.size
            received = FdPassing.receive(socket, buffer: chunk[0, Math.min(chunk.size, room)])
            received.fd.try { |descriptor| descriptors << descriptor }
            count += received.descriptor_count
            break if received.size == 0

            piece = chunk[0, received.size]
            newline = piece.index('\n'.ord.to_u8)
            if newline
              line.write(piece[0, newline])
              break
            end
            line.write(piece)
            raise Protocol::Error.new("request longer than #{Protocol::MAX_REQUEST} bytes") if line.size > Protocol::MAX_REQUEST
          end
          raise Protocol::Error.new("no request") if line.size == 0
        rescue error
          descriptors.each { |descriptor| LibC.close(descriptor) }
          raise error
        end

        new(line.to_s, descriptors: descriptors, descriptor_count: count)
      end

      # The one descriptor that came with the line, checked to be the utun
      # device *name*: *name_of* answers a descriptor's interface name and
      # raises `IO::Error` for one that is no utun device. The descriptor
      # stays open until `close`, which pins the device: the kernel cannot
      # destroy the interface and give its name to another while the
      # handler holds it.
      #
      # Raises `Protocol::Error` when the line came with no descriptor or
      # more than one, when the descriptor is no utun device, and when it is
      # another one, naming the field `name`.
      def pin(name : InterfaceName, *, name_of : Int32 -> InterfaceName) : Int32
        raise Protocol::Error.new("request must carry the device's descriptor") if @descriptor_count == 0
        raise Protocol::Error.new("request must carry only the device's descriptor") if @descriptor_count > 1

        descriptor = @descriptors.first
        actual = begin
          name_of.call(descriptor)
        rescue error : IO::Error
          raise Protocol::Error.new("descriptor is not a utun device", cause: error)
        end
        raise Protocol::Error.new("descriptor is #{actual}, not #{name}", field: "name") if actual != name

        descriptor
      end

      # Closes every descriptor that came with the line; later calls do
      # nothing.
      def close : Nil
        @descriptors.each { |descriptor| LibC.close(descriptor) }
        @descriptors.clear
      end
    end
  end
end
