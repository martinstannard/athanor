defmodule Athanor.ConfigTest do
  use ExUnit.Case, async: true

  alias Athanor.Config

  @moduletag :tmp_dir

  test "reads opencode-go key from auth.json file", %{tmp_dir: tmp_dir} do
    auth_file = Path.join(tmp_dir, "auth.json")

    File.write!(
      auth_file,
      JSON.encode!(%{
        "opencode-go" => %{"type" => "api", "key" => "sk-test-opencode-key"}
      })
    )

    assert {:ok, "sk-test-opencode-key"} = Config.read_opencode_auth_key(auth_file)
  end

  test "returns error when auth.json is missing or lacks opencode-go key", %{tmp_dir: tmp_dir} do
    assert {:error, :not_found} =
             Config.read_opencode_auth_key(Path.join(tmp_dir, "nope.json"))
  end
end
