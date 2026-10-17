defmodule Kinoko.CLISideEffectsTest do
  # Sets process-wide env vars (KINOKO_DATA, KINOKO_MODE), so not async.
  use ExUnit.Case, async: false

  alias Kinoko.CLI

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    data = Path.join(tmp, "fresh-data")
    vars = ~w(KINOKO_DATA KINOKO_MODE SECRET_KEY_BASE)
    previous = Map.new(vars, &{&1, System.get_env(&1)})

    System.put_env("KINOKO_DATA", data)
    System.delete_env("KINOKO_MODE")
    System.delete_env("SECRET_KEY_BASE")

    on_exit(fn ->
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    %{data: data}
  end

  test "the release's runtime config makes no secret and no data directory", %{data: data} do
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)

    refute Keyword.has_key?(config[:kinoko][KinokoWeb.Endpoint], :secret_key_base)
    assert config[:kinoko][Kinoko.Repo][:database] == Path.join(data, "kinoko.db")
    refute File.exists?(data)
  end

  test "version, mcp and uninstall create nothing", %{data: data} do
    for command <- [:version, :mcp, :uninstall] do
      assert is_binary(CLI.output(command))
    end

    refute File.exists?(data)
  end

  test "start_error_message/1 names a taken port" do
    reason = {:kinoko, {:bad_return, {:shutdown, {:failed_to_start_child, :ranch, :eaddrinuse}}}}
    assert CLI.start_error_message(reason, 4123) =~ "port 4123 is in use"
    assert CLI.start_error_message(:other, 4123) =~ "could not start"
  end
end
