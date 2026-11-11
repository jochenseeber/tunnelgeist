require "log"
require "microtest"

include Microtest::DSL

# Runs the block and returns the error of *error_class* it raised, so a test can
# inspect it; microtest's assert_raises returns nothing.
def raised(error_class : T.class, &) : T forall T
  yield
  raise "expected #{error_class} but nothing was raised"
rescue error : T
  error
end

# `Log#finalize` initializes `Log.builder` on first use. Specs that build their
# logs with `Log.new` never touch it, so the first finalizer the GC runs would
# start that initialization, and an allocation inside it can run another `Log`
# finalizer and raise "Recursion while initializing class variables". It is
# initialized here, before any test runs.
Log.builder

# microtest installs no at_exit hook, so the suite is started here. Crystal
# loads a require once, so this runs once although every spec requires it.
Microtest.run!([
  Microtest::ProgressReporter.new,
  Microtest::ErrorListReporter.new,
  Microtest::SlowTestsReporter.new,
  Microtest::SummaryReporter.new,
] of Microtest::Reporter)
