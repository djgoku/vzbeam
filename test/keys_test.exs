defmodule VzBeam.KeysTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "vzbeam-keys-#{System.unique_integer([:positive])}")
    System.put_env("VZBEAM_HOME", home)
    on_exit(fn -> System.delete_env("VZBEAM_HOME"); File.rm_rf!(home) end)
    :ok
  end

  test "generates an ed25519 keypair, idempotently" do
    assert {:ok, %{private: priv, public: pub}} = VzBeam.Keys.ensure()
    assert File.regular?(priv) and File.regular?(pub)
    assert File.read!(pub) =~ "ssh-ed25519"
    before = File.read!(priv)
    assert {:ok, _} = VzBeam.Keys.ensure()
    assert File.read!(priv) == before
  end
end
