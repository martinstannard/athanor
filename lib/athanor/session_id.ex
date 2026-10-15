defmodule Athanor.SessionId do
  @moduledoc """
  Generation and validation of session identifiers.

  A session id is the immutable identity of a Conductor or Sub-Agent. It is a `Registry` key
  today and, from §7.1/§7.4 onwards, also a filesystem directory name and a git branch
  component. That gives it three required properties:

    * **Unique by construction.** `:erlang.unique_integer/1` is unique per node with no race,
      and the random suffix keeps ids unique across nodes (§7.8) and across VM restarts. The
      previous implementation derived a counter from `Registry.count/1` + 2 random bytes,
      which is racy under concurrent spawns. That was survivable while ids were ephemeral, but
      once §7.4 persists transcripts a collision silently merges two sessions and is
      unrecoverable.
    * **Path- and ref-safe.** `[a-z0-9]` plus `-`, never `.` or `/`, so `Path.join/2` and
      `git branch` need no escaping and `..` can never appear as a path segment.
    * **Stable.** Generated once, then never re-derived.

  Uniqueness is enforced in two places: generation (negligible collision probability) and
  `Athanor.Agent`, which **refuses to start** when an id is already registered rather than
  running unregistered and therefore unreachable (`DynamicSupervisor` does not reject
  duplicate child-spec ids, so the registry is the only real guard).
  """

  @max_length 120
  @random_bytes 4

  @prefix_re ~r/^[a-z][a-z0-9]*$/
  @id_re ~r/^[a-z]([a-z0-9_-]*[a-z0-9])?$/

  @doc """
  Generates an id for `prefix` (an atom or lowercase string), e.g. `"worker-1q-9c1d4e7a"`.

  Raises `ArgumentError` for a prefix that could not produce a valid id.
  """
  @spec generate(String.t() | atom()) :: String.t()
  def generate(prefix) when is_atom(prefix), do: generate(Atom.to_string(prefix))

  def generate(prefix) when is_binary(prefix) do
    unless Regex.match?(@prefix_re, prefix) do
      raise ArgumentError, "invalid session id prefix: #{inspect(prefix)}"
    end

    # NB: `Integer.to_string/2` emits *uppercase* base-36 digits, so downcase to keep ids
    # inside the lowercase-only charset that `valid?/1` (and §7.1/§7.4 paths) require.
    "#{prefix}-#{counter()}-#{random_hex()}"
  end

  @doc """
  Validates an id.

  Requires 1..#{@max_length} bytes of a path- and ref-safe charset, starting with a letter so an
  id can never be mistaken for a `..` segment or an option flag.
  """
  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id) do
    byte_size(id) <= @max_length and Regex.match?(@id_re, id)
  end

  def valid?(_id), do: false

  @doc "Maximum accepted id length in bytes."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  defp counter do
    :erlang.unique_integer([:positive]) |> Integer.to_string(36) |> String.downcase()
  end

  defp random_hex do
    :crypto.strong_rand_bytes(@random_bytes) |> Base.encode16(case: :lower)
  end
end
