defmodule VzBeam.RunOptions do
  @moduledoc "Command-specific parser for run, including optional-value --iso media."
  alias VzBeam.Resolution

  @type media :: nil | :cached | {:path, String.t()}

  @spec parse([String.t()]) :: {:ok, map} | {:error, atom}
  def parse(args) do
    cond do
      Enum.any?(args, &(&1 == "--no-iso" or String.starts_with?(&1, "--no-iso="))) ->
        {:error, :usage}

      iso_count(args) > 1 ->
        {:error, :repeated_iso}

      true ->
        parse_iso(args)
    end
  end

  defp iso_count(args) do
    Enum.count(args, &(&1 == "--iso" or String.starts_with?(&1, "--iso=")))
  end

  defp parse_iso(args) do
    case Enum.find_index(args, &(&1 == "--iso" or String.starts_with?(&1, "--iso="))) do
      nil ->
        parse_normal(args, nil)

      index ->
        token = Enum.at(args, index)

        if token == "--iso" do
          parse_bare_iso(args, index)
        else
          parse_equals_iso(args, index, String.replace_prefix(token, "--iso=", ""))
        end
    end
  end

  defp parse_equals_iso(_args, _index, ""), do: {:error, :usage}

  defp parse_equals_iso(args, index, path) do
    args
    |> remove_at(index)
    |> parse_normal({:path, path})
  end

  defp parse_bare_iso(args, index) do
    cached = args |> remove_at(index) |> parse_normal(:cached)

    case cached do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        case valued_iso(args, index) do
          {:ok, _} = ok ->
            ok

          {:error, valued_reason} ->
            {:error, preferred_error(reason, valued_reason)}
        end
    end
  end

  defp valued_iso(args, index) do
    case Enum.at(args, index + 1) do
      nil ->
        {:error, :usage}

      next when is_binary(next) ->
        if String.starts_with?(next, "-") do
          {:error, :usage}
        else
          args
          |> remove_at(index + 1)
          |> remove_at(index)
          |> parse_normal({:path, next})
        end
    end
  end

  defp preferred_error(:usage, valued_reason), do: valued_reason
  defp preferred_error(reason, _valued_reason), do: reason

  defp parse_normal(args, iso) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [gui: :boolean, headless: :boolean, resolution: :string, share: :string]
      )

    gui = Keyword.get(opts, :gui, false)
    headless = Keyword.get(opts, :headless, false)
    resolution = Keyword.get(opts, :resolution)
    share = opts |> Keyword.get_values(:share) |> List.last()

    cond do
      invalid != [] ->
        {:error, invalid_reason(invalid)}

      positional |> length() != 1 ->
        {:error, :usage}

      iso != nil and headless ->
        {:error, :iso_headless}

      gui and headless ->
        {:error, :mode_conflict}

      resolution != nil and match?({:error, _}, Resolution.parse(resolution)) ->
        {:error, :bad_resolution}

      true ->
        {:ok,
         %{
           name: hd(positional),
           gui: gui or iso != nil,
           headless: headless,
           resolution: resolution,
           share: share,
           iso: iso
         }}
    end
  end

  defp invalid_reason(invalid) do
    known = ["--gui", "--headless", "--resolution", "--share"]

    if Enum.any?(invalid, fn {option, _value} -> option not in known end),
      do: :unknown_option,
      else: :usage
  end

  defp remove_at(list, index), do: List.delete_at(list, index)
end
