import Config

config :dllb,
  enabled: true,
  host: "127.0.0.1",
  port: 3009,
  pool_size: 30,
  outcome: :json,
  timeout: 30_000

import_config "#{config_env()}.exs"
