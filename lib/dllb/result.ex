defmodule Dllb.Result do
  @moduledoc """
  Structs representing parsed dllb server responses.

  Each struct corresponds to a response status:

    * `Dllb.Result.Ok` - generic success (`{"status":"ok"}`)
    * `Dllb.Result.Created` - record created with an id
    * `Dllb.Result.Deleted` - record deleted, reports whether it existed
    * `Dllb.Result.Rows` - query result with count and data rows
    * `Dllb.Result.Error` - server-side error with a message
  """

  defmodule Ok do
    @moduledoc "Represents a successful operation with no return data."
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule Created do
    @moduledoc "Represents a successful creation, carrying the new record's id."
    defstruct [:id]
    @type t :: %__MODULE__{id: String.t()}
  end

  defmodule Deleted do
    @moduledoc "Represents a deletion, reporting whether the record existed."
    defstruct [:existed]
    @type t :: %__MODULE__{existed: boolean()}
  end

  defmodule Rows do
    @moduledoc "Represents a query result containing rows of data."
    defstruct [:count, :data]
    @type t :: %__MODULE__{count: non_neg_integer(), data: [map()]}
  end

  defmodule Error do
    @moduledoc "Represents a server-side error response."
    defstruct [:message]
    @type t :: %__MODULE__{message: String.t()}
  end

  @type t :: Ok.t() | Created.t() | Deleted.t() | Rows.t() | Error.t()

  @doc """
  Converts a decoded JSON map (from `Dllb.Protocol.decode/2`) into the
  appropriate result struct by pattern-matching on the `"status"` key.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{"status" => "ok"}) do
    {:ok, %Ok{}}
  end

  def parse(%{"status" => "created", "id" => id}) do
    {:ok, %Created{id: id}}
  end

  def parse(%{"status" => "deleted", "existed" => existed}) do
    {:ok, %Deleted{existed: existed}}
  end

  def parse(%{"status" => "rows", "count" => count, "data" => data}) do
    {:ok, %Rows{count: count, data: data}}
  end

  def parse(%{"status" => "error", "message" => message}) do
    {:ok, %Error{message: message}}
  end

  def parse(other) do
    {:error, {:unknown_response, other}}
  end
end
