defmodule Kinoko.ExecGoldenTest do
  # Every answer TS gave, asked again of compiled Yabu on the BEAM: the
  # golden calls and app traces, compared by value with TS's (decoded by the
  # declared type, `YabuGolden.decode/3`), and the corpus's deftests scored.
  # Ported from kinoko-next `tests/golden.rs` ("every answer TS gave" and the
  # harvest pins). The stdlib examples are `exec/stdlib_test.exs`'s.
  #
  # Each program is staged and loaded once, and its image reused for every
  # call. Images are distinct per program and never unloaded here, so this
  # module can run beside others.
  use ExUnit.Case, async: true

  alias Kinoko.Exec
  alias Kinoko.Lang

  # Error messages TS's interpreter is known to fail with, besides "division
  # by zero" (which `expected/1` treats as a real answer): Split's and
  # Notes' `Cmd` carries a function (the store callback), which the
  # interpreter cannot represent as a value. (golden.rs
  # KNOWN_INTERPRETER_FAILURES)
  @known_interpreter_failures ["a function escaped into value position"]

  # A golden call or step runs in well under this; a runaway one is a bug.
  @opts [timeout: 2_000]

  # --- loading ---------------------------------------------------------------

  # A golden program, checked and loaded: its image, the signatures TS's
  # answers decode by, and its deftests' names.
  defp load(label, source) do
    {u, r} = Lang.stage(Lang.new(), "golden", source)
    assert {:promoted, _} = r, "#{label}: #{inspect(r, limit: 5)}"
    assert {:ok, image} = Exec.load(Lang.snapshot(u)), label
    %{image: image, sigs: YabuGolden.signatures(source), tests: Map.keys(image.tests)}
  end

  defp corpus_run(file), do: load(file, YabuOracle.corpus_source(file))

  defp generated_runs do
    for p <- YabuGolden.generated() do
      label = "generated (seed #{p["seed"]})"
      {label, load(label, p["source"]), p}
    end
  end

  # --- TS's answers ------------------------------------------------------------

  # What the BEAM must give: `{:ok, json}`, `{:error, "division by zero"}`,
  # or nil where TS had no answer.
  defp expected(%{"value" => json}), do: {:ok, json}
  defp expected(%{"error" => "division by zero" = e}), do: {:error, e}
  defp expected(%{"error" => _}), do: nil

  # --- the tally ---------------------------------------------------------------

  defp tally, do: %{compared: %{}, skipped: %{}, mismatches: [], repeated: []}

  defp bump(t, which, kind), do: update_in(t, [which, kind], &((&1 || 0) + 1))

  defp mismatch(t, site, why), do: %{t | mismatches: ["#{site}\n  #{why}" | t.mismatches]}

  # The BEAM's answer `got` against TS's `answer` at `site`: the same value,
  # closures compared as the lambda marker, or both division by zero. Where
  # TS had no answer the BEAM's is not compared, but it must have one.
  defp check(t, kind, site, sigs, answer, type, got) do
    case expected(answer) do
      nil ->
        t = bump(t, :skipped, kind)

        case got do
          {:ok, _} ->
            t

          {:error, e} ->
            mismatch(t, site, "TS had no answer, and the BEAM has none either: #{inspect(e)}")
        end

      want ->
        t = bump(t, :compared, kind)

        t = %{
          t
          | repeated: Enum.map(repeated_maps(answer["value"]), &"#{site}: #{&1}") ++ t.repeated
        }

        case differs(want, type, sigs, got) do
          nil ->
            t

          why ->
            mismatch(
              t,
              site,
              "#{why}\n  TS:   #{inspect(answer)}\n  BEAM: #{inspect(got, limit: :infinity)}"
            )
        end
    end
  end

  defp differs({:ok, json}, type, sigs, {:ok, got}) do
    case YabuGolden.decode(json, type, sigs) do
      {:ok, want} ->
        if YabuGolden.without_closures(got) == want,
          do: nil,
          else: "differs (decoded TS: #{inspect(want, limit: :infinity)})"

      {:error, why} ->
        "TS's answer does not decode: #{why}"
    end
  end

  defp differs({:error, _}, _, _, {:error, %{code: "runtime", message: m}}) do
    if m =~ "division by zero", do: nil, else: "a different error"
  end

  defp differs(_, _, _, _), do: "one answered and the other failed"

  # Every `$map` in `json` whose keys repeat: there the last value wins, as in
  # Rust, which changes TS's answer. (Rust's decoder reports these; the key
  # JSON is the key's spelling, the same whichever type decodes it.)
  defp repeated_maps(json) do
    case json do
      %{"$map" => pairs} = m when map_size(m) == 1 and is_list(pairs) ->
        keys = Enum.map(pairs, fn [k, _] -> k end)
        here = if Enum.uniq(keys) != keys, do: [JSON.encode!(json)], else: []
        here ++ Enum.flat_map(pairs, &repeated_maps/1)

      %{} = m ->
        m |> Map.values() |> Enum.flat_map(&repeated_maps/1)

      xs when is_list(xs) ->
        Enum.flat_map(xs, &repeated_maps/1)

      _ ->
        []
    end
  end

  # Fails listing every mismatch, else unless exactly `counts` (per kind:
  # compared, skipped) and exactly `repeated` answers held a repeated map key.
  defp finish(t, what, counts, repeated) do
    kinds = Enum.uniq(Map.keys(t.compared) ++ Map.keys(t.skipped)) |> Enum.sort()
    got = for k <- kinds, do: {k, Map.get(t.compared, k, 0), Map.get(t.skipped, k, 0)}

    if t.mismatches != [] do
      all = t.mismatches |> Enum.reverse() |> Enum.join("\n\n")

      flunk(
        "#{length(t.mismatches)} of #{what} differ from TS's ((kind, compared, skipped): #{inspect(got)}):\n\n#{all}"
      )
    end

    want = counts |> Enum.filter(fn {_, c, s} -> c + s > 0 end) |> Enum.sort()
    assert got == want, "#{what}: (kind, compared, skipped)"

    assert length(t.repeated) == repeated,
           "#{what}: answers with a repeated map key:\n#{Enum.join(t.repeated, "\n")}"
  end

  # --- calls and traces --------------------------------------------------------

  defp call(run, name, args), do: Exec.call(run.image, name, args, @opts)

  # Each call: the def applied to TS's arguments (decoded by its parameters'
  # types) against TS's answer (by its return type).
  defp calls(t, run, label, calls) do
    Enum.reduce(calls, t, fn c, t ->
      site = "#{label}: #{c["name"]}(#{Enum.map_join(c["args"], ", ", &JSON.encode!/1)})"
      {params, ret} = YabuGolden.def_signature(run.sigs, c["name"])

      assert length(c["args"]) == length(params),
             "#{site}: TS's arguments, against the def's parameters"

      decoded = Enum.zip_with(c["args"], params, &YabuGolden.decode(&1, &2, run.sigs))

      case Enum.find(decoded, &match?({:error, _}, &1)) do
        nil ->
          args = Enum.map(decoded, fn {:ok, v} -> v end)
          check(t, "calls", site, run.sigs, c["answer"], ret, call(run, c["name"], args))

        {:error, why} ->
          mismatch(t, site, "TS's arguments do not decode: #{why}")
      end
    end)
  end

  # One app's trace: `init`; `view` of its model; `update` of that model with
  # each argument-free message; then the scripted steps, each updating the
  # model TS's step before answered (decoded), so a mismatch does not hide
  # what follows.
  defp trace(t, run, label, tr) do
    app = tr["app"]
    [init, view, update] = Enum.map(~w(init view update), &"#{app}.#{&1}")
    {_, init_ty} = YabuGolden.def_signature(run.sigs, init)

    t =
      check(t, "init", "#{label}: #{init}()", run.sigs, tr["init"], init_ty, call(run, init, []))

    case model_of(run.sigs, tr["init"], init_ty) do
      nil ->
        t

      model ->
        t =
          case tr["view"] do
            nil ->
              t

            answer ->
              {_, ty} = YabuGolden.def_signature(run.sigs, view)
              site = "#{label}: #{view}(init's model)"
              check(t, "view", site, run.sigs, answer, ty, call(run, view, [model]))
          end

        {[msg_ty, _], ty} = YabuGolden.def_signature(run.sigs, update)

        step = fn t, kind, site, s, model ->
          case YabuGolden.decode(s["msg"], msg_ty, run.sigs) do
            {:ok, msg} ->
              check(t, kind, site, run.sigs, s["answer"], ty, call(run, update, [msg, model]))

            {:error, why} ->
              mismatch(t, site, "TS's message does not decode: #{why}")
          end
        end

        t =
          Enum.reduce(tr["updates"] || [], t, fn u, t ->
            step.(
              t,
              "updates",
              "#{label}: #{update}(#{JSON.encode!(u["msg"])}, init's model)",
              u,
              model
            )
          end)

        (tr["steps"] || [])
        |> Enum.with_index(1)
        |> Enum.reduce_while({t, model}, fn {s, i}, {t, model} ->
          site = "#{label}: step #{i}: #{update}(#{JSON.encode!(s["msg"])}, the model before)"
          t = step.(t, "steps", site, s, model)

          case model_of(run.sigs, s["answer"], ty) do
            nil -> {:halt, {t, model}}
            next -> {:cont, {t, next}}
          end
        end)
        |> elem(0)
    end
  end

  # The model of TS's answer `(model, cmd)`, decoded, if TS answered with one.
  defp model_of(sigs, answer, {:tuple, [model_ty | _]}) do
    with {:ok, %{"$tup" => [json | _]}} <- expected(answer),
         {:ok, model} <- YabuGolden.decode(json, model_ty, sigs),
         do: model,
         else: (_ -> nil)
  end

  defp model_of(_, _, _), do: nil

  # --- every answer TS gave ----------------------------------------------------

  describe "every answer TS gave" do
    test "every generated call and trace answers as in TS" do
      runs = generated_runs()

      calls =
        Enum.reduce(runs, tally(), fn {label, run, p}, t -> calls(t, run, label, p["calls"]) end)

      finish(calls, "the generated calls", [{"calls", 824, 0}], 7)

      traces =
        Enum.reduce(runs, tally(), fn {label, run, p}, t ->
          Enum.reduce(p["traces"], t, &trace(&2, run, label, &1))
        end)

      counts = [{"init", 100, 0}, {"view", 98, 0}, {"updates", 98, 0}, {"steps", 0, 0}]
      finish(traces, "the generated traces' answers", counts, 5)
    end

    # TS's interpreter had no answer for two corpus calls: Notes' and
    # Split's, whose `Cmd` holds a function. The BEAM has one for each;
    # Split's `init` is compared through its trace, which TS's compiler
    # answered.
    test "every corpus call and trace answers as in TS" do
      corpus = for f <- YabuGolden.corpus(), do: {f, corpus_run(f["file"])}

      calls =
        Enum.reduce(corpus, tally(), fn {f, run}, t -> calls(t, run, f["file"], f["calls"]) end)

      finish(calls, "the corpus calls", [{"calls", 20, 2}], 0)

      traces =
        Enum.reduce(corpus, tally(), fn {f, run}, t ->
          Enum.reduce(f["traces"], t, &trace(&2, run, f["file"], &1))
        end)

      counts = [{"init", 4, 0}, {"view", 4, 0}, {"updates", 5, 0}, {"steps", 19, 0}]
      finish(traces, "the corpus traces' answers", counts, 0)
    end

    test "every corpus deftest scores as in TS" do
      ran =
        for f <- YabuGolden.corpus(), reduce: 0 do
          ran ->
            run = corpus_run(f["file"])

            assert Enum.sort(run.tests) == Enum.sort(Map.keys(f["tests"])),
                   "#{f["file"]}: the deftests TS ran"

            for {name, failures} <- f["tests"], reduce: ran do
              ran ->
                assert score(run, name) == failures, "#{f["file"]}: #{name}"
                ran + 1
            end
        end

      assert ran == 3, "corpus deftests"
    end

    test "a corpus deftest made to fail fails (the control)" do
      source = YabuOracle.corpus_source("split.yabu")

      {held, broken} =
        {~s|always(Split.money(0) == "0.00")|, ~s|always(Split.money(0) == "0.01")|}

      assert source =~ held, "split.yabu: no `#{held}` to break"
      run = load("split.yabu, broken", String.replace(source, held, broken))

      assert score(run, "Split.money_prints_cents") ==
               [~s|always failed: Split.money(0) == "0.01"|]
    end
  end

  defp score(run, name) do
    case Exec.test(run.image, name, @opts) do
      :ok -> []
      {:error, %{code: "test", failures: failures}} -> failures
      {:error, e} -> flunk("#{name}: #{inspect(e)}")
    end
  end

  # --- the harvest -------------------------------------------------------------

  # Every `$v` name, every error message, and every `$fn` value (with the
  # `by` of the trace it came from, nil for a call) in every answer and every
  # call's arguments, across the corpus and the generated programs.
  defp harvest do
    programs = YabuGolden.corpus() ++ YabuGolden.generated()

    Enum.reduce(programs, %{errors: [], names: [], fns: []}, fn p, h ->
      h =
        Enum.reduce(p["calls"], h, fn c, h ->
          h = Enum.reduce(c["args"], h, &walk_value(&1, &2, nil))
          walk_answer(c["answer"], h, nil)
        end)

      Enum.reduce(p["traces"], h, fn tr, h ->
        by = tr["by"] || ""
        h = walk_answer(tr["init"], h, by)
        h = if tr["view"], do: walk_answer(tr["view"], h, by), else: h

        Enum.reduce((tr["updates"] || []) ++ (tr["steps"] || []), h, fn u, h ->
          h = walk_value(u["msg"], h, by)
          walk_answer(u["answer"], h, by)
        end)
      end)
    end)
  end

  defp walk_answer(%{"value" => v}, h, by), do: walk_value(v, h, by)
  defp walk_answer(%{"error" => e}, h, _), do: %{h | errors: [e | h.errors]}

  defp walk_value(xs, h, by) when is_list(xs), do: Enum.reduce(xs, h, &walk_value(&1, &2, by))

  defp walk_value(%{} = m, h, by) do
    h = if is_binary(m["$v"]), do: %{h | names: [m["$v"] | h.names]}, else: h
    h = if is_binary(m["$fn"]), do: %{h | fns: [{m["$fn"], by} | h.fns]}, else: h
    m |> Map.values() |> Enum.reduce(h, &walk_value(&1, &2, by))
  end

  defp walk_value(_, h, _), do: h

  describe "the harvest" do
    test "every interpreter failure is pinned or division by zero" do
      %{errors: errors} = harvest()
      assert errors != [], "the corpus and generated programs hold error answers"

      for e <- errors do
        assert e == "division by zero" or e in @known_interpreter_failures,
               "unpinned interpreter failure (not in @known_interpreter_failures): #{e}"
      end
    end

    test "every variant name ends in an uppercase segment" do
      %{names: names} = harvest()
      assert names != []

      for name <- names do
        last = name |> String.split(".") |> List.last()

        assert last =~ ~r/\A[A-Z]/,
               "#{name}: a lowercase last segment (a stdlib fn made a variant)"
      end
    end

    test "every fn value is a name or the lambda marker" do
      %{fns: fns} = harvest()
      assert fns != []

      for {name, by} <- fns do
        assert name =~ "." or name == "<lambda>",
               "#{name}: neither a dotted name nor \"<lambda>\""

        if name == "<lambda>",
          do: assert(by == "compiler", "\"<lambda>\" outside a compiler trace")
      end
    end
  end
end
