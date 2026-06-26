defmodule VzBeam.Displays do
  @moduledoc "Parse `system_profiler SPDisplaysDataType -json` and suggest --resolution values."

  @default "1920x1200"
  @type display :: %{name: String.t(), width: pos_integer, height: pos_integer,
                     main: boolean, looks_like: String.t() | nil}

  @spec parse(String.t()) :: [display]
  def parse(json) do
    case Jason.decode(json) do
      {:ok, %{"SPDisplaysDataType" => gpus}} when is_list(gpus) ->
        gpus
        |> Enum.flat_map(&Map.get(&1, "spdisplays_ndrvs", []))
        |> Enum.map(&one/1)
        |> Enum.reject(&is_nil/1)

      _ -> []
    end
  end

  defp one(%{"_spdisplays_pixels" => px} = d) do
    case dims(px) do
      {w, h} ->
        res = d["_spdisplays_resolution"]
        %{name: d["_name"] || "Display", width: w, height: h,
          main: d["spdisplays_main"] == "spdisplays_yes",
          looks_like: if(is_binary(res), do: res, else: nil)}
      :error -> nil
    end
  end
  defp one(_), do: nil

  defp dims(s) do
    case Regex.run(~r/(\d+)\s*x\s*(\d+)/, to_string(s)) do
      [_, w, h] -> {String.to_integer(w), String.to_integer(h)}
      _ -> :error
    end
  end

  @spec suggestions([display]) :: [String.t()]
  def suggestions([]), do: [@default]
  def suggestions(displays) do
    %{width: w, height: h} = Enum.find(displays, hd(displays), & &1.main)
    Enum.uniq(["#{w}x#{h}", "#{div(w, 2)}x#{div(h, 2)}", @default])
  end
end
