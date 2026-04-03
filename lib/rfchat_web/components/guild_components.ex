defmodule RfchatWeb.GuildComponents do
  @moduledoc false

  defdelegate mobile_overlays(assigns), to: RfchatWeb.GuildComponents.Shell
  defdelegate mobile_channel_drawer(assigns), to: RfchatWeb.GuildComponents.Shell
  defdelegate members_drawer(assigns), to: RfchatWeb.GuildComponents.Shell
  defdelegate active_channel_view(assigns), to: RfchatWeb.GuildComponents.Messages
  defdelegate empty_channel_view(assigns), to: RfchatWeb.GuildComponents.Messages
end
