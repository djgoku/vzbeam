defmodule VzBeam.Share do
  @moduledoc "Parse + validate a --share tag=/path argument (tag <=36 UTF-8 bytes, no '='; host dir must exist)."

  @max_tag 36

  @spec parse(String.t()) ::
          {:ok, %{tag: String.t(), path: Path.t()}}
          | {:error, :no_equals | :empty_tag | :tag_too_long | :no_such_dir}
  def parse(spec) do
    case String.split(spec, "=", parts: 2) do
      [_] ->
        {:error, :no_equals}

      [tag, path] ->
        abs = Path.expand(path)

        cond do
          tag == "" -> {:error, :empty_tag}
          byte_size(tag) > @max_tag -> {:error, :tag_too_long}
          not File.dir?(abs) -> {:error, :no_such_dir}
          true -> {:ok, %{tag: tag, path: abs}}
        end
    end
  end
end
