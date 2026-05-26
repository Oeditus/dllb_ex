defmodule Dllb.Pool do
  @moduledoc """
  NimblePool-based connection pool for dllb TCP connections.

  Workers are raw `:gen_tcp` sockets managed through `Dllb.Connection`.
  Dead sockets are detected at checkout and transparently reconnected.
  """

  @behaviour NimblePool

  alias Dllb.Connection

  @doc """
  Returns a child spec for starting the pool under a supervisor.

  ## Options

    * `:host` - server hostname (default from app env or `"127.0.0.1"`)
    * `:port` - server port (default from app env or `3009`)
    * `:pool_size` - number of connections (default from app env or `5`)
    * `:outcome` - response format (default `:json`)
    * `:timeout` - connection/recv timeout in ms (default `30_000`)
  """
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    pool_size = Keyword.get(opts, :pool_size, Application.get_env(:dllb, :pool_size, 5))

    %{
      id: __MODULE__,
      start:
        {NimblePool, :start_link,
         [[worker: {__MODULE__, opts}, pool_size: pool_size, name: __MODULE__]]}
    }
  end

  @doc """
  Executes a query through the connection pool.

  Checks out a socket, runs the query via `Dllb.Connection.query/3`,
  and checks the socket back in.

  ## Options

    * `:timeout` - recv timeout in ms (default `30_000`)

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec query(String.t(), Keyword.t()) :: {:ok, Dllb.Result.t()} | {:error, term()}
  def query(query_string, opts \\ []) do
    NimblePool.checkout!(__MODULE__, :checkout, fn _from, socket ->
      result = Connection.query(socket, query_string, opts)
      {result, result}
    end)
  catch
    :exit, reason -> {:error, {:pool_error, reason}}
  end

  @doc """
  Executes multiple queries through a single pool checkout.

  Checks out one socket, sends all queries sequentially, then checks
  the socket back in. This amortises the pool checkout cost across
  many queries (e.g. bulk AST ingestion).

  Returns a list of `{:ok, result} | {:error, reason}` in the same
  order as the input query strings.
  """
  @spec batch([String.t()], Keyword.t()) :: [{:ok, Dllb.Result.t()} | {:error, term()}]
  def batch(query_strings, opts \\ []) when is_list(query_strings) do
    NimblePool.checkout!(__MODULE__, :checkout, fn _from, socket ->
      results =
        Enum.map(query_strings, fn qs ->
          Connection.query(socket, qs, opts)
        end)

      {results, results}
    end)
  catch
    :exit, reason ->
      Enum.map(query_strings, fn _ -> {:error, {:pool_error, reason}} end)
  end

  @doc """
  Executes multiple queries inside a `BEGIN BATCH ... END BATCH` block
  through a single pool checkout.

  All statements run in one server-side storage transaction. Returns a
  single `{:ok, result}` or `{:error, reason}`.
  """
  @spec batch_transaction([String.t()], Keyword.t()) ::
          {:ok, Dllb.Result.t()} | {:error, term()}
  def batch_transaction(query_strings, opts \\ []) when is_list(query_strings) do
    NimblePool.checkout!(__MODULE__, :checkout, fn _from, socket ->
      result = Connection.batch_transaction(socket, query_strings, opts)
      {result, result}
    end)
  catch
    :exit, reason -> {:error, {:pool_error, reason}}
  end

  # -- NimblePool callbacks --------------------------------------------------

  @impl NimblePool
  def init_worker(opts) do
    conn_opts = [
      host: Keyword.get(opts, :host, Application.get_env(:dllb, :host, "127.0.0.1")),
      port: Keyword.get(opts, :port, Application.get_env(:dllb, :port, 3009)),
      outcome: Keyword.get(opts, :outcome, Application.get_env(:dllb, :outcome, :json)),
      timeout: Keyword.get(opts, :timeout, Application.get_env(:dllb, :timeout, 30_000))
    ]

    case Connection.connect(conn_opts) do
      {:ok, socket} ->
        {:ok, socket, opts}

      {:error, reason} ->
        raise "unexpected return from #{inspect(__MODULE__)}.init_worker/1: #{inspect(reason)}"
    end
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, socket, opts) do
    if Connection.alive?(socket) do
      {:ok, socket, socket, opts}
    else
      Connection.close(socket)

      {:ok, new_socket, opts} = init_worker(opts)
      {:ok, new_socket, new_socket, opts}
    end
  end

  @impl NimblePool
  def handle_checkin(_checkin_result, _from, socket, opts) do
    if Connection.alive?(socket) do
      {:ok, socket, opts}
    else
      {:remove, :closed, opts}
    end
  end

  @impl NimblePool
  def handle_info(message, socket) do
    case message do
      {:tcp_closed, ^socket} -> {:remove, :closed}
      {:tcp_error, ^socket, _reason} -> {:remove, :tcp_error}
      _ -> {:ok, socket}
    end
  end

  @impl NimblePool
  def terminate_worker(_reason, socket, opts) do
    Connection.close(socket)
    {:ok, opts}
  end
end
