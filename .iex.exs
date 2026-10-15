alias Kinoko.Repl, as: Y
alias Kinoko.{Lang, Exec}

IO.puts("""

Yabu REPL: Y.load("test/fixtures/yabu/counter.yabu"), then Y.eval("Counter.init()").
Y.last() is the last value eval/call computed. Also Y.symbols(), Y.test(name),
Y.read(name), Y.reset(). See `h Kinoko.Repl`.
""")
