defmodule VzBeam.CLITest do
  use ExUnit.Case, async: true

  test "no args returns usage as an error" do
    assert {:error, 2, usage} = VzBeam.CLI.run([])
    assert IO.iodata_to_binary(usage) =~ "Usage: vzbeam"
  end

  test "--help returns usage as ok" do
    assert {:ok, usage} = VzBeam.CLI.run(["--help"])
    assert IO.iodata_to_binary(usage) =~ "ls"
  end

  test "unknown verb errors with exit code 2" do
    assert {:error, 2, msg} = VzBeam.CLI.run(["bogus"])
    assert IO.iodata_to_binary(msg) =~ "unknown command: bogus"
  end

  test "set dispatches (usage error without flags) and appears in help" do
    assert {:error, 2, _} = VzBeam.CLI.run(["set", "dev"])
    assert IO.iodata_to_binary(elem(VzBeam.CLI.run(["--help"]), 1)) =~ "set <name>"
  end

  test "displays dispatches (arity guard) and appears in help" do
    assert {:error, 2, _} = VzBeam.CLI.run(["displays", "extra"])  # routed to the verb, not help
    assert IO.iodata_to_binary(elem(VzBeam.CLI.run(["--help"]), 1)) =~ "displays"
  end

  test "fetch help line documents every image spec kind" do
    assert {:ok, usage} = VzBeam.CLI.run(["--help"])
    assert IO.iodata_to_binary(usage) =~ "fetch <latest|PATH|URL|BUILD>"
  end

  test "new --image help line documents every image spec kind" do
    assert {:ok, usage} = VzBeam.CLI.run(["--help"])
    assert IO.iodata_to_binary(usage) =~ "new <name> --image <latest|PATH|URL|BUILD>"
  end

  test "help text is pure ASCII (the escript renders non-ASCII as \\x{...} literals)" do
    assert {:ok, usage} = VzBeam.CLI.run(["--help"])
    bin = IO.iodata_to_binary(usage)
    non_ascii = for <<c <- bin>>, c >= 128, do: c
    assert non_ascii == [], "help text contains non-ASCII bytes: #{inspect(non_ascii)}"
  end

  test "top-level help is grouped by section" do
    assert {:ok, usage} = VzBeam.CLI.run(["--help"])
    text = IO.iodata_to_binary(usage)
    for section <- ["Images:", "Bundles:", "Lifecycle:", "Inspect:"], do: assert(text =~ section)
  end

  for verb <- ~w(fetch images new set rm run stop kill ssh ls ip displays) do
    test "help #{verb} and #{verb} --help agree and show usage" do
      assert {:ok, help} = VzBeam.CLI.run(["help", unquote(verb)])
      assert VzBeam.CLI.run([unquote(verb), "--help"]) == {:ok, help}
      assert IO.iodata_to_binary(help) =~ "Usage: vzbeam #{unquote(verb)}"
    end
  end

  test "per-command help documents the sizing flags and image specs" do
    {:ok, new_help} = VzBeam.CLI.run(["help", "new"])
    assert IO.iodata_to_binary(new_help) =~ "--disk-gb G"
    assert IO.iodata_to_binary(new_help) =~ "latest"
    {:ok, set_help} = VzBeam.CLI.run(["help", "set"])
    assert IO.iodata_to_binary(set_help) =~ "resizeContainer"
  end

  test "per-command help is pure ASCII" do
    for {:ok, help} <- Enum.map(~w(fetch images new set rm run stop kill ssh ls ip displays),
                                &VzBeam.CLI.run(["help", &1])) do
      non_ascii = for <<c <- IO.iodata_to_binary(help)>>, c >= 128, do: c
      assert non_ascii == []
    end
  end

  test "help for an unknown verb errors with exit code 2" do
    assert {:error, 2, msg} = VzBeam.CLI.run(["help", "bogus"])
    assert IO.iodata_to_binary(msg) =~ "no help for: bogus"
  end

  @version_line "vzbeam #{Mix.Project.config()[:version]} - https://github.com/djgoku/vzbeam"

  for flag <- ["version", "--version", "-v"] do
    test "#{flag} prints 'vzbeam <version> - <github-url>'" do
      assert {:ok, out} = VzBeam.CLI.run([unquote(flag)])
      assert IO.iodata_to_binary(out) =~ @version_line
    end
  end

  test "help header includes the version + github url line" do
    assert {:ok, usage} = VzBeam.CLI.run(["--help"])
    assert IO.iodata_to_binary(usage) =~ @version_line
  end
end
