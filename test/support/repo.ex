defmodule LiveViewVisualizer.TestRepo do
  @moduledoc false
  # Default telemetry prefix: [:live_view_visualizer, :test_repo]
  use Ecto.Repo, otp_app: :liveview_visualizer, adapter: Ecto.Adapters.Postgres
end

defmodule LiveViewVisualizer.AnalyticsRepo do
  @moduledoc false
  # Configured with a custom telemetry prefix ([:analytics, :db]) in
  # config/test.exs, to prove the prefix is discovered rather than guessed.
  use Ecto.Repo, otp_app: :liveview_visualizer, adapter: Ecto.Adapters.Postgres
end

defmodule LiveViewVisualizer.TestApp.Product do
  @moduledoc false
  use Ecto.Schema

  schema "products" do
    field :name, :string
    field :price, :integer
  end
end

defmodule LiveViewVisualizer.TestApp.StockLevel do
  @moduledoc false
  use Ecto.Schema

  schema "stock_levels" do
    field :product_id, :integer
    field :quantity, :integer
  end
end

defmodule LiveViewVisualizer.TestApp.User do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :api_token, :string
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password_hash, :api_token])
    |> unique_constraint(:email)
  end
end

defmodule LiveViewVisualizer.TestApp.PageView do
  @moduledoc false
  use Ecto.Schema

  schema "page_views" do
    field :path, :string
  end
end

defmodule LiveViewVisualizer.TestApp.Products do
  @moduledoc false
  # An ordinary context module: nothing here knows about the visualizer.
  import Ecto.Query

  alias LiveViewVisualizer.TestApp.{Product, StockLevel}
  alias LiveViewVisualizer.TestRepo, as: Repo

  def count, do: Repo.aggregate(Product, :count)
  def list_products, do: Repo.all(from p in Product, order_by: p.id)
  def list_stock_levels, do: Repo.all(StockLevel)
  def search(name), do: Repo.all(from p in Product, where: p.name == ^name)
end

defmodule LiveViewVisualizer.TestDB do
  @moduledoc false
  # Creates the dedicated test database and tables, and starts the repos the
  # way a host application would: after :liveview_visualizer has started.

  alias Ecto.Adapters.Postgres
  alias LiveViewVisualizer.{AnalyticsRepo, TestRepo}

  @tables [
    "CREATE TABLE products (id bigserial PRIMARY KEY, name text, price integer)",
    "CREATE TABLE stock_levels (id bigserial PRIMARY KEY, product_id bigint, quantity integer)",
    "CREATE TABLE users (id bigserial PRIMARY KEY, email text, password_hash text, api_token text)",
    "CREATE UNIQUE INDEX users_email_index ON users (email)",
    "CREATE TABLE page_views (id bigserial PRIMARY KEY, path text)"
  ]

  def setup do
    with :ok <- storage_up(),
         {:ok, _} <- TestRepo.start_link(),
         {:ok, _} <- AnalyticsRepo.start_link() do
      TestRepo.query!("DROP TABLE IF EXISTS products, stock_levels, users, page_views")
      Enum.each(@tables, &TestRepo.query!/1)
      :ok
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  def reset do
    TestRepo.query!("TRUNCATE products, stock_levels, users, page_views RESTART IDENTITY")
  end

  defp storage_up do
    case Postgres.storage_up(TestRepo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
