defmodule Nobi.WasmFixture do
  @moduledoc """
  The `echo.wat` test module (`test/fixtures/wasm/echo.wat`), stored, and a
  Nobi app that calls it with `Cmd.wasm.call`: `init` echoes a JSON run
  result (run 1), `Start` loops (call, decode the `Float`, re-arm with
  `Cmd.time.after`) until run 4, `Call(export)` calls any export, `Burst`
  starts five `spin`s at once, and `Click` only counts.
  """

  @doc "Stores `echo.wat` and answers its hash."
  def put! do
    {:ok, bytes} = Wasmex.Wat.to_wasm(File.read!("test/fixtures/wasm/echo.wat"))
    {:ok, hash, _} = Nobi.Wasm.put(bytes)
    hash
  end

  @doc "The app, calling the module `hash`, routed at `/` by `W.Routes`."
  def app(hash) do
    ~s'''
    defmodel W.Sim do
      dps : Float
    end

    defmodel W.Model do
      out : String
      dps : Float
      runs : Int
      looping : Bool
      clicks : Int
      errs : List<String>
    end

    deftype W.Msg do
      Start | Call(String) | Got(Result<String, String>) | Click | Burst
    end

    def W.mod() : String do
      "#{hash}"
    end

    def W.init() : (W.Model, Cmd<W.Msg>) do
      (%W.Model{out: "", dps: 0.0, runs: 0, looping: false, clicks: 0, errs: []}, Cmd.wasm.call(W.mod(), "echo", "{\\"dps\\": 7.25}", W.Msg.Got))
    end

    def W.dps(text : String) : Float do
      case (JSON.parse(text) : Result<W.Sim, String>) do
        Result.Ok(sim) -> sim.dps
        Result.Err(_) -> -1.0
      end
    end

    def W.got(r : Result<String, String>, model : W.Model) : (W.Model, Cmd<W.Msg>) do
      case r do
        Result.Ok(text) -> (%W.Model{model | out: text, dps: W.dps(text) * 1.0, runs: model.runs + 1}, if model.looping and model.runs + 1 < 4 do Cmd.time.after(10, W.Msg.Start) else Cmd.none() end)
        Result.Err(why) -> (%W.Model{model | out: String.concat("Err: ", why), errs: List.append(model.errs, why)}, Cmd.none())
      end
    end

    def W.update(msg : W.Msg, model : W.Model) : (W.Model, Cmd<W.Msg>) do
      case msg do
        W.Msg.Start -> (%W.Model{model | looping: true}, Cmd.wasm.call(W.mod(), "echo", "{\\"dps\\": 1234.5}", W.Msg.Got))
        W.Msg.Call(export) -> (model, Cmd.wasm.call(W.mod(), export, "{\\"dps\\": 1.5}", W.Msg.Got))
        W.Msg.Got(r) -> W.got(r, model)
        W.Msg.Click -> (%W.Model{model | clicks: model.clicks + 1}, Cmd.none())
        W.Msg.Burst -> (model, Cmd.batch(List.map([1, 2, 3, 4, 5], fn (i : Int) -> Cmd.wasm.call(W.mod(), "spin", "x", W.Msg.Got) end)))
      end
    end

    def W.view(model : W.Model) : Html<W.Msg> do
      <main>
        <p id="out">{model.out}</p>
        <p id="dps">{model.dps}</p>
        <p id="runs">{model.runs}</p>
        <p id="clicks">{model.clicks}</p>
        <p id="errs">{String.join(model.errs, ";")}</p>
        <button id="start" on-click={W.Msg.Start}>start</button>
        <button id="spin" on-click={W.Msg.Call("spin")}>spin</button>
        <button id="click" on-click={W.Msg.Click}>click</button>
        <button id="burst" on-click={W.Msg.Burst}>burst</button>
      </main>
    end

    defapp W

    defroutes W.Routes do
      "/" -> W
    end
    '''
  end
end
