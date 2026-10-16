defmodule Kinoko.Data.HooksTest do
  use ExUnit.Case, async: true

  alias Kinoko.Data.Hooks

  @outside {:yabu_error, "store handle used outside its transaction"}

  # A coordinator that answers one read with `reply`, after reporting it.
  defp coordinator(reply) do
    test = self()

    spawn_link(fn ->
      receive do
        {:kinoko_store_read, ref, from, op} ->
          send(test, {:asked, ref, from, op})
          if reply != :silent, do: send(from, {:kinoko_store_reply, ref, reply})
          Process.sleep(:infinity)
      end
    end)
  end

  test "store_get sends the read with the handle's ref and returns the reply" do
    ref = make_ref()
    pid = coordinator({:ok, {:var, "Option", "None", []}})
    me = self()

    assert Hooks.store_get({:store, pid, ref}, "A.Post", {:uuid, "x"}) ==
             {:var, "Option", "None", []}

    assert_received {:asked, ^ref, ^me, {:get, "A.Post", {:uuid, "x"}}}
  end

  test "store_list sends the read and returns the rows" do
    ref = make_ref()
    pid = coordinator({:ok, []})
    assert Hooks.store_list({:store, pid, ref}, "A.Post") == []
    assert_received {:asked, ^ref, _, {:list, "A.Post"}}
  end

  test "an error reply is a Yabu runtime error" do
    pid = coordinator({:error, "too-many-rows"})

    assert catch_throw(Hooks.store_list({:store, pid, make_ref()}, "A.Post")) ==
             {:yabu_error, "too-many-rows"}
  end

  test "a closed or dead coordinator: the handle is used outside its transaction" do
    pid = coordinator(:closed)
    assert catch_throw(Hooks.store_list({:store, pid, make_ref()}, "A.Post")) == @outside

    dead = spawn(fn -> :ok end)
    mon = Process.monitor(dead)
    assert_receive {:DOWN, ^mon, _, _, _}

    assert catch_throw(Hooks.store_get({:store, dead, make_ref()}, "A.Post", {:uuid, "x"})) ==
             @outside

    refute_received {:DOWN, _, _, _, _}
  end

  test "a coordinator that never answers times out as a Yabu runtime error" do
    pid = coordinator(:silent)

    assert {:yabu_error, message} =
             catch_throw(Hooks.request({:store, pid, make_ref()}, {:list, "A.Post"}, 20))

    assert message =~ "timed out"
  end

  test "a reply to another handle is not taken" do
    ref = make_ref()
    send(self(), {:kinoko_store_reply, make_ref(), {:ok, :stale}})
    pid = coordinator({:ok, []})
    assert Hooks.store_list({:store, pid, ref}, "A.Post") == []
  end

  test "something not a handle is a Yabu runtime error" do
    assert {:yabu_error, _} = catch_throw(Hooks.store_list(:nope, "A.Post"))
  end

  test "an answer of the wrong shape is a Yabu runtime error, not a crash" do
    pid = coordinator(:what)
    assert {:yabu_error, _} = catch_throw(Hooks.store_list({:store, pid, make_ref()}, "A.Post"))
  end
end
