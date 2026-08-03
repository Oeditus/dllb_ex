defmodule Dllb.ErrorTest do
  use ExUnit.Case, async: true

  describe "exception/1" do
    test "builds a Dllb.Error from a %{message:, type:} map" do
      error = Dllb.Error.exception(%{message: "boom", type: :connection_error})

      assert %Dllb.Error{message: "boom", type: :connection_error} = error
      assert Exception.message(error) == "boom"
    end

    test "builds a Dllb.Error from a bare message, defaulting type to :query_error" do
      error = Dllb.Error.exception("something went wrong")

      assert %Dllb.Error{message: "something went wrong", type: :query_error} = error
    end

    test "is raiseable and catchable like any other exception" do
      assert_raise Dllb.Error, "boom", fn ->
        raise Dllb.Error, "boom"
      end
    end
  end
end
