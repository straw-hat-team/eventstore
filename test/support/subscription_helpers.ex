defmodule EventStore.SubscriptionHelpers do
  import ExUnit.Assertions

  alias EventStore.{EventFactory, RecordedEvent, UUID}
  alias EventStore.Subscriptions.Subscription
  alias TestEventStore, as: EventStore

  def append_to_stream(stream_uuid, event_count, expected_version \\ 0) do
    events = EventFactory.create_events(event_count, expected_version + 1)

    :ok = EventStore.append_to_stream(stream_uuid, expected_version, events)
  end

  def subscribe_to_all_streams(opts) when is_list(opts) do
    subscription_name = UUID.uuid4()
    {:ok, subscription} = EventStore.subscribe_to_all_streams(subscription_name, self(), opts)

    assert_receive {:subscribed, ^subscription}

    {:ok, subscription}
  end

  def subscribe_to_all_streams(subscription_name, subscriber, opts \\ []) do
    {:ok, subscription} = EventStore.subscribe_to_all_streams(subscription_name, subscriber, opts)

    assert_receive {:subscribed, ^subscription}

    {:ok, subscription}
  end

  def collect_and_ack_events(subscription_pid, timeout: timeout) do
    collect_and_ack_with_timeout(subscription_pid, [], timeout)
  end

  def collect_all_batches(subscription_pid, timeout: timeout) do
    collect_batches_with_timeout(subscription_pid, [], timeout)
  end

  def assert_event_numbers(events, expected_numbers) do
    actual_numbers = Enum.map(events, & &1.event_number)
    assert actual_numbers == expected_numbers
  end

  def assert_per_stream_order(events) do
    events
    |> Enum.group_by(& &1.stream_uuid)
    |> Enum.each(fn {_stream_uuid, stream_events} ->
      numbers = Enum.map(stream_events, & &1.event_number)
      assert numbers == Enum.sort(numbers)
    end)
  end

  def start_subscriber do
    reply_to = self()

    spawn_link(fn -> receive_events(reply_to) end)
  end

  def receive_events(reply_to) do
    receive do
      {:subscribed, subscription} ->
        send(reply_to, {:subscribed, subscription, self()})

      {:events, events} ->
        send(reply_to, {:events, events, self()})
    end

    receive_events(reply_to)
  end

  def assert_receive_events(expected_event_numbers, expected_subscriber) do
    assert_receive {:events, received_events, ^expected_subscriber}

    actual_event_numbers = Enum.map(received_events, & &1.event_number)
    assert expected_event_numbers == actual_event_numbers
  end

  def receive_and_ack(subscription, expected_stream_uuid, expected_intial_event_number) do
    assert_receive {:events, received_events}
    refute_receive {:events, _received_events}
    assert length(received_events) == 10

    received_events
    |> Enum.with_index(expected_intial_event_number)
    |> Enum.each(fn {event, expected_event_number} ->
      %RecordedEvent{event_number: event_number} = event

      assert event_number == expected_event_number
      assert event.stream_uuid == expected_stream_uuid

      :ok = Subscription.ack(subscription, event)
    end)
  end

  defp collect_and_ack_with_timeout(_subscription_pid, acc, remaining_timeout)
       when remaining_timeout <= 0 do
    acc
  end

  defp collect_and_ack_with_timeout(subscription_pid, acc, remaining_timeout) do
    start = System.monotonic_time(:millisecond)

    receive do
      {:events, events} ->
        :ok = Subscription.ack(subscription_pid, events)
        elapsed = System.monotonic_time(:millisecond) - start
        new_timeout = remaining_timeout - elapsed
        collect_and_ack_with_timeout(subscription_pid, acc ++ events, new_timeout)
    after
      min(remaining_timeout, 200) ->
        acc
    end
  end

  defp collect_batches_with_timeout(_subscription_pid, acc, remaining_timeout)
       when remaining_timeout <= 0 do
    Enum.reverse(acc)
  end

  defp collect_batches_with_timeout(subscription_pid, acc, remaining_timeout) do
    start = System.monotonic_time(:millisecond)

    receive do
      {:events, batch} ->
        :ok = Subscription.ack(subscription_pid, batch)
        elapsed = System.monotonic_time(:millisecond) - start
        new_timeout = remaining_timeout - elapsed
        collect_batches_with_timeout(subscription_pid, [batch | acc], new_timeout)
    after
      min(remaining_timeout, 200) ->
        elapsed = System.monotonic_time(:millisecond) - start
        new_timeout = remaining_timeout - elapsed
        collect_batches_with_timeout(subscription_pid, acc, new_timeout)
    end
  end
end
