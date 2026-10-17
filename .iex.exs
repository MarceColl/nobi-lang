alias Nobi.Repl, as: Y
alias Nobi.{Universe, Exec}

IO.puts("""

Nobi REPL: Y.load("test/fixtures/nobi/counter.nobi"), then Y.eval("Counter.init()").
State lives in the current universe ("main" by default; Y.universes(), Y.create(name),
Y.use(name) - create a fresh one to start over). Y.last() is the last value eval/call
computed. Also Y.symbols(), Y.test(name), Y.read(name). See `h Nobi.Repl`.
""")
