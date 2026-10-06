defmodule LiveViewVisualizer.ConfigTest do
  # Mutates the application environment, so it must not run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LiveViewVisualizer.Config

  @app :liveview_visualizer

  setup do
    original = Application.get_all_env(@app)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(@app), do: Application.delete_env(@app, key)
      for {key, value} <- original, do: Application.put_env(@app, key, value)
    end)
  end

  describe "enabled?/0" do
    test "is disabled by default when nothing is configured" do
      Application.delete_env(@app, :enabled)
      refute Config.enabled?()
    end

    test "is enabled when configured with true" do
      Application.put_env(@app, :enabled, true)
      assert Config.enabled?()
    end

    test "is disabled when configured with false" do
      Application.put_env(@app, :enabled, false)
      refute Config.enabled?()
    end

    test "is disabled for truthy values that are not the literal true" do
      for value <- ["true", 1, :yes, nil] do
        Application.put_env(@app, :enabled, value)
        refute Config.enabled?(), "expected #{inspect(value)} to mean disabled"
      end
    end
  end

  describe "max_events/0" do
    test "defaults to 1000" do
      Application.delete_env(@app, :max_events)
      assert Config.max_events() == 1_000
    end

    test "returns the configured positive integer" do
      Application.put_env(@app, :max_events, 42)
      assert Config.max_events() == 42
    end

    test "falls back to the default and warns on invalid values" do
      for value <- [0, -5, "100", 1.5] do
        Application.put_env(@app, :max_events, value)

        log = capture_log(fn -> assert Config.max_events() == 1_000 end)
        assert log =~ ":max_events"
      end
    end
  end

  describe "redact_keys/0" do
    test "defaults to an empty list" do
      Application.delete_env(@app, :redact_keys)
      assert Config.redact_keys() == []
    end

    test "returns configured atoms and strings" do
      Application.put_env(@app, :redact_keys, [:ssn, "iban"])
      assert Config.redact_keys() == [:ssn, "iban"]
    end

    test "ignores invalid values with a warning" do
      Application.put_env(@app, :redact_keys, [:ok, 123])
      assert capture_log(fn -> assert Config.redact_keys() == [] end) =~ ":redact_keys"

      Application.put_env(@app, :redact_keys, :ssn)
      assert capture_log(fn -> assert Config.redact_keys() == [] end) =~ ":redact_keys"
    end
  end

  describe "instrumentations/0" do
    test "defaults to no instrumentations" do
      Application.delete_env(@app, :instrumentations)
      assert Config.instrumentations() == []
    end

    test "returns configured modules" do
      Application.put_env(@app, :instrumentations, [LiveViewVisualizer.TestInstrumentation])
      assert Config.instrumentations() == [LiveViewVisualizer.TestInstrumentation]
    end

    test "ignores invalid values with a warning" do
      Application.put_env(@app, :instrumentations, ["NotAModule"])
      assert capture_log(fn -> assert Config.instrumentations() == [] end) =~ ":instrumentations"
    end
  end
end
