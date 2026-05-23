defmodule Dllb.Error do
  @moduledoc """
  Exception struct for dllb client errors.

  ## Fields

    * `:message` - human-readable error description
    * `:type` - atom classifying the error, one of
      `:connection_error`, `:protocol_error`, `:query_error`, `:timeout`
  """

  @type t :: %__MODULE__{
          message: String.t(),
          type: :connection_error | :protocol_error | :query_error | :timeout
        }

  defexception [:message, :type]

  @impl Exception
  def exception(%{message: message, type: type}) do
    %__MODULE__{message: message, type: type}
  end

  def exception(message) when is_binary(message) do
    %__MODULE__{message: message, type: :query_error}
  end
end
