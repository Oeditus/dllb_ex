import Config

config :dllb,
  enabled: true,
  host: "127.0.0.1",
  port: 3009,
  pool_size: 5,
  outcome: :json,
  timeout: 30_000
