defmodule ChatApiWeb.ConversationChannel do
  use ChatApiWeb, :channel
  use Appsignal.Instrumentation.Decorators

  alias ChatApiWeb.Presence
  alias ChatApi.{Messages, Conversations}
  alias ChatApi.Messages.Message

  require Logger

  @impl true
  def join("conversation:lobby", _payload, socket) do
    {:ok, socket}
  end

  def join("conversation:lobby:" <> customer_id, _params, socket) do
    {:ok, assign(socket, :customer_id, customer_id)}
  end

  def join("conversation:" <> private_conversation_id, payload, socket) do
    if authorized?(payload, private_conversation_id) do
      conversation = Conversations.get_conversation!(private_conversation_id)

      socket =
        assign(
          socket,
          :conversation,
          ChatApiWeb.ConversationView.render("basic.json", conversation: conversation)
        )

      # If the payload includes a customer_id, we want to mark this customer
      # as "online" via Phoenix Presence in the :after_join hook
      case payload do
        %{"customer_id" => customer_id} ->
          send(self(), :after_join)
          {:ok, socket |> assign(:customer_id, customer_id)}

        _ ->
          {:ok, socket}
      end
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    with %{customer_id: customer_id, conversation: conversation} <- socket.assigns,
         %{account_id: account_id} <- conversation do
      key = "customer:" <> customer_id

      # Track the presence of this customer in the conversation
      {:ok, _} =
        Presence.track(socket, key, %{
          online_at: inspect(System.system_time(:second)),
          customer_id: customer_id
        })

      topic = "notification:" <> account_id

      # Track the presence of this customer for the given account,
      # so agents can see the "online" status in the dashboard
      {:ok, _} =
        Presence.track(self(), topic, key, %{
          online_at: inspect(System.system_time(:second)),
          customer_id: customer_id
        })

      push(socket, "presence_state", Presence.list(socket))
      ChatApiWeb.Endpoint.broadcast!(topic, "presence_state", Presence.list(topic))
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, payload}, socket}
  end

  @decorate channel_action()
  def handle_in("shout", payload, socket) do
    Logger.warn(
      "'shout' is deprecated as event name on a new message and will be removed in a future version. Please migrate to a newer version of a client."
    )

    handle_incoming_message("shout", payload, socket)
  end

  @impl true
  def handle_in("message:created", payload, socket) do
    handle_incoming_message("message:created", payload, socket)
  end

  @decorate channel_action()
  def handle_in("messages:seen", _payload, socket) do
    with %{conversation: conversation} <- socket.assigns,
         %{id: conversation_id} <- conversation do
      Conversations.mark_agent_messages_as_seen(conversation_id)
    end

    {:noreply, socket}
  end

  @spec broadcast_new_message(any(), String.t(), Message.t()) :: Message.t()
  defp broadcast_new_message(socket, event_name, message) do
    broadcast(socket, event_name, Messages.Helpers.format(message))

    message
    |> Messages.Notification.broadcast_to_admin!(event_name)
    |> Messages.Notification.notify(:slack)
    # TODO: check if :slack_support_channel and :slack_company_channel are relevant
    |> Messages.Notification.notify(:slack_support_channel)
    |> Messages.Notification.notify(:slack_company_channel)
    |> Messages.Notification.notify(:mattermost)
    |> Messages.Notification.notify(:new_message_email)
    |> Messages.Notification.notify(:webhooks)
    |> Messages.Notification.notify(:push)
    |> Messages.Helpers.handle_post_creation_hooks()
  end

  defp handle_incoming_message(event_name, payload, socket) do
    with %{conversation: conversation} <- socket.assigns,
         %{id: conversation_id, account_id: account_id} <- conversation,
         {:ok, message} <-
           payload
           |> Map.merge(%{"conversation_id" => conversation_id, "account_id" => account_id})
           |> Messages.create_message() do
      case Map.get(payload, "file_ids") do
        file_ids when is_list(file_ids) -> Messages.create_attachments(message, file_ids)
        _ -> nil
      end

      message = Messages.get_message!(message.id)

      broadcast_new_message(socket, event_name, message)
    else
      _ ->
        broadcast(socket, event_name, payload)
    end

    {:noreply, socket}
  end

  # Add authorization logic here as required.
  @spec authorized?(any(), binary()) :: boolean()
  defp authorized?(_payload, conversation_id) do
    case Conversations.get_conversation(conversation_id) do
      %Conversations.Conversation{} -> true
      _ -> false
    end
  end
end
