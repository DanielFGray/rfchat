defmodule TavernWeb.Live.SharedHelpers do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Tavern.Chat
  alias Tavern.Chat.Visibility

  # Each button's visibility is one decision, made when the view renders. Nothing is stored
  # on the socket, so a role change applies at the next render.
  def can_manage_channels?(nil), do: false
  def can_manage_channels?(scope), do: Visibility.can?(scope, :manage_channels, :server)

  def can_manage_emojis?(nil), do: false

  def can_manage_emojis?(scope),
    do: Visibility.can?(scope, :manage_emojis_and_stickers, :server)

  def can_manage_server?(nil), do: false
  def can_manage_server?(scope), do: Visibility.can?(scope, :manage_server, :server)

  def can_view_audit_log?(nil), do: false
  def can_view_audit_log?(scope), do: Visibility.can?(scope, :view_audit_log, :server)

  def can_moderate_members?(nil), do: false

  def can_moderate_members?(scope) do
    Enum.any?(
      [:moderate_members, :kick_members, :ban_members],
      &Visibility.can?(scope, &1, :server)
    )
  end

  def save_emoji(socket, emoji_params, refresh_fun) when is_function(refresh_fun, 1) do
    upload = uploaded_entry(socket, :emoji_image)

    if is_nil(upload) do
      {:noreply, put_flash(socket, :error, "Choose an image before saving the emoji.")}
    else
      case consume_emoji_upload(socket, emoji_params) do
        {:ok, _emoji, socket} ->
          {:noreply,
           socket
           |> refresh_fun.()
           |> assign(:emoji_form, to_form(Chat.change_emoji(%Chat.Emoji{}, %{}), as: :emoji))
           |> put_flash(:info, "Emoji added.")}

        {:error, :invalid_upload_type, socket} ->
          {:noreply, put_flash(socket, :error, "Emoji uploads must be png, jpg, gif, or webp.")}

        {:error, changeset, socket} ->
          {:noreply, assign(socket, :emoji_form, to_form(changeset, as: :emoji))}
      end
    end
  end

  def consume_emoji_upload(socket, emoji_params) do
    result =
      Phoenix.LiveView.consume_uploaded_entries(socket, :emoji_image, fn %{path: path}, entry ->
        {:ok,
         Chat.create_custom_emoji_from_upload(emoji_params, socket.assigns.current_user, %{
           path: path,
           client_name: entry.client_name,
           client_type: entry.client_type
         })}
      end)

    case result do
      [{:ok, emoji}] -> {:ok, emoji, socket}
      [{:error, reason}] -> {:error, reason, socket}
      [] -> {:error, :invalid_upload_type, socket}
    end
  end

  def uploaded_entry(socket, name) do
    socket.assigns.uploads[name].entries |> List.first()
  end

  def run_member_moderation(scope, subject_id, %{
        "action" => "timeout",
        "duration_minutes" => minutes,
        "reason" => reason
      }) do
    case Integer.parse(to_string(minutes || "")) do
      {duration_minutes, ""} when duration_minutes > 0 ->
        case Chat.timeout_member(scope, subject_id, duration_minutes, blank_to_nil(reason)) do
          {:ok, updated_subject, moderation_case} ->
            {:ok, updated_subject, moderation_case, "Member timed out."}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :invalid_duration}
    end
  end

  def run_member_moderation(scope, subject_id, %{"action" => "kick", "reason" => reason}) do
    case Chat.kick_member(scope, subject_id, blank_to_nil(reason)) do
      {:ok, updated_subject, moderation_case} ->
        {:ok, updated_subject, moderation_case, "Member kicked."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_member_moderation(scope, subject_id, %{"action" => "ban", "reason" => reason}) do
    case Chat.ban_member(scope, subject_id, blank_to_nil(reason)) do
      {:ok, updated_subject, moderation_case} ->
        {:ok, updated_subject, moderation_case, "Member banned."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_member_moderation(_scope, _subject_id, _params), do: {:error, :invalid_action}

  def emoji_entries_for_picker(current_user) do
    Chat.list_available_emojis(current_user)
    |> Enum.map(fn emoji ->
      %{
        id: emoji.id,
        name: emoji.name,
        shortcode: emoji.shortcode,
        url: Chat.asset_url(emoji.asset)
      }
    end)
  end

  def server_branding do
    settings = Chat.get_server_settings()

    %{
      name: settings.name,
      icon_url: Chat.server_icon_url(settings)
    }
  end

  def assign_channel_form_mode(socket, mode) when is_binary(mode) do
    assign_channel_form_mode(socket, String.to_existing_atom(mode))
  rescue
    ArgumentError -> assign_channel_form_mode(socket, :create_text)
  end

  def assign_channel_form_mode(socket, :create_category) do
    socket
    |> assign(:channel_form_mode, :create_category)
    |> assign(:channel_form_title, "Create category")
    |> assign(:editing_channel_id, nil)
  end

  def assign_channel_form_mode(socket, :edit_category) do
    socket
    |> assign(:channel_form_mode, :edit_category)
    |> assign(:channel_form_title, "Edit category")
  end

  def assign_channel_form_mode(socket, :edit_text) do
    socket
    |> assign(:channel_form_mode, :edit_text)
    |> assign(:channel_form_title, "Edit channel")
  end

  def assign_channel_form_mode(socket, _mode) do
    socket
    |> assign(:channel_form_mode, :create_text)
    |> assign(:channel_form_title, "Create text channel")
    |> assign(:editing_channel_id, nil)
  end

  def default_channel_attrs(:create_category) do
    %{kind: :category, name: "", slug: "", topic: nil, parent_channel_id: nil, nsfw: false}
  end

  def default_channel_attrs(_mode) do
    %{kind: :text, name: "", slug: "", topic: nil, parent_channel_id: nil, nsfw: false}
  end

  def edit_mode_for(channel) do
    if channel.kind == :category, do: :edit_category, else: :edit_text
  end

  def normalize_channel_params(channel_params, channel_form_mode) do
    kind =
      if channel_form_mode in [:create_category, :edit_category], do: "category", else: "text"

    channel_params
    |> Map.put("kind", kind)
    |> Map.update("parent_channel_id", nil, fn parent_id ->
      if kind == "category", do: nil, else: blank_to_nil(parent_id)
    end)
    |> Map.update("topic", nil, &blank_to_nil/1)
    |> Map.update("slug", "", fn slug ->
      slug = String.trim(slug || "")
      if slug == "", do: slugify(Map.get(channel_params, "name", "")), else: slug
    end)
  end

  def creation_flash(channel) do
    if channel.kind == :category, do: "Category created.", else: "Channel created."
  end

  def assign_channel_form(socket, channel \\ nil) do
    channel = channel || %Chat.Channel{}

    attrs =
      if channel.id do
        %{
          name: channel.name,
          slug: channel.slug,
          topic: channel.topic,
          kind: channel.kind,
          parent_channel_id: channel.parent_channel_id,
          nsfw: channel.nsfw
        }
      else
        default_channel_attrs(socket.assigns.channel_form_mode)
      end

    form =
      channel
      |> Chat.change_channel(attrs)
      |> to_form(as: :channel)

    socket
    |> assign(:channel_form, form)
    |> assign(:editing_channel_id, channel.id)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
