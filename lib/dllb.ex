defmodule Dllb do
  @moduledoc """
  Elixir client for the dllb multi-model NoSQL database.

  Provides a high-level API that delegates to a NimblePool-managed
  connection pool. Configure the pool in your application config:

      config :dllb,
        enabled: true,
        host: "127.0.0.1",
        port: 3009,
        pool_size: 5,
        outcome: :json,
        timeout: 30_000

  ## Usage

      {:ok, result} = Dllb.query("SELECT * FROM users")
      result = Dllb.query!("SELECT * FROM users")
  """

  @doc """
  Executes a query through the connection pool.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec query(String.t()) :: {:ok, Dllb.Result.t()} | {:error, term()}
  def query(query_string), do: Dllb.Pool.query(query_string)

  @doc """
  Executes a query through the connection pool, raising on error.

  Returns the result struct on success or raises `Dllb.Error`.
  """
  @spec query!(String.t()) :: Dllb.Result.t()
  def query!(query_string) do
    case Dllb.Pool.query(query_string) do
      {:ok, %Dllb.Result.Error{message: message}} ->
        raise Dllb.Error, %{message: message, type: :query_error}

      {:ok, result} ->
        result

      {:error, reason} ->
        raise Dllb.Error, %{message: "query failed: #{inspect(reason)}", type: :connection_error}
    end
  end

  @doc """
  Executes multiple queries in a single pool checkout.

  Returns a list of `{:ok, result} | {:error, reason}` in the same
  order as the input queries. This is significantly faster for bulk
  operations (e.g. AST ingestion) because it amortises the pool
  checkout overhead.
  """
  @spec batch([String.t()]) :: [{:ok, Dllb.Result.t()} | {:error, term()}]
  def batch(query_strings) when is_list(query_strings) do
    Dllb.Pool.batch(query_strings)
  end

  @doc """
  Like `batch/1` but raises on the first error encountered.

  Returns a list of result structs on success.
  """
  @spec batch!([String.t()]) :: [Dllb.Result.t()]
  def batch!(query_strings) when is_list(query_strings) do
    query_strings
    |> Dllb.Pool.batch()
    |> Enum.map(fn
      {:ok, %Dllb.Result.Error{message: message}} ->
        raise Dllb.Error, %{message: message, type: :query_error}

      {:ok, result} ->
        result

      {:error, reason} ->
        raise Dllb.Error, %{
          message: "batch query failed: #{inspect(reason)}",
          type: :connection_error
        }
    end)
  end
end
