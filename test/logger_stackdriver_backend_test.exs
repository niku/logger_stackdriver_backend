defmodule LoggerStackdriverBackendTest do
  use ExUnit.Case
  doctest LoggerStackdriverBackend

  test "greets the world" do
    assert LoggerStackdriverBackend.hello() == :world
  end
end
