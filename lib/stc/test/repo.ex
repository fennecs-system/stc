defmodule Stc.Test.Repo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :stc,
    adapter: Ecto.Adapters.Postgres
end
