# Subscriptions

There are two types of subscriptions provided by EventStore:

1. [Transient subscriptions](#transient-subscriptions) where new events are broadcast to subscribers immediately after they have been appended to storage.
2. [Persistent subscriptions](#persistent-subscriptions) which guarantee at-least-once delivery of every persisted event, provide back-pressure, and can be started, paused, and resumed from any position, including from the stream's origin.

## Event pub/sub

PostgreSQL's `LISTEN` and `NOTIFY` commands are used to pub/sub event notifications from the database. An after update trigger on the `streams` table is used to execute `NOTIFY` for each batch of inserted events. The notification payload contains the stream uuid, stream id, and first / last stream versions (e.g. `stream-12345,1,1,5`).

A single process will connect to the database to listen for these notifications. It fetches the event data and broadcasts to all interested subscriptions. This approach supports running an EventStore on multiple nodes, regardless of whether they are connected together to form a cluster using distributed Erlang. One connection per node is used for single node and multi-node deployments.

## Transient subscriptions

Use `c:EventStore.subscribe/2` to create a transient subscription to a single stream identified by its `stream_uuid`. Events will be received in batches as an `{:events, events}` message, where `events` is a collection of `EventStore.RecordedEvent` structs.

You can use `$all` as the stream identity to subscribe to events appended to all streams. With transient subscriptions you do not need to acknowledge receipt of the published events. The subscription will terminate when the subscriber process stops running.

#### Subscribe to single stream events

Subscribe to events appended to a *single* stream:

```elixir
alias MyApp.EventStore

:ok = EventStore.subscribe(stream_uuid)

# receive first batch of events
receive do
  {:events, events} ->
    IO.puts("Received events: " <> inspect(events))
end
```

#### Filtering events

You can provide an event selector function that filters each `RecordedEvent` before sending it to the subscriber:

```elixir
alias EventStore.RecordedEvent
alias MyApp.EventStore

EventStore.subscribe(stream_uuid, selector: fn
  %RecordedEvent{data: data} -> data != nil
end)

# receive first batch of mapped event data
receive do
  {:events, %RecordedEvent{} = event_data} ->
    IO.puts("Received non nil event data: " <> inspect(event_data))
end
```

#### Mapping events

You can provide an event mapping function that maps each `RecordedEvent` before sending it to the subscriber:

```elixir
alias EventStore.RecordedEvent
alias MyApp.EventStore

EventStore.subscribe(stream_uuid, mapper: fn
  %RecordedEvent{data: data} -> data
end)

# receive first batch of mapped event data
receive do
  {:events, event_data} ->
    IO.puts("Received event data: " <> inspect(event_data))
end
```

## Persistent subscriptions

Persistent subscriptions to a stream will guarantee *at least once* delivery of every persisted event. Each subscription may be independently paused, then later resumed from where it stopped. The last received and acknowledged event is stored by the EventStore to support resuming at a later time or whenever the subscriber process restarts.

A subscription can be created to receive events appended to a single or all streams.

Subscriptions must be uniquely named. By default a subscription only supports a single subscriber. Attempting to connect two subscribers to the same subscription will return `{:error, :subscription_already_exists}`. You can optionally create a [competing consumer subscription with multiple subscribers](#subscription-concurrency).

### `:subscribed` message

Once the subscription has successfully subscribed to the stream it will send the subscriber a `{:subscribed, subscription}` message. This indicates the subscription succeeded and you will begin receiving events.

Only one instance of a named subscription to a stream can connect to the database. This guarantees that starting the same subscription on each node when run on a cluster, or when running multiple single instance nodes, will only allow one subscription to actually connect. Therefore you can defer any initialisation until receipt of the `{:subscribed, subscription}` message to prevent duplicate effort by multiple nodes racing to create or subscribe to the same subscription.

### `:events` message

For each batch of events appended to the event store your subscriber will receive a `{:events, events}` message. The `events` list is a collection of `EventStore.RecordedEvent` structs.

### Subscription start from

By default subscriptions are created from the stream origin; they will receive all events from the stream. You can optionally specify a given start position:

- `:origin` - subscribe to events from the start of the stream (identical to using `0`). This is the default behaviour.
- `:current` - subscribe to events from the current version.
- `event_number` (integer) - specify an exact event number to subscribe from. This will be the same as the stream version for single stream subscriptions.

### Acknowledge received events

Receipt of each event by the subscriber must be acknowledged. This allows the subscription to resume on failure without missing an event and to indicate the subscription is ready to receive the next event.

The subscriber receives an `{:events, events}` tuple containing the published events. A subscription is returned when subscribing to the stream. This should be used to send the acknowledgement to using the `c:EventStore.ack/2` function:

 ```elixir
 alias MyApp.EventStore

 :ok = EventStore.ack(subscription, events)
 ```

A subscriber can confirm receipt of each event in a batch by sending multiple acks, one per event. The subscriber may confirm receipt of the last event in the batch in a single ack.

A subscriber will not receive further published events until it has confirmed receipt of all received events. This provides back pressure to the subscription to prevent the subscriber from being overwhelmed with messages if it cannot keep up. The subscription will buffer events until the subscriber is ready to receive, or an overflow occurs. At which point it will move into a catch-up mode and query events and replay them from storage until caught up.

#### Subscribe to all events

Subscribe to events appended to all streams:

```elixir
alias MyApp.EventStore

{:ok, subscription} = EventStore.subscribe_to_all_streams("example_all_subscription", self())

# Wait for the subscription confirmation
receive do
  {:subscribed, ^subscription} ->
    IO.puts("Successfully subscribed to all streams")
end

receive do
  {:events, events} ->
    IO.puts "Received events: #{inspect events}"

    # Acknowledge receipt
    :ok = EventStore.ack(subscription, events)
end
```

Unsubscribe from all streams:

```elixir
alias MyApp.EventStore

:ok = EventStore.unsubscribe_from_all_streams("example_all_subscription")
```

#### Subscribe to single stream events

Subscribe to events appended to a *single* stream:

```elixir
alias MyApp.EventStore

stream_uuid = EventStore.UUID.uuid4()
{:ok, subscription} = EventStore.subscribe_to_stream(stream_uuid, "example_single_subscription", self())

# Wait for the subscription confirmation
receive do
  {:subscribed, ^subscription} ->
    IO.puts("Successfully subscribed to single stream")
end

receive do
  {:events, events} ->
    # Process events & acknowledge receipt
    :ok = EventStore.ack(subscription, events)
end
```

Unsubscribe from a single stream:

```elixir
alias MyApp.EventStore

:ok = EventStore.unsubscribe_from_stream(stream_uuid, "example_single_subscription")
```

#### Start subscription from a given position

You can choose to receive events from a given starting position.

The supported options are:

  - `:origin` - Start receiving events from the beginning of the stream or all streams (default).
  - `:current` - Subscribe to newly appended events only, skipping already persisted events.
  - `event_number` (integer) - Specify an exact event number to subscribe from. This will be the same as the stream version for single stream subscriptions.

Example all stream subscription that will receive new events appended after the subscription has been created:

```elixir
alias MyApp.EventStore

{:ok, subscription} = EventStore.subscribe_to_all_streams("example_subscription", self(), start_from: :current)
```

#### Event Filtering

You can provide an event selector function that run in the subscription process, before sending the event to your mapper and subscriber. You can use this to filter events before dispatching to a subscriber.

Subscribe to all streams and provide a `selector` function that only sends data that the selector function returns `true` for.

```elixir
alias EventStore.RecordedEvent
alias MyApp.EventStore

selector = fn %RecordedEvent{event_number: event_number} ->
  rem(event_number) == 0
end

{:ok, subscription} = EventStore.subscribe_to_all_streams("example_subscription", self(), selector: selector)

# wait for the subscription confirmation
receive do
  {:subscribed, ^subscription} ->
    IO.puts("Successfully subscribed to all streams")
end

receive do
  {:events, filtered_events} ->
    # ... process events & ack receipt using last `event_number`
    RecordedEvent{event_number: event_number} = List.last(filtered_events)

    :ok = EventStore.ack(subscription, event_number)
end
```

#### Mapping events

You can provide an event mapping function that runs in the subscription process, before sending the event to your subscriber. You can use this to change the data received.

Subscribe to all streams and provide a `mapper` function that sends only the event data:

```elixir
alias EventStore.RecordedEvent
alias MyApp.EventStore

mapper = fn %RecordedEvent{event_number: event_number, data: data} ->
  {event_number, data}
end

{:ok, subscription} = EventStore.subscribe_to_all_streams("example_subscription", self(), mapper: mapper)

# wait for the subscription confirmation
receive do
  {:subscribed, ^subscription} ->
    IO.puts("Successfully subscribed to all streams")
end

receive do
  {:events, mapped_events} ->
    # ... process events & ack receipt using last `event_number`
    {event_number, _data} = List.last(mapped_events)

    :ok = EventStore.ack(subscription, event_number)
end
```

### Subscription concurrency

A single persistent subscription can support multiple subscribers. Events will be distributed to subscribers evenly using a round-robin algorithm. The [competing consumers pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/competing-consumers) enables multiple subscribers to process events concurrently to optimise throughput, to improve scalability and availability, and to balance the workload.

By default a subscription will only allow a single subscriber but you can opt-in to concurrent subscriptions be providing a non-negative `concurrency_limit` as a subscription option.

#### Subscription concurrency configuration options

- `concurrency_limit` defines the maximum number of concurrent subscribers allowed to connect to the subscription. By default only one subscriber may connect. If too many subscribers attempt to connect to the
  subscription an `{:error, :too_many_subscribers}` is returned.

- `buffer_size` limits how many in-flight events will be sent to the subscriber process before acknowledgement of successful processing. This limits the number of messages sent to the subscriber and stops their message queue from getting filled with events. Defaults to one in-flight event.

- `buffer_flush_after` (milliseconds) ensures events are flushed to the subscriber after a period of time even if the buffer size has not been reached. This ensures events are delivered with bounded latency during less busy periods. When set to 0 (default), no time-based flushing is performed and events are only sent when the buffer_size is reached. Each partition has its own independent timer. If a subscriber is at capacity when the timer fires, events remain queued and the timer is automatically restarted to ensure eventual delivery with bounded latency. See [Buffer Flush Behavior](#buffer-flush-behavior) for detailed information.

- `partition_by` is an optional function used to partition events to subscribers. It can be used to guarantee processing order when multiple subscribers have subscribed to a single subscription as described in [Ordering guarantee](#ordering-guarantee) below. The function is passed a single argument (an `EventStore.RecordedEvent` struct) and must return the partition key. As an example to guarantee events for a single stream are processed serially, but different streams are processed concurrently, you could use the `stream_uuid` as the partition key.

### Ordering guarantee

With multiple subscriber processes connected to a single subscription the ordering of event processing is no longer guaranteed since events may be processed in differing amounts of time. This can cause problems if your event handling code expects events to be processed in the order they were originally appended to a steam.

You can use a `partition_by` function to guarantee ordering of events within a particular group (e.g. per stream) but still allow events for different groups to be processed concurrently.


Partitioning gives you the benefits of competing consumers but still allows event ordering by partition where required.

#### Partition by example

```elixir
alias EventStore.RecordedEvent
alias MyApp.EventStore

by_stream = fn %RecordedEvent{stream_uuid: stream_uuid} -> stream_uuid end

{:ok, _subscription} =
  EventStore.subscribe_to_stream(stream_uuid, "example", self(),
    concurrency_limit: 10,
    partition_by: by_stream
  )
```

The above subscription would ensure that events for each stream are processed serially (by a single subscriber) in the order they were appended to the stream, but events for any other stream can be processed concurrently by another subscriber.

### Example persistent subscriber

Use a `GenServer` process to subscribe to the event store and track all notified events:

```elixir
# An example subscriber
defmodule Subscriber do
  use GenServer

  alias MyApp.EventStore

  def start_link do
    GenServer.start_link(__MODULE__, [])
  end

  def received_events(subscriber) do
    GenServer.call(subscriber, :received_events)
  end

  def init(events) do
    # Subscribe to events from all streams
    {:ok, subscription} = EventStore.subscribe_to_all_streams("example_subscription", self())

    {:ok, %{events: events, subscription: subscription}}
  end

  # Successfully subscribed to all streams
  def handle_info({:subscribed, subscription}, %{subscription: subscription} = state) do
    {:noreply, state}
  end

  # Event notification
  def handle_info({:events, events}, state) do
    %{events: existing_events, subscription: subscription} = state

    # Confirm receipt of received events
    :ok = EventStore.ack(subscription, events)

    {:noreply, %{state | events: existing_events ++ events}}
  end

  def handle_call(:received_events, _from, %{events: events} = state) do
    {:reply, events, state}
  end
end
```

Start your subscriber process, which subscribes to all streams in the event store:

```elixir
{:ok, subscriber} = Subscriber.start_link()
```

## Buffer Flush Behavior

The `buffer_flush_after` option provides bounded latency guarantees for event delivery by automatically flushing buffered events after a timeout period. This is particularly useful when using `buffer_size > 1` for throughput optimization but still requiring predictable latency during low-traffic periods.

### How It Works

#### Without `buffer_flush_after`

```elixir
{:ok, subscription} = 
  EventStore.subscribe_to_all_streams("my_sub", self(), 
    buffer_size: 100
  )
```

**Behavior:**
- Events are buffered until 100 events accumulate
- During high traffic: ✅ Batches flush quickly (good throughput)
- During low traffic: ❌ Events wait indefinitely for the 100th event
- **Problem:** Read models can become stale during quiet periods

#### With `buffer_flush_after`

```elixir
{:ok, subscription} = 
  EventStore.subscribe_to_all_streams("my_sub", self(), 
    buffer_size: 100,
    buffer_flush_after: 5_000  # 5 seconds
  )
```

**Behavior:**
- Events are buffered until 100 events **OR** 5 seconds, whichever comes first
- During high traffic: ✅ Batches flush when full (good throughput)
- During low traffic: ✅ Partial batches flush after 5s (bounded latency)
- **Result:** Predictable latency regardless of traffic patterns

### Per-Partition Timers

When using `partition_by`, each partition maintains its own independent timer:

```elixir
{:ok, subscription} = 
  EventStore.subscribe_to_all_streams("my_sub", self(),
    buffer_size: 100,
    buffer_flush_after: 5_000,
    partition_by: fn event -> event.stream_uuid end
  )
```

**Why per-partition timers are necessary:**

Consider a scenario with different traffic patterns per partition:
- Stream A: 1000 events/second (high volume)
- Stream B: 1 event/minute (low volume)

**With per-partition timers (current design):**
- Stream A: Buffer fills quickly → flushes on `buffer_size`
- Stream B: Buffer doesn't fill → timer fires after 5s → flushes partial batch
- ✅ Both streams get timely delivery

**Without per-partition timers (hypothetical):**
- Stream A: Buffer fills quickly → flushes → **resets global timer**
- Stream B: Waits for global timer → **but Stream A keeps resetting it!**
- ❌ Stream B's events never time out → stale data

### Acknowledgement and Checkpointing

**Important:** While partitions have independent flush timers, acknowledgements and checkpoints respect **global event ordering**.

#### The Flow

1. **Events arrive** across multiple partitions:
   ```
   Stream-A: Event #100, #101, #104
   Stream-B: Event #102
   Stream-C: Event #103
   ```

2. **Per-partition timers** control when events are sent to subscribers:
   ```
   T=0s:  All events buffered
   T=5s:  Stream-B timer fires → Event #102 sent to subscriber
   T=5.1s: Stream-A timer fires → Events #100, #101, #104 sent
   T=10s: Stream-C timer fires → Event #103 sent
   ```

3. **Subscriber acknowledges** events:
   ```elixir
   # Subscriber receives Stream-B events first (due to timer)
   {:events, [event_102]} -> :ok = EventStore.ack(subscription, event_102)
   
   # Then Stream-A events
   {:events, [event_100, event_101, event_104]} -> 
     :ok = EventStore.ack(subscription, event_104)  # ACKs all in batch
   
   # Finally Stream-C events
   {:events, [event_103]} -> :ok = EventStore.ack(subscription, event_103)
   ```

4. **Checkpoint advances** in global event order:
   ```
   After ACK 102: Checkpoint cannot advance (event 100 not ACK'd yet)
   After ACK 104: Checkpoint advances to 102 (100, 101, 102 all ACK'd)
   After ACK 103: Checkpoint advances to 104 (all events ACK'd)
   ```

**Key insight:** Events from different partitions can be **delivered at different times**, but the checkpoint always advances in **global event number order** to ensure consistent replay on restart.

### Use Cases

#### Read Model Projections with Batching

```elixir
defmodule MyApp.ReadModelProjector do
  use Commanded.Event.Handler,
    application: MyApp,
    name: __MODULE__,
    batch_size: 1000,  # Batch for database performance
    buffer_flush_after: 5_000  # But don't wait forever

  def handle_batch(events) do
    Repo.transaction(fn ->
      # Insert 1000 events efficiently
      Enum.each(events, &insert_into_read_model/1)
    end)
    :ok
  end
end
```

**Benefits:**
- High traffic: Efficient 1000-event batches
- Low traffic: Events still delivered within 5 seconds
- Predictable read model freshness

#### Per-Stream Processing with Variable Traffic

```elixir
{:ok, subscription} = 
  EventStore.subscribe_to_all_streams("processor", self(),
    buffer_size: 50,
    buffer_flush_after: 3_000,
    partition_by: fn event -> event.stream_uuid end,
    concurrency_limit: 10
  )
```

**Benefits:**
- Each stream processed independently
- High-volume streams don't block low-volume streams
- All streams get 3-second latency guarantee

### Configuration Guidelines

**Choose `buffer_size` based on throughput needs:**
- `buffer_size: 1` (default) - Lowest latency, no batching needed
- `buffer_size: 10-100` - Good balance for most use cases
- `buffer_size: 1000+` - High-throughput batch processing

**Choose `buffer_flush_after` based on latency requirements:**
- `buffer_flush_after: 0` (default) - No timeout (only flush on buffer_size)
- `buffer_flush_after: 1_000` - 1 second max latency (real-time systems)
- `buffer_flush_after: 5_000` - 5 second max latency (typical read models)
- `buffer_flush_after: 30_000` - 30 second max latency (background processing)

**Rule of thumb:**
```elixir
# If you set buffer_size > 1, you probably want buffer_flush_after too
{:ok, subscription} = 
  EventStore.subscribe_to_all_streams("my_sub", self(),
    buffer_size: 100,
    buffer_flush_after: 5_000  # Don't let events sit indefinitely!
  )
```

### Deleting a persistent subscription

You can delete a single stream or all stream subscription without requiring an active subscriber:

```elixir
alias MyApp.EventStore

:ok = EventStore.delete_subscription(stream_uuid, subscription_name)
:ok = EventStore.delete_all_streams_subscription(subscription_name)
```

Deleting the subscription will remove the subscription checkpoint allowing you to later create a subscription with the same name, using any start point.

If there is an active subscriber when deleting the subscription it will be stopped.
