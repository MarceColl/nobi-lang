defmodule Mix.Tasks.Kinoko.DistTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kinoko.Dist

  test "erts_pin/4: pinned tarballs for OTP 28.1.1 / ERTS 16.1.1" do
    assert {:ok, {"OTP-28.1.1/macos/universal/" <> _, sha}} =
             Dist.erts_pin("28.1.1", "16.1.1", :darwin, :aarch64)

    assert byte_size(sha) == 64

    assert {:ok, {"OTP-28.1.1/linux/aarch64/" <> _, _}} =
             Dist.erts_pin("28.1.1", "16.1.1", :linux, :aarch64)
  end

  test "erts_pin/4: an unpinned version fails closed and says how to re-pin" do
    assert {:error, message} = Dist.erts_pin("28.2", "16.2", :linux, :x86_64)
    assert message =~ "no pinned ERTS for OTP 28.2"
    assert message =~ "@erts_pins"
    assert message =~ "shasum -a 256"
  end

  @tag :tmp_dir
  test "verified?/2 compares the file's sha256", %{tmp_dir: dir} do
    path = Path.join(dir, "f")
    File.write!(path, "abc")
    sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    assert Dist.verified?(path, sha)
    refute Dist.verified?(path, String.duplicate("0", 64))
  end

  test "binary_name/1" do
    assert Dist.binary_name(:macos_x86_64) == "kinoko-macos-x86_64"
    assert Dist.binary_name(:linux_arm64) == "kinoko-linux-arm64"
  end

  test "check_commit!/1 refuses a build with no commit id" do
    assert Dist.check_commit!("01d4483c0ffe") == "01d4483c0ffe"
    assert_raise Mix.Error, ~r/cannot tell which commit/, fn -> Dist.check_commit!("unknown") end
    assert_raise Mix.Error, ~r/KINOKO_COMMIT/, fn -> Dist.check_commit!("") end
  end

  @tag :tmp_dir
  test "patch_burrito!/1 patches the upstream wrapper once, and refuses any other", %{
    tmp_dir: dir
  } do
    src = Path.join(dir, "src")
    File.mkdir_p!(src)
    wrapper = Path.join(src, "wrapper.zig")
    File.cp!(Path.join(Mix.Project.deps_paths().burrito, "src/wrapper.zig"), wrapper)
    patch = Path.expand("../../patches/burrito-musl-runtime.patch", __DIR__)

    # Start from upstream, whichever state deps/burrito is in.
    System.cmd("patch", ["-p1", "-R", "-N", "-s", "-d", dir, "-i", patch])
    upstream = File.read!(wrapper)
    refute upstream =~ "Kinoko patch"

    ExUnit.CaptureIO.capture_io(fn -> assert Dist.patch_burrito!(dir) == :ok end)
    patched = File.read!(wrapper)
    assert patched =~ "Kinoko patch"
    assert patched =~ "fn musl_state("

    # Applied already: left as is.
    assert Dist.patch_burrito!(dir) == :ok
    assert File.read!(wrapper) == patched

    File.write!(wrapper, upstream <> "// changed\n")
    assert_raise Mix.Error, ~r/neither Burrito 1.6.0's/, fn -> Dist.patch_burrito!(dir) end
  end
end
