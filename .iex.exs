alias Kinoko.Repl, as: Y
alias Kinoko.{Universe, Exec}

IO.puts("""

Yabu REPL: Y.load("test/fixtures/yabu/counter.yabu"), then Y.eval("Counter.init()").
State lives in the current universe ("main" by default; Y.universes(), Y.create(name),
Y.use(name) - create a fresh one to start over). Y.last() is the last value eval/call
computed. Also Y.symbols(), Y.test(name), Y.read(name). See `h Kinoko.Repl`.
""")
