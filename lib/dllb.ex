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
end
