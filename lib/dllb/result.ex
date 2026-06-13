defmodule Dllb.Result do
  @moduledoc """
  Structs representing parsed dllb server responses.

  Each struct corresponds to a response status:

    * `Dllb.Result.Ok` - generic success (`{"status":"ok"}`)
    * `Dllb.Result.Created` - record created with an id
    * `Dllb.Result.Deleted` - record deleted, reports whether it existed
    * `Dllb.Result.DeletedMany` - `DELETE ... WHERE`, reports how many removed
    * `Dllb.Result.Rows` - query result with count and data rows
    * `Dllb.Result.Error` - server-side error with a message
  """

  defmodule Ok do
    @moduledoc "Represents a successful operation with no return data."
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule Created do
    @moduledoc "Represents a successful creation or upsert, carrying the record's id."
    defstruct [:id]
    @type t :: %__MODULE__{id: String.t()}
  end

  defmodule Deleted do
    @moduledoc "Represents a deletion, reporting whether the record existed."
    defstruct [:existed]
    @type t :: %__MODULE__{existed: boolean()}
  end

  defmodule DeletedMany do
    @moduledoc "Represents a `DELETE ... WHERE` deletion, reporting the number of rows removed."
    defstruct [:count]
    @type t :: %__MODULE__{count: non_neg_integer()}
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

  defmodule Batch do
    @moduledoc "Represents the result of a `BEGIN BATCH ... END BATCH` block."
    defstruct [:count, :created, :updated]

    @type t :: %__MODULE__{
            count: non_neg_integer(),
            created: non_neg_integer(),
            updated: non_neg_integer()
          }
  end

  defmodule Communities do
    @moduledoc """
    Represents the result of a `GRAPH COMMUNITIES` query.

    Each entry in `data` is a map with three keys (values are serde-tagged):
      - `"id"` — community representative node ID (e.g. `%{"String" => "node_id"}`)
      - `"size"` — number of members (e.g. `%{"Int" => 5}`)
      - `"members"` — list of member IDs (e.g. `%{"Array" => [%{"String" => "n1"}, ...]}`)}
    """
    defstruct [:algorithm, :community_count, :data]

    @type t :: %__MODULE__{
            algorithm: String.t(),
            community_count: non_neg_integer(),
            data: [map()]
          }
  end

  defmodule Count do
    @moduledoc "Represents the result of a `COUNT` query."
    defstruct [:count]
    @type t :: %__MODULE__{count: non_neg_integer()}
  end

  defmodule Update do
    @moduledoc "Represents the result of an `UPDATE` statement (rows matched)."
    defstruct [:matched]
    @type t :: %__MODULE__{matched: non_neg_integer()}
  end

  defmodule Components do
    @moduledoc """
    Represents the result of a `GRAPH COMPONENTS` query: a compact
    connected-components summary (no per-component membership).
    """
    defstruct [:component_count, :largest, :nodes]

    @type t :: %__MODULE__{
            component_count: non_neg_integer(),
            largest: non_neg_integer(),
            nodes: non_neg_integer()
          }
  end

  @type t ::
          Ok.t()
          | Created.t()
          | Deleted.t()
          | DeletedMany.t()
          | Rows.t()
          | Error.t()
          | Batch.t()
          | Communities.t()
          | Count.t()
          | Update.t()
          | Components.t()

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

  def parse(%{"status" => "updated", "id" => id}) do
    {:ok, %Created{id: id}}
  end

  def parse(%{"status" => "deleted", "existed" => existed}) do
    {:ok, %Deleted{existed: existed}}
  end

  def parse(%{"status" => "deleted_many", "count" => count}) do
    {:ok, %DeletedMany{count: count}}
  end

  def parse(%{"status" => "rows", "count" => count, "data" => data}) do
    {:ok, %Rows{count: count, data: data}}
  end

  def parse(%{"status" => "error", "message" => message}) do
    {:ok, %Error{message: message}}
  end

  def parse(%{"status" => "batch", "count" => count, "created" => created, "updated" => updated}) do
    {:ok, %Batch{count: count, created: created, updated: updated}}
  end

  def parse(%{
        "status" => "communities",
        "algorithm" => algorithm,
        "community_count" => community_count,
        "data" => data
      }) do
    {:ok, %Communities{algorithm: algorithm, community_count: community_count, data: data}}
  end

  def parse(%{"status" => "count", "count" => count}) do
    {:ok, %Count{count: count}}
  end

  def parse(%{"status" => "update", "matched" => matched}) do
    {:ok, %Update{matched: matched}}
  end

  def parse(%{
        "status" => "components",
        "component_count" => component_count,
        "largest" => largest,
        "nodes" => nodes
      }) do
    {:ok, %Components{component_count: component_count, largest: largest, nodes: nodes}}
  end

  def parse(other) do
    {:error, {:unknown_response, other}}
  end
end
