# The live suite (tag :php) shells out to a real `php` binary and is excluded
# by default, so `mix test` runs everywhere and still proves parity against the
# committed golden verdict files. Opt in with `mix test --include php` (or use
# the `mix php.test` alias, which regenerates the golden first).
ExUnit.start(exclude: [:php])
