defmodule VzBeam.Commands.ImagesTest do
  use ExUnit.Case, async: true
  alias VzBeam.Commands.Images

  @cached %{"version" => "26.5.1", "build" => "25F80", "bytes" => 16 * 1024 * 1024 * 1024, "source" => "latest"}
  @offered [%{"version" => "26.6.1", "build" => "25G76", "url" => "https://u/a.ipsw"},
            %{"version" => "26.5.1", "build" => "25F80", "url" => "https://u/b.ipsw"}]

  defp deps(overrides \\ %{}) do
    Map.merge(
      %{list: fn -> [@cached] end,
        remote: fn -> {:ok, @offered} end,
        warn: fn _ -> flunk("no warning expected") end},
      overrides
    )
  end

  test "merges cached and Apple-offered rows, labeled local/remote, newest first" do
    assert {:ok, out} = Images.run([], deps())
    text = IO.iodata_to_binary(out)
    assert text =~ ~r/VERSION\s+BUILD\s+SIZE\s+STATUS/
    assert text =~ ~r/26\.6\.1\s+25G76\s+-\s+remote/
    assert text =~ ~r/26\.5\.1\s+25F80\s+16G\s+local/
    # newest (remote) row sorts above the cached one
    assert :binary.match(text, "25G76") < :binary.match(text, "25F80")
  end

  test "a build both cached and offered appears once, as local" do
    assert {:ok, out} = Images.run([], deps())
    text = IO.iodata_to_binary(out)
    assert length(String.split(text, "25F80")) == 2  # exactly one occurrence
    refute text =~ ~r/25F80\s+-\s+remote/
  end

  test "an unreachable catalog degrades to cached-only with a note, exit 0" do
    me = self()

    deps = deps(%{remote: fn -> {:error, :timeout} end,
                  warn: fn io -> send(me, {:warn, IO.iodata_to_binary(io)}) end})

    assert {:ok, out} = Images.run([], deps)
    text = IO.iodata_to_binary(out)
    assert text =~ "local"
    refute text =~ "remote"
    assert_received {:warn, note}
    assert note =~ "could not reach Apple's catalog"
  end

  test "empty cache still lists Apple's offers" do
    assert {:ok, out} = Images.run([], deps(%{list: fn -> [] end}))
    text = IO.iodata_to_binary(out)
    assert text =~ ~r/25G76\s+-\s+remote/
    assert text =~ ~r/25F80\s+-\s+remote/
  end

  test "usage (exit 2) on any argument" do
    assert {:error, 2, _} = Images.run(["--remote"], deps())
    assert {:error, 2, _} = Images.run(["extra"], deps())
  end
end
