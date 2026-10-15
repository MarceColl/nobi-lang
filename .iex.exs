alias Kinoko.Repl, as: Y
alias Kinoko.{Lang, Exec}

IO.puts("""

Yabu REPL: Y.load("test/fixtures/yabu/counter.yabu"), then Y.eval("Counter.init()").
Also Y.symbols(), Y.test(name), Y.read(name), Y.reset(). See `h Kinoko.Repl`.
""")
