defmodule TavernWeb.SettingsComponents do
  @moduledoc false

  defdelegate page(assigns), to: TavernWeb.SettingsComponents.Shell
end
