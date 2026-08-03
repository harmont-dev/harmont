import Config

# Keep debug logs in production for now (reviewer request): the executor is
# young and we want full visibility into job/build state churn in prod.
config :logger, level: :debug

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
