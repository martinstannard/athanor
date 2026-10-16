defmodule Athanor.Store.TokensTest do
  use ExUnit.Case, async: true

  alias Athanor.Store.Tokens

  # Pure module: no tmp_dir needed, nothing touches the file system (plan §9.5).

  describe "estimate/1" do
    test "is zero for empty/nil and monotonic in length" do
      assert Tokens.estimate("") == 0
      assert Tokens.estimate(nil) == 0

      lengths = [1, 4, 5, 100, 1_000, 10_000]
      estimates = Enum.map(lengths, &Tokens.estimate(String.duplicate("x", &1)))

      assert estimates == Enum.sort(estimates)
      assert length(Enum.uniq(estimates)) > 1
    end

    test "is roughly bytes/4 and never zero for a non-empty string" do
      assert Tokens.estimate("abcd") == 1
      assert Tokens.estimate("abcde") == 2
      assert Tokens.estimate(String.duplicate("a", 400)) == 100
      assert Tokens.estimate("a") >= 1
    end

    test "counts bytes, not codepoints" do
      # Multi-byte input must not under-count: a 4-byte emoji is one token by this proxy.
      assert Tokens.estimate("é") == 1
      assert Tokens.estimate("🙂🙂🙂🙂") == 4
    end
  end

  describe "estimate_messages/1" do
    test "empty list is 0" do
      assert Tokens.estimate_messages([]) == 0
    end

    test "sums the per-message framing cost plus content" do
      messages = [
        %{"role" => "system", "content" => "abcd"},
        %{"role" => "user", "content" => "abcd"}
      ]

      # 4 framing tokens each + 1 content token each
      assert Tokens.estimate_messages(messages) == 10
      assert Tokens.cost(hd(messages)) == 5
    end

    test "a tool message counts its content" do
      short = %{"role" => "tool", "tool_call_id" => "call_1", "content" => "ok"}

      long = %{
        "role" => "tool",
        "tool_call_id" => "call_1",
        "content" => String.duplicate("z", 400)
      }

      assert Tokens.estimate_messages([long]) > Tokens.estimate_messages([short])
      # 400 bytes → 100 tokens, 4 bytes → 1; the equal framing cost cancels out.
      assert Tokens.estimate_messages([long]) - Tokens.estimate_messages([short]) == 99
      assert Tokens.estimate(String.duplicate("z", 400)) == 100
      assert Tokens.estimate("ok") == 1
    end

    test "includes tool-call function name and arguments JSON" do
      without = %{"role" => "assistant", "content" => "", "tool_calls" => []}

      with_call = %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "read_file", "arguments" => ~s({"path":"mix.exs"})}
          }
        ]
      }

      assert Tokens.estimate_messages([with_call]) > Tokens.estimate_messages([without])

      expected =
        Tokens.estimate("read_file") + Tokens.estimate(~s({"path":"mix.exs"}))

      assert Tokens.estimate_messages([with_call]) - Tokens.estimate_messages([without]) ==
               expected

      assert expected > 0
    end

    test "a tool call with a pre-decoded arguments map counts zero for the arguments" do
      # `arguments` is a JSON *string* on the wire; a map (an in-process convenience) is not
      # counted, because `estimate/1` only measures binaries.
      call = %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{"id" => "c", "function" => %{"name" => "bash", "arguments" => %{"cmd" => "ls"}}}
        ]
      }

      assert Tokens.estimate_messages([call]) == 4 + Tokens.estimate("bash")
    end

    test "sums the whole list (order-independent, additive)" do
      a = %{"role" => "user", "content" => String.duplicate("a", 40)}
      b = %{"role" => "assistant", "content" => String.duplicate("b", 80)}

      assert Tokens.estimate_messages([a, b]) == Tokens.cost(a) + Tokens.cost(b)
      assert Tokens.estimate_messages([a, b]) > Tokens.estimate_messages([a])
    end

    test "tolerates atom keys, structs and malformed entries" do
      assert Tokens.cost(%{role: "user", content: "abcd"}) == 5
      assert Tokens.cost(%Athanor.Store.Session{id: "s1", role: :worker}) > 0
      assert Tokens.cost(nil) == 0
      assert Tokens.estimate_messages([nil, "garbage"]) |> is_integer()

      # tool_calls is `nil` (as OpenAI returns for a tool message) rather than a list.
      assert Tokens.cost(%{"role" => "assistant", "content" => "hi", "tool_calls" => nil}) ==
               4 + Tokens.estimate("hi")
    end
  end
end
