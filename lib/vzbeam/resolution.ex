defmodule VzBeam.Resolution do
  @moduledoc "Shared parser for positive lowercase WIDTHxHEIGHT resolutions."

  @spec parse(term) :: {:ok, {pos_integer, pos_integer}} | {:error, :bad_resolution}
  def parse(value) when is_binary(value) do
    case Regex.run(~r/\A([1-9]\d*)x([1-9]\d*)\z/, value) do
      [_, width, height] -> {:ok, {String.to_integer(width), String.to_integer(height)}}
      _ -> {:error, :bad_resolution}
    end
  end

  def parse(_), do: {:error, :bad_resolution}
end
