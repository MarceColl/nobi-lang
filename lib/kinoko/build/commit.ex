defmodule Kinoko.Build.Commit do
  @moduledoc """
  Reads the commit the source tree is at, for `Kinoko.Build` to stamp at
  compile time: `KINOKO_COMMIT` if set, else the last non-empty jj commit,
  else git's `HEAD`, else `"unknown"`.
  """

  @doc "The current commit's short id, or `\"unknown\"`."
  @spec read() :: String.t()
  def read do
    System.get_env("KINOKO_COMMIT") || jj_commit() || git_commit() || "unknown"
  end

  defp jj_commit do
    run("jj", [
      "log",
      "--ignore-working-copy",
      "--no-graph",
      "-r",
      "heads(::@ ~ empty())",
      "-T",
      "commit_id.short(12)"
    ])
  end

  defp git_commit, do: run("git", ["rev-parse", "--short=12", "HEAD"])

  defp run(cmd, args) do
    with path when is_binary(path) <- System.find_executable(cmd),
         {out, 0} <- System.cmd(path, args, stderr_to_stdout: true),
         id when id != "" <- String.trim(out) do
      id
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
