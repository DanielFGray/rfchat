defmodule RfchatWeb.SettingsComponents do
  @moduledoc false

  defdelegate page(assigns), to: RfchatWeb.SettingsComponents.Shell
end
