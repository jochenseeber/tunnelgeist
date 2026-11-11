# Runs calls in fibers and waits for them with a time limit, so a spec can
# show that a call does not wait for a lock another fiber holds: a call that
# waits fails the test instead of hanging it.
module TunnelgeistPromptCalls
  extend self

  # How long `awaited` and `promptly` wait for a call.
  PROMPT_LIMIT = 1.second

  # Runs the block in a fiber; the channel receives its value, or what it
  # raised.
  def later(&block : -> T) : Channel(T | Exception) forall T
    done = Channel(T | Exception).new(1)
    spawn do
      done.send(block.call)
    rescue error
      done.send(error)
    end
    done
  end

  # The value *done* receives within `PROMPT_LIMIT`; raises what the call
  # raised, or when nothing arrives in time.
  def awaited(done : Channel(T | Exception)) : T forall T
    result = select
    when value = done.receive
      value
    when timeout(PROMPT_LIMIT)
      raise "the call did not return within #{PROMPT_LIMIT.total_seconds} seconds"
    end
    raise result if result.is_a?(Exception)

    result
  end

  # Runs the block in a fiber and returns its value; raises when it does not
  # return within `PROMPT_LIMIT`.
  def promptly(&block : -> T) : T forall T
    awaited(later(&block))
  end
end
