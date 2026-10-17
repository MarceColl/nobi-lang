defmodule KinokoWeb.Mcp.Tools do
  @moduledoc """
  The MCP tools: each maps its arguments onto one `Kinoko.Universe`
  function and answers agent-readable text.

  Every tool but `guide`, `list_universes`, `create_universe` and
  `list_deployments` takes an optional `universe` (default `"main"`). `create_deployment` takes
  one too: a deployment serves one universe, and like every other tool it
  acts on main unless told otherwise. `list_deployments` lists them all,
  whatever universe each serves. The deployment tools go through
  `Kinoko.Deployment` (the table) and `Kinoko.Universe.routes/1` (whether the
  route table exists), never the database or a process.

  `call/2` answers `{:ok, %{content: [%{type: "text", text: ...}], isError: bool}}`,
  or `{:error, :unknown_tool}`. `isError` is true when the tool could not
  do what was asked: a missing or ill-typed argument, an unknown universe,
  an eval that fails, a test that fails. A patch that stays staged is NOT
  an error: the verdict is the answer, and it reads `staged: <id>` followed
  by one `- symbol [code] message` line per reason.
  """

  alias Kinoko.{Deployment, Exec, Universe}
  alias Kinoko.Lang.Format

  @default_universe "main"
  @name_rule "^[a-z0-9][a-z0-9_-]{0,62}$"

  # `Kinoko.Deployment.create/4`'s host refusals.
  @host_refusals [:bad_host, :reserved_host, :foreign_localhost, :host_taken]

  @universe_prop %{
    type: "string",
    description: "The universe to act on (default \"main\"). list_universes shows them."
  }

  @tools [
    {"guide",
     "The whole instructions: a worked app with every declaration form, events and forms, " <>
       "serving, stored data and the whole stdlib. Read it before your first patch: clients " <>
       "often show the server instructions cut short.", %{}, []},
    {"list_universes", "List every universe by name. Start here.", %{}, []},
    {"create_universe",
     "Create an empty universe to work in without touching \"main\". Names match #{@name_rule}.",
     %{name: %{type: "string", description: "The new universe's name."}}, ["name"]},
    {"stage_patch",
     "Stage a patch: Yabu source defining one or more declarations, under a patch id. " <>
       "It PROMOTES when the whole committed image still typechecks; otherwise it stays " <>
       "staged (inert) and the answer lists why. Restage the SAME id to fix it. " <>
       "A patch replaces each declaration it names whole.",
     %{
       id: %{
         type: "string",
         description: "Patch id. Restaging an id replaces what it staged before."
       },
       source: %{type: "string", description: "Yabu source: zero or more declarations."},
       remove: %{
         type: "array",
         items: %{type: "string"},
         description: "Fully qualified symbols this patch deletes."
       }
     }, ["id", "source"]},
    {"unstage", "Drop a staged patch by id.",
     %{id: %{type: "string", description: "The patch id."}}, ["id"]},
    {"list_staged",
     "Every staged (not promoted) patch with the reasons it cannot promote and its source.", %{},
     []},
    {"read", "The source of one declaration (committed, else staged). Read before you change it.",
     %{symbol: %{type: "string", description: "Fully qualified name, e.g. Counter.update."}},
     ["symbol"]},
    {"symbols", "The signature of every committed declaration.", %{}, []},
    {"eval",
     "Typecheck and evaluate a Yabu expression against the committed code (staged patches " <>
       "are not visible). Answers `value : type`.",
     %{expression: %{type: "string", description: "A Yabu expression, e.g. Counter.init()."}},
     ["expression"]},
    {"test", "Run one committed deftest.",
     %{symbol: %{type: "string", description: "The deftest's fully qualified name."}},
     ["symbol"]},
    {"history", "Every promotion, oldest first: the patch ids and the symbols each changed.", %{},
     []},
    {"health",
     "Whether the universe is healthy, or DEGRADED: its committed code no longer typechecks " <>
       "(the checker changed under it). A degraded universe reads and stages as ever, but " <>
       "eval and test refuse until a patch that makes the whole image typecheck promotes.", %{},
     []},
    {"list_deployments",
     "Every deployment (a served address of a universe's route table): its universe, route " <>
       "table, whether it follows the universe's head or is pinned, and its URLs.", %{}, []},
    {"create_deployment",
     "Serve a committed route table (a `defroutes`) of the universe at its own address: " <>
       "http://<name>.localhost:<port>/, plus any `hosts`. It follows the universe's head, so " <>
       "each promotion is live at once. `defroutes Main` is already served at " <>
       "http://localhost:<port>/ by the built-in `local` deployment.",
     %{
       name: %{
         type: "string",
         description:
           "The deployment's name, matching #{@name_rule}; it serves at <name>.localhost."
       },
       routes: %{
         type: "string",
         description: "The committed route table to serve, e.g. Forum.Routes or Main."
       },
       hosts: %{
         type: "array",
         items: %{type: "string"},
         description: "Extra host names that reach it (optional; <name>.localhost needs none)."
       }
     }, ["name", "routes"]}
  ]

  @no_universe ["guide", "list_universes", "create_universe", "list_deployments"]

  @doc "Every tool, as `tools/list` gives it."
  @spec list() :: [map()]
  def list do
    for {name, description, props, required} <- @tools do
      props = if name in @no_universe, do: props, else: Map.put(props, :universe, @universe_prop)
      schema = %{type: "object", properties: props}
      schema = if required == [], do: schema, else: Map.put(schema, :required, required)
      %{name: name, description: description, inputSchema: schema}
    end
  end

  @names Enum.map(@tools, &elem(&1, 0))

  @doc "Run tool `name`: `{:ok, result}` or `{:error, :unknown_tool}`."
  @spec call(String.t(), map()) :: {:ok, map()} | {:error, :unknown_tool}
  def call(name, args) when name in @names do
    result =
      case run(name, args) do
        {:ok, text} -> text_result(text, false)
        {:error, text} -> error_result(text)
      end

    {:ok, result}
  end

  def call(_name, _args), do: {:error, :unknown_tool}

  @doc "An `isError` tool result carrying `text`."
  @spec error_result(String.t()) :: map()
  def error_result(text), do: text_result(text, true)

  defp text_result(text, error?), do: %{content: [%{type: "text", text: text}], isError: error?}

  ## The tools

  defp run("guide", _args), do: {:ok, KinokoWeb.Mcp.Instructions.text()}

  defp run("list_universes", _args) do
    case Universe.list() do
      {:error, error} -> universe_error(error, nil)
      [] -> {:ok, "no universes"}
      universes -> {:ok, Enum.map_join(universes, "\n", &universe_line(&1.name))}
    end
  end

  defp run("create_universe", args) do
    with {:ok, name} <- string(args, "name") do
      case Universe.create(name) do
        :ok -> {:ok, "created: #{name}"}
        {:error, :exists} -> {:error, "universe #{name} already exists"}
        {:error, :bad_name} -> universe_error(:bad_name, name)
        {:error, error} -> universe_error(error, name)
      end
    end
  end

  defp run("stage_patch", args) do
    with {:ok, u} <- universe(args),
         {:ok, id} <- string(args, "id"),
         {:ok, source} <- string(args, "source"),
         {:ok, remove} <- strings(args, "remove") do
      case Universe.stage(u, id, source, remove: remove) do
        {:promoted, ids} -> {:ok, "promoted: " <> Enum.join(ids, ", ")}
        {:staged, reasons} -> {:ok, staged_text(id, reasons)}
        {:error, error} -> universe_error(error, u)
      end
    end
  end

  defp run("unstage", args) do
    with {:ok, u} <- universe(args), {:ok, id} <- string(args, "id") do
      case Universe.unstage(u, id) do
        :ok -> {:ok, "unstaged: #{id}"}
        :not_found -> {:error, "nothing staged under #{id}"}
        {:error, error} -> universe_error(error, u)
      end
    end
  end

  defp run("list_staged", args) do
    with {:ok, u} <- universe(args) do
      case Universe.staged(u) do
        {:error, error} -> universe_error(error, u)
        [] -> {:ok, "no staged patches"}
        patches -> {:ok, Enum.map_join(patches, "\n\n", &patch_text/1)}
      end
    end
  end

  defp run("read", args) do
    with {:ok, u} <- universe(args), {:ok, symbol} <- string(args, "symbol") do
      case Universe.read(u, symbol) do
        {:ok, text} -> {:ok, text}
        :error -> {:error, "no symbol named #{symbol} (committed or staged); see `symbols`"}
        {:error, error} -> universe_error(error, u)
      end
    end
  end

  defp run("symbols", args) do
    with {:ok, u} <- universe(args) do
      case Universe.symbols(u) do
        {:error, error} ->
          universe_error(error, u)

        [] ->
          {:ok, "no symbols (the universe is empty)"}

        symbols ->
          lines = Enum.map(symbols, &symbol_line/1)

          case Universe.health(u) do
            {:degraded, reasons} -> {:ok, Enum.join([degraded_line(reasons) | lines], "\n")}
            _ -> {:ok, Enum.join(lines, "\n")}
          end
      end
    end
  end

  defp run("eval", args) do
    with {:ok, u} <- universe(args), {:ok, expr} <- string(args, "expression") do
      case Universe.eval(u, expr) do
        {:ok, value, type} -> {:ok, "#{Exec.show(value, type)} : #{Format.type(type)}"}
        {:error, error} -> universe_error(error, u)
      end
    end
  end

  defp run("test", args) do
    with {:ok, u} <- universe(args), {:ok, symbol} <- string(args, "symbol") do
      case Universe.test(u, symbol) do
        :ok ->
          {:ok, "#{symbol}: ok"}

        {:error, %{failures: failures}} when is_list(failures) and failures != [] ->
          {:error, Enum.map_join(failures, "\n", &"#{symbol}: FAILED #{&1}")}

        {:error, error} ->
          universe_error(error, u)
      end
    end
  end

  defp run("history", args) do
    with {:ok, u} <- universe(args) do
      case Universe.history(u) do
        {:error, error} -> universe_error(error, u)
        [] -> {:ok, "no commits yet"}
        commits -> {:ok, commits |> Enum.with_index(1) |> Enum.map_join("\n", &commit_line/1)}
      end
    end
  end

  defp run("health", args) do
    with {:ok, u} <- universe(args) do
      case Universe.health(u) do
        :ok ->
          {:ok, "ok: #{u} is healthy (its committed code typechecks)"}

        {:degraded, reasons} ->
          {:ok,
           Enum.join(
             [
               "degraded: #{u}'s committed code no longer typechecks. Reading and staging " <>
                 "work; eval and test refuse until a patch that fixes every reason below " <>
                 "promotes (promotion checks the whole image)."
               | reason_lines(reasons)
             ],
             "\n"
           )}

        {:error, error} ->
          universe_error(error, u)
      end
    end
  end

  defp run("list_deployments", _args) do
    case Deployment.list() do
      [] -> {:ok, "no deployments"}
      deployments -> {:ok, Enum.map_join(deployments, "\n", &deployment_line/1)}
    end
  end

  defp run("create_deployment", args) do
    with {:ok, u} <- universe(args),
         {:ok, name} <- string(args, "name"),
         {:ok, routes} <- string(args, "routes"),
         {:ok, hosts} <- strings(args, "hosts"),
         :ok <- local_hosts(hosts),
         :ok <- route_table(u, routes) do
      case Deployment.create(name, u, routes, hosts: hosts) do
        :ok -> {:ok, created_text(name)}
        {:error, :exists} -> {:error, "deployment #{name} already exists (list_deployments)"}
        {:error, :bad_name} -> {:error, bad_deployment_name(name)}
        {:error, refused} when refused in @host_refusals -> {:error, host_refusal(refused, name)}
        {:error, :no_such_universe} -> universe_error(:no_such_universe, u)
        {:error, error} -> universe_error(error, u)
      end
    end
  end

  ## Deployments

  # The route table must be committed in the universe: a deployment of a
  # missing one serves nothing but an error page.
  defp route_table(u, routes) do
    case Universe.routes(u) do
      %{^routes => _} ->
        :ok

      tables when is_map(tables) ->
        committed =
          case tables |> Map.keys() |> Enum.sort() do
            [] -> "none"
            names -> Enum.join(names, ", ")
          end

        {:error,
         "no route table #{routes} in #{u}'s committed code (committed route tables: " <>
           "#{committed}). Define it with `defroutes #{routes} do \"/\" -> App end` " <>
           "(stage_patch; it must promote), then create the deployment."}

      {:error, error} ->
        universe_error(error, u)
    end
  end

  defp bad_deployment_name(name),
    do: "bad deployment name: #{Jason.encode!(name)} (names match #{@name_rule})"

  # A local build answers only on loopback names (KinokoWeb.LocalHost), so
  # any other host could never reach the deployment.
  defp local_hosts(hosts) do
    case {Application.get_env(:kinoko, :mode),
          Enum.reject(hosts, &KinokoWeb.LocalHost.local_host?(strip_port(&1)))} do
      {:local, [host | _]} ->
        {:error,
         "host #{Jason.encode!(host)} cannot be served: local mode serves only localhost " <>
           "names. Leave `hosts` out; the deployment is at http://<name>.localhost:#{port()}/."}

      _ ->
        :ok
    end
  end

  defp strip_port(host), do: String.replace(host, ~r/:\d+$/, "")

  defp host_refusal(:bad_host, _name),
    do:
      "a host is not a DNS name: each dot-separated label is a-z, 0-9 and inner '-', " <>
        "at most 63 characters (e.g. forum.example.com)"

  defp host_refusal(:reserved_host, name),
    do:
      "localhost, 127.0.0.1 and [::1] belong to the built-in `local` deployment " <>
        "(it serves `defroutes Main`). Leave them out: #{name} is at " <>
        "http://#{name}.localhost:#{port()}/."

  defp host_refusal(:foreign_localhost, name),
    do:
      "a *.localhost host other than #{name}.localhost belongs to another deployment " <>
        "(<x>.localhost is deployment x). Leave it out: #{name}.localhost needs no host, " <>
        "or name the deployment after the address you want."

  defp host_refusal(:host_taken, _name),
    do: "a host is already another deployment's (list_deployments shows whose); leave it out"

  defp created_text(name) do
    {:ok, d} = Deployment.get(name)

    urls =
      case urls(d) do
        [] -> ["no URL: this server does not serve <name>.localhost and it has no hosts"]
        [url | more] -> ["URL: #{url}" | Enum.map(more, &"also: #{&1}")]
      end

    Enum.join(
      [
        "created: deployment #{name} serves route table #{d.routes} of universe #{d.universe}, " <>
          "following its head (each promotion is live at once)."
        | urls
      ],
      "\n"
    )
  end

  defp deployment_line(d) do
    head = if d.commit, do: "pinned to commit #{d.commit}", else: "follows head"
    "#{d.name}: universe #{d.universe}, routes #{d.routes}, #{head}; #{Enum.join(urls(d), " ")}"
  end

  # `<name>.localhost` only where it reaches the deployment, then its hosts.
  defp urls(d) do
    own = if Deployment.localhost_deployments?(), do: [d.name <> ".localhost"], else: []
    Enum.map(own ++ d.hosts, &host_url/1)
  end

  defp host_url(host), do: "http://#{host}:#{port()}/"

  @doc "The port the endpoint listens on, as the deployment URLs give it."
  @spec port() :: :inet.port_number()
  def port do
    case KinokoWeb.Endpoint.config(:http)[:port] do
      port when is_integer(port) -> port
      _ -> URI.parse(KinokoWeb.Endpoint.url()).port
    end
  end

  ## Text

  # A universe's name, and why it is not healthy when it is not.
  defp universe_line(name) do
    case Universe.health(name) do
      {:degraded, reasons} ->
        "#{name} (DEGRADED: #{failing(reasons)} no longer typecheck; see health)"

      {:error, %{code: code}} ->
        "#{name} (cannot open: [#{code}]; see health)"

      _ ->
        name
    end
  end

  defp degraded_line(reasons),
    do:
      "DEGRADED: #{failing(reasons)} no longer typecheck, so eval and test refuse " <>
        "until a fix promotes (see health)."

  defp failing(reasons) do
    reasons
    |> Enum.map(&Map.get(&1, :name))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp staged_text(id, reasons) do
    Enum.join(
      ["staged: #{id} (not promoted; fix the reasons and restage #{id})" | reason_lines(reasons)],
      "\n"
    )
  end

  # Each reason said once: a check can find the same fault twice (say, two
  # branches updating the same missing field).
  defp reason_lines(reasons) do
    reasons
    |> Enum.uniq_by(&{Map.get(&1, :name), &1.code, &1.message})
    |> Enum.map(&"- #{Map.get(&1, :name) || "(patch)"} [#{&1.code}] #{&1.message}")
  end

  defp patch_text(%{id: id, source: source, removes: removes, reasons: reasons}) do
    head = if removes == [], do: id, else: "#{id} (removes: #{Enum.join(removes, ", ")})"

    reasons =
      if reasons == [], do: ["- (no reasons: waiting to promote)"], else: reason_lines(reasons)

    source = if source == "", do: [], else: ["source:", indent(source)]
    Enum.join([head | reasons] ++ source, "\n")
  end

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  defp symbol_line(%{symbol: name, signature: sig}),
    do: if(String.starts_with?(sig, name), do: sig, else: "#{name} : #{sig}")

  defp commit_line({%{ids: ids, entries: entries}, n}) do
    live = for {:live, symbol, _cid} <- entries, do: symbol
    gone = for {:gone, symbol} <- entries, do: symbol

    parts =
      [Enum.join(live, ", "), gone != [] && "removed: " <> Enum.join(gone, ", ")]
      |> Enum.filter(&(&1 not in [false, ""]))

    "#{n}. #{Enum.join(ids, ", ")}: #{Enum.join(parts, "; ")}"
  end

  ## Errors

  defp universe_error(:no_such_universe, u),
    do:
      {:error,
       "no such universe: #{u} (list_universes shows them; create_universe makes a new one)"}

  defp universe_error(:bad_name, u),
    do: {:error, "bad universe name: #{inspect(u)} (names match #{@name_rule})"}

  # The reasons only where they say more than the message (the message is
  # the first reason's): each said once, and none that repeats the message.
  defp universe_error(%{code: code, message: message} = error, _u) do
    reasons =
      error
      |> Map.get(:reasons, [])
      |> Enum.uniq_by(&{&1.code, &1.message})
      |> Enum.reject(&(&1.code == code and &1.message == message))
      |> reason_lines()

    {:error, Enum.join(["error: [#{code}] #{message}" | reasons], "\n")}
  end

  ## Arguments

  defp universe(args) do
    case Map.get(args, "universe") do
      nil -> {:ok, @default_universe}
      u when is_binary(u) -> {:ok, u}
      other -> {:error, "argument `universe` must be a string, not #{Jason.encode!(other)}"}
    end
  end

  defp string(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, other} -> {:error, "argument `#{key}` must be a string, not #{Jason.encode!(other)}"}
      :error -> {:error, "missing required argument `#{key}` (a string)"}
    end
  end

  defp strings(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, "argument `#{key}` must be an array of strings"}

      other ->
        {:error, "argument `#{key}` must be an array of strings, not #{Jason.encode!(other)}"}
    end
  end
end
