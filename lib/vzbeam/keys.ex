defmodule VzBeam.Keys do
  @moduledoc "Baked SSH keypair at $VZBEAM_HOME/keys/id_ed25519[.pub], generated lazily on first need."
  alias VzBeam.Home

  @spec dir() :: Path.t()
  def dir, do: Path.join(Home.root(), "keys")

  @spec private() :: Path.t()
  def private, do: Path.join(dir(), "id_ed25519")

  @spec public() :: Path.t()
  def public, do: private() <> ".pub"

  @spec ensure((String.t(), [String.t()], keyword -> {String.t(), non_neg_integer})) ::
          {:ok, %{private: Path.t(), public: Path.t()}} | {:error, term}
  def ensure(runner \\ &System.cmd/3) do
    if File.regular?(private()) do
      {:ok, %{private: private(), public: public()}}
    else
      File.mkdir_p!(dir())

      case runner.("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "vzbeam", "-f", private()], stderr_to_stdout: true) do
        {_, 0} -> {:ok, %{private: private(), public: public()}}
        {out, _} -> {:error, {:keygen_failed, String.trim(out)}}
      end
    end
  end
end
