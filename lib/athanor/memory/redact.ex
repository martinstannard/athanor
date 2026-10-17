defmodule Athanor.Memory.Redact do
  @moduledoc """
  Secret scrubbing for memory (plan D6, §9.1).

  Runs on **write** *and* on **injection**. The second is what defends against a `MEMORY.md`
  that a human hand-edited to contain a token, or an entry written before redaction existed —
  a fact that is already on disk must not reach the prompt unmasked just because it bypassed
  the write path.

  This is a best-effort filter, not a guarantee: `forget/2` remains the escape hatch when a
  secret slips through, and the audit line records why.
  """

  @redacted "[REDACTED]"

  @patterns [
    ~r/sk-[A-Za-z0-9]{16,}/,
    ~r/AKIA[0-9A-Z]{16}/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s,
    ~r/Authorization:\s*Bearer\s+\S+/i,
    ~r/(api[_-]?key|token|secret|password)\s*[:=]\s*\S+/i
  ]

  @doc """
  Replaces recognized secret shapes with `[REDACTED]`.

  Non-binary input is returned unchanged so callers can pass an optional field without
  guarding first.
  """
  @spec scrub(term()) :: term()
  def scrub(text) when is_binary(text) do
    Enum.reduce(@patterns, text, fn pattern, acc -> Regex.replace(pattern, acc, @redacted) end)
  end

  def scrub(other), do: other
end
