defmodule VzBeam.Defaults do
  @moduledoc "Built-in default sizing — no config file in the MVP."

  @values %{cpu: 4, mem_gb: 8, disk_gb: 64, resolution: "1920x1200", ssh_user: "admin"}

  @spec values() :: map
  def values, do: @values

  @spec resolve(any | nil, atom) :: any
  def resolve(nil, key), do: Map.fetch!(@values, key)
  def resolve(flag_value, _key), do: flag_value
end
