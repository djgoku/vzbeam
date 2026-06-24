defmodule VzBeam.Protocol do
  @moduledoc "Pure decoder for the vz JSON-lines wire protocol (no I/O)."

  @max_line 1_048_576
  @type event :: {:event, String.t(), map}

  @spec decode_line(binary) :: event | {:error, :bad_json | :missing_type | :oversize}
  def decode_line(line) when byte_size(line) > @max_line, do: {:error, :oversize}

  def decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = map} -> {:event, type, map}
      {:ok, _} -> {:error, :missing_type}
      {:error, _} -> {:error, :bad_json}
    end
  end

  @spec collect([binary], [String.t()], boolean) :: {:ok, [event], event} | {:error, term}
  def collect(lines, terminal_types, final_newline?) do
    with :ok <- check_terminated(lines, final_newline?),
         {:ok, events} <- decode_all(lines) do
      error = Enum.find(events, &match?({:event, "error", _}, &1))
      terminal = Enum.find(events, fn {:event, t, _} -> t in terminal_types end)

      cond do
        error ->
          {:event, "error", m} = error
          {:error, {:vz, m["domain"], m["code"], m["message"]}}

        terminal ->
          {:ok, events, terminal}

        true ->
          {:error, :no_terminal}
      end
    end
  end

  defp check_terminated([], _), do: :ok
  defp check_terminated(_lines, true), do: :ok
  defp check_terminated(_lines, false), do: {:error, :unterminated}

  defp decode_all(lines) do
    result =
      Enum.reduce_while(lines, [], fn line, acc ->
        case decode_line(line) do
          {:event, _, _} = ev -> {:cont, [ev | acc]}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:error, _} = err -> err
      acc -> {:ok, Enum.reverse(acc)}
    end
  end
end
