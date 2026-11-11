# A spec asked a `TunnelgeistFakeDirectory` for a directory outside the
# temporary directory it serves. The loader turns neither `ArgumentError`
# nor `Config::Error` into anything else, so this is neither, and the
# misdirected spec fails with it.
class TunnelgeistOutsideTemporaryDirectory < Exception
end
