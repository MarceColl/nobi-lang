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

  test "start_error_message/2 names a taken port" do
    reason = {:kinoko, {:bad_return, {:shutdown, {:failed_to_start_child, :ranch, :eaddrinuse}}}}
    assert CLI.start_error_message({:error, reason}, 4123) =~ "port 4123 is in use"
    assert CLI.start_error_message({:error, :other}, 4123) =~ "could not start: :other"
  end

  test "a raise in the start is one line; the details only carry the stack" do
    failure =
      try do
        raise "no case clause matching:\n\n    {:error, :enotdir}\n"
      rescue
        e -> {:exception, e, __STACKTRACE__}
      end

    line = CLI.start_error_message(failure, 4123)

    assert line ==
             "kinoko: could not start: no case clause matching: {:error, :enotdir} " <>
               "(KINOKO_DEBUG=1 prints the full error)"

    refute line =~ "\n"
    assert CLI.start_error_details(failure) =~ "cli_side_effects_test.exs"

    assert CLI.start_error_message({:caught, :exit, :boom, []}, 4123) =~
             "could not start: exit :boom"

    huge = {:error, {:shutdown, Enum.to_list(1..10_000)}}
    assert String.length(CLI.start_error_message(huge, 4123)) < 400
  end

  test "debug?/1 is KINOKO_DEBUG=1" do
    assert CLI.debug?(%{"KINOKO_DEBUG" => "1"})
    refute CLI.debug?(%{"KINOKO_DEBUG" => "0"})
    refute CLI.debug?(%{})
  end
end
