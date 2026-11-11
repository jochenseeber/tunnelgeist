{% skip_file unless flag?(:darwin) %}

require "./bounded_buffer"
require "./result"
require "./spawner"

module Tunnelgeist
  module CommandRunner
    # One run of a program: the child process, the pipes of its standard
    # input, output and error, and the fibers that feed and drain them.
    # `CommandRunner.run` starts one with `.start` and collects it with
    # `#finish`.
    class Execution
      # How long a program has to end after `TERM` before it gets `KILL`.
      TERMINATION_GRACE = 1.second

      # Bytes read from a pipe at a time.
      CHUNK_SIZE = 4_096

      # Starts *argv* by absolute path, without a shell and with an empty
      # environment, with *input* as its standard input when given and the
      # null device otherwise; keeps at most *output_limit* bytes of each of
      # its standard output and standard error. Raises `IO::Error` when the
      # program cannot be started. The program leads a process group of its
      # own, every signal has its default action, and it inherits no
      # descriptor but its standard input, output and error (`Spawner`).
      def self.start(argv : Array(String), *, input : String?, output_limit : Int32) : self
        # Declared before the `begin`, so that a failure closes the pipes
        # made before it.
        output_reader = output_writer = error_reader = error_writer = nil
        input_reader = input_writer = nil
        begin
          output_reader, output_writer = IO.pipe(write_blocking: true)
          error_reader, error_writer = IO.pipe(write_blocking: true)
          input_reader, input_writer = IO.pipe(read_blocking: true) if input
          process = Spawner.start(argv, input: input_reader, output: output_writer, error: error_writer)
          new(process, output: output_reader, error: error_reader, input: input_writer, text: input, output_limit: output_limit)
        rescue error
          [output_reader, error_reader, input_writer].each(&.try(&.close))
          raise error
        ensure
          # The child holds its own copies; the parent's would keep the pipes
          # open after the child ended.
          [output_writer, error_writer, input_reader].each(&.try(&.close))
        end
      end

      # The parent's end of the program's standard input, nil when it reads
      # the null device.
      @input : IO::FileDescriptor?

      # Whether `#stop` closed the pipes, so that their readers expect a
      # closed stream.
      @stopped = false

      # The parent's ends of the program's pipes, which `#stop` closes.
      @pipes : Array(IO::FileDescriptor)
      @output : BoundedBuffer
      @error : BoundedBuffer
      @drained = Channel(IO::Error?).new(2)
      @finished = Channel(Process::Status | Exception).new(1)

      private def initialize(@process : Process, *, output : IO::FileDescriptor, error : IO::FileDescriptor,
                             input : IO::FileDescriptor?, text : String?, output_limit : Int32)
        @input = input
        @pipes = [output, error, input].compact
        @output = BoundedBuffer.new(limit: output_limit)
        @error = BoundedBuffer.new(limit: output_limit)
        spawn { drain(output, into: @output) }
        spawn { drain(error, into: @error) }
        if input && text
          spawn { feed(input, text: text) }
        end
        spawn { await }
      end

      # Waits for the program to end and its output to be drained, at most
      # *timeout*. Then its process group is sent `TERM`, and `KILL` after
      # `TERMINATION_GRACE`, which stops the processes it started too unless
      # they left the group; it is always reaped. The `Result` keeps the
      # output read until then.
      def finish(timeout : Time::Span) : Result
        timed_out = false
        outcome = select
        when finished = @finished.receive
          finished
        when timeout(timeout)
          timed_out = true
          stop
        end
        # A process the program started may still hold its standard input
        # and keep `#feed` waiting.
        @input.try(&.close)
        raise outcome if outcome.is_a?(Exception)

        Result.new(exit_status: outcome.exit_code? || -1, output: @output.text, error: @error.text,
          timed_out_after: timed_out ? timeout : nil)
      end

      # Ends a program that ran out of time, and the processes it started, and
      # returns what `#await` reports. The group is signalled also when the
      # program itself already ended but a process it started still holds
      # its output open: the group's id stays taken while any member lives,
      # so it names no other process. The pipes are closed last, for a
      # process that left the group and still holds them.
      private def stop : Process::Status | Exception
        signal(Signal::TERM)
        select
        when finished = @finished.receive
          return finished
        when timeout(TERMINATION_GRACE)
          signal(Signal::KILL)
        end
        @stopped = true
        @pipes.each(&.close)
        @finished.receive
      end

      # Sends *signal* to the program's process group; a group whose members
      # all ended meanwhile is no error.
      private def signal(signal : Signal) : Nil
        return if LibC.kill(-@process.pid.to_i32, signal.value) == 0
        raise RuntimeError.from_errno("kill") unless Errno.value == Errno::ESRCH
      end

      # Reaps the program, waits until both pipes are drained and reports the
      # exit status, or the first error.
      private def await : Nil
        status = @process.wait
        errors = Array.new(2) { @drained.receive }.compact
        @finished.send(errors.first? || status)
      rescue error
        @finished.send(error)
      end

      # Reads *io* until its end into *buffer*, which drops what exceeds its
      # limit, so the program never blocks on a full pipe.
      private def drain(io : IO::FileDescriptor, *, into buffer : BoundedBuffer) : Nil
        failure = nil
        bytes = Bytes.new(CHUNK_SIZE)
        begin
          loop do
            count = io.read(bytes)
            break if count == 0

            buffer.append(bytes[0, count])
          end
        rescue error : IO::Error
          # `#stop` closes the pipes to end a read that a process the program
          # started keeps waiting.
          failure = error unless @stopped
        end
        io.close
        @drained.send(failure)
      end

      # Writes *text* to the program's standard input and closes it.
      private def feed(io : IO::FileDescriptor, *, text : String) : Nil
        io.sync = true
        io.write(text.to_slice)
      rescue IO::Error
        # The program closed its standard input or ended before reading all
        # of it; its exit status says whether that was a failure.
      ensure
        io.close
      end
    end
  end
end
