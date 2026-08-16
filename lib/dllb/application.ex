defmodule Dllb.Application do
  @moduledoc """
  OTP Application for the dllb client.

  Starts the `Dllb.Pool` connection pool under a supervisor when the
  `:dllb` application is configured with `enabled: true`.

  ## Configuration

      config :dllb,
        enabled: true,
        host: "127.0.0.1",
        port: 3009,
        pool_size: 30,
        outcome: :json,
        timeout: 30_000
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      if Application.get_env(:dllb, :enabled, false) do
        pool_opts = [
          host: Application.get_env(:dllb, :host, "127.0.0.1"),
          port: Application.get_env(:dllb, :port, 3009),
          pool_size: Application.get_env(:dllb, :pool_size, 30),
          outcome: Application.get_env(:dllb, :outcome, :json),
          timeout: Application.get_env(:dllb, :timeout, 30_000)
        ]

        [Dllb.Pool.child_spec(pool_opts)]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Dllb.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
