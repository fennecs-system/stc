defmodule Stc.Test.Repo.Migrations.CreateStcTables do
  use Ecto.Migration

  def change do
    create table(:stc_events) do
      add :type, :text, null: false
      add :task_id, :text
      add :workflow_id, :text
      add :payload, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:stc_locks, primary_key: false) do
      add :task_id, :text, primary_key: true
      add :lock_id, :text, null: false
      add :caller_id, :text, null: false
      add :acquired_at, :utc_datetime_usec, null: false
    end

    create table(:stc_kv, primary_key: false) do
      add :key, :text, primary_key: true
      add :value, :binary, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: false)
    end
  end
end
