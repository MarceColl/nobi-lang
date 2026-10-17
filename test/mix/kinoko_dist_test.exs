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
end
