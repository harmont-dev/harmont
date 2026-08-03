# Pre-existing dialyzer warnings acknowledged as non-actionable.
#
# These fall into two categories:
#
# 1. unknown_type: Cross-umbrella-app type references. Dialyzer sees harmont_core
#    Ecto schema types (Build.t(), Job.t(), etc.) as unknown when specs in
#    harmont_engine/harmont_gh_app reference them, because umbrella apps compile
#    into separate BEAM files and dialyzer resolves types across the unified PLT
#    but not across the compile-time opaque boundaries set by each app's mix.exs.
#    These are structural — not logic errors — and will resolve if/when the codebase
#    moves to a single PLT or adds cross-app type exports.
#
# 2. call_without_opaque / pattern_match_cov in scheduling.ex and payload.ex:
#    MapSet opaque-type propagation warnings (scheduling.ex) and TypedStruct
#    macro-generated unreachable clause warnings (payload.ex) — both pre-existing
#    before Task 6, confirmed non-functional.
[
  # unknown_type warnings across umbrella app boundaries (structural, not logic).
  # These reference non-schema types from sibling apps (github_client, etc.) that
  # dialyzer can't resolve across the per-app compile boundary. The harmont_core
  # Ecto schema .t() references that used to land here are now resolved — every
  # schema defines @type t :: %__MODULE__{} — so the engine entries are gone.
  {"lib/harmont/gh_app/runtime.ex", :unknown_type},
  {"lib/harmont/gh_app/store.ex", :unknown_type},
  {"lib/harmont/gh_app/webhook/payload.ex", :unknown_type},

  # MapSet opaque-type propagation in scheduling.ex — pre-existing, not a logic error
  {"lib/harmont/engine/scheduling.ex", :call_without_opaque},

  # TypedStruct macro-generated pattern_match_cov in payload.ex — pre-existing
  {"lib/harmont/gh_app/webhook/payload.ex", :pattern_match_cov},

  # Harmont.Storage.Gcs is a deliberate Plan-8 stub: every callback returns
  # {:error, {:not_implemented, _}} until the GCS REST upload/download lands, so
  # it can't yet satisfy the @callback specs. Local is the default backend; this
  # is acknowledged-incomplete, not a logic error.
  {"lib/harmont/storage/gcs.ex", :callback_type_mismatch}
]
