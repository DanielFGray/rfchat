defmodule Rfchat.Accounts.Scope do
  @moduledoc """
  Who acts. It holds ids only: the permissions are read by `Rfchat.Chat.Visibility` for each
  decision, never stored here.
  """

  defstruct [:user_id, :bot_token_id]
end
