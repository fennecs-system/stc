defmodule Stc.Test.Repo.Migrations.CreateStcTables do
  use Ecto.Migration
  def up, do: Stc.Migrations.up()
  def down, do: Stc.Migrations.down()
end
