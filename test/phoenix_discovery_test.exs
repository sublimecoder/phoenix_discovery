defmodule PhoenixDiscoveryTest do
  use ExUnit.Case, async: true

  doctest PhoenixDiscovery

  describe "url/2" do
    test "keeps http URLs as they are" do
      assert PhoenixDiscovery.url("https://example.com", "http://example.org/x") ==
               "http://example.org/x"
    end

    test "rejects a path without a leading slash" do
      assert_raise FunctionClauseError, fn -> PhoenixDiscovery.url("https://example.com", "x") end
    end
  end
end
