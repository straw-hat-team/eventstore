# Buffer Flush Architecture

This document provides a deep dive into the `buffer_flush_after` feature's architecture, design decisions, and implementation details.

## Table of Contents

- [Overview](#overview)
- [Problem Statement](#problem-statement)
- [Design Goals](#design-goals)
- [Architecture](#architecture)
- [Per-Partition Timer Design](#per-partition-timer-design)
- [Acknowledgement and Checkpointing](#acknowledgement-and-checkpointing)
- [State Machine Integration](#state-machine-integration)
- [Edge Cases](#edge-cases)
- [Performance Considerations](#performance-considerations)

## Overview

The `buffer_flush_after` feature provides bounded latency guarantees for event delivery by automatically flushing buffered events after a configurable timeout period. This ensures predictable event delivery during variable traffic patterns, particularly when using `buffer_size > 1` for throughput optimization.

## Problem Statement

### The Batching Dilemma

EventStore subscriptions support batching via `buffer_size` to optimize throughput:

```elixir
EventStore.subscribe_to_all_streams("my_sub", self(), buffer_size: 100)
```

**Benefits of batching:**
- Reduced per-event overhead
- Efficient database operations (batch inserts/updates)
- Better throughput for high-volume streams

**The problem:**
- During **high traffic**: Buffers fill quickly → good throughput ✅
- During **low traffic**: Events wait indefinitely for the Nth event ❌

### Real-World Impact

Consider a read model projector with `buffer_size: 1000`:

```elixir
defmodule ReadModelProjector do
  use Commanded.Event.Handler,
    batch_size: 1000  # Batch for DB performance
    
  def handle_batch(events) do
    Repo.transaction(fn ->
      Enum.each(events, &insert_into_read_model/1)
    end)
  end
end
```

**Scenario:**
- Business hours: 10,000 events/hour → batches flush every ~6 minutes ✅
- After hours: 10 events/hour → **events wait hours for the 1000th event** ❌
- **Result:** Stale read model during quiet periods

## Design Goals

1. **Bounded latency**: Guarantee maximum wait time for event delivery
2. **Maintain throughput**: Don't sacrifice batching benefits during high traffic
3. **Per-partition independence**: Support variable traffic across partitions
4. **Consistent replay**: Maintain checkpoint consistency for crash recovery
5. **Minimal overhead**: Low cost when not needed (buffer_flush_after: 0)

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────┐
│              Subscription FSM                            │
│                                                           │
│  ┌────────────────────────────────────────────────────┐ │
│  │         Partition-Based Event Queue                │ │
│  │                                                    │ │
│  │  Partition A: [event_100, event_101, event_104]  │ │
│  │  Partition B: [event_102]                         │ │
│  │  Partition C: [event_103]                         │ │
│  └────────────────────────────────────────────────────┘ │
│                          │                               │
│                          ▼                               │
│  ┌────────────────────────────────────────────────────┐ │
│  │         Per-Partition Timer Map                    │ │
│  │                                                    │ │
│  │  Partition A → timer_ref_A (fires in 5s)         │ │
│  │  Partition B → timer_ref_B (fires in 2s)         │ │
│  │  Partition C → timer_ref_C (fires in 7s)         │ │
│  └────────────────────────────────────────────────────┘ │
│                          │                               │
│                          ▼                               │
│  ┌────────────────────────────────────────────────────┐ │
│  │    Global Checkpoint Tracking                      │ │
│  │                                                    │ │
│  │  in_flight_event_numbers: [100, 101, 102, ...]   │ │
│  │  acknowledged_event_numbers: MapSet[100, 102, ...]│ │
│  │  last_ack: 102                                    │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### Data Structures

```elixir
defmodule SubscriptionState do
  defstruct [
    # Partition queues (partition_key → :queue.queue())
    partitions: %{},
    
    # Per-partition timers (partition_key → timer_ref)
    buffer_timers: %{},
    
    # Global event tracking (in event_number order)
    in_flight_event_numbers: [],
    acknowledged_event_numbers: MapSet.new(),
    
    # Single checkpoint for entire subscription
    last_ack: 0,
    
    # Configuration
    buffer_flush_after: 0,
    buffer_size: 1,
    partition_by: nil,
    # ... other fields
  ]
end
```

## Per-Partition Timer Design

### Why Per-Partition Timers?

Consider a subscription with multiple partitions (e.g., partitioned by stream):

```elixir
partition_by = fn event -> event.stream_uuid end

EventStore.subscribe_to_all_streams("my_sub", self(),
  buffer_size: 100,
  buffer_flush_after: 5_000,
  partition_by: partition_by
)
```

**Traffic pattern:**
- Stream A: 1000 events/second (corporate account)
- Stream B: 1 event/minute (personal account)

#### With Per-Partition Timers (Current Design) ✅

```
T=0s:   Stream A: Event arrives → buffer → timer starts
T=0.1s: Stream A: 100 events → buffer full → flush immediately
        (Timer cancelled because partition emptied)

T=0s:   Stream B: Event arrives → buffer → timer starts  
T=5s:   Stream B: Timer fires → flush 1 event
        (Bounded latency guaranteed!)
```

**Result:** Both streams get appropriate treatment:
- High-volume Stream A: Flushes on buffer_size (good throughput)
- Low-volume Stream B: Flushes on timeout (bounded latency)

#### Without Per-Partition Timers (Hypothetical) ❌

```
T=0s:   Stream A: Event arrives → global timer starts
T=0.1s: Stream A: 100 events → buffer full → flush immediately
        → RESETS global timer

T=0s:   Stream B: Event arrives → waiting for global timer
T=0.2s: Stream A: 100 more events → flush → RESETS global timer
T=0.4s: Stream A: 100 more events → flush → RESETS global timer
        (Stream A keeps resetting the timer!)

T=???:  Stream B: NEVER times out! (starved by Stream A)
```

**Result:** High-volume partition prevents low-volume partitions from timing out!

### Timer Lifecycle

```elixir
# 1. Timer starts when first event added to partition
defp enqueue_event(data, event) do
  partition_key = partition_key(data, event)
  is_new_partition = not Map.has_key?(data.partitions, partition_key)
  
  data = add_to_partition_queue(data, partition_key, event)
  
  if is_new_partition do
    maybe_start_partition_timer(data, partition_key)
  else
    data
  end
end

# 2. Timer fires → send :flush_buffer message
defp maybe_start_partition_timer(data, partition_key) do
  timer_ref = Process.send_after(
    self(), 
    {:flush_buffer, partition_key}, 
    data.buffer_flush_after
  )
  
  %{data | buffer_timers: Map.put(data.buffer_timers, partition_key, timer_ref)}
end

# 3. Handle timeout → flush partition
def handle_info({:flush_buffer, partition_key}, state) do
  data = 
    data
    |> clear_partition_timer(partition_key)  # Clear (not cancel)
    |> flush_partition_on_timeout(partition_key)
  
  {:noreply, data}
end

# 4. Timer cancelled when partition empties
defp notify_partition_subscriber(data, partition_key) do
  # ... send events to subscriber ...
  
  if partition_emptied do
    cancel_partition_timer(data, partition_key)
  else
    data
  end
end

# 5. Timer restarted if events remain after flush (subscriber at capacity)
defp flush_partition_on_timeout(data, partition_key) do
  data = notify_partition_subscriber(data, partition_key)
  
  case Map.get(data.partitions, partition_key) do
    nil -> 
      # Partition emptied, timer already cancelled
      data
    
    _remaining_events ->
      # Events remain, restart timer to ensure bounded latency
      maybe_start_partition_timer(data, partition_key)
  end
end
```

## Acknowledgement and Checkpointing

### The Critical Design Decision

**Question:** Should we maintain per-partition checkpoints or a single global checkpoint?

**Answer:** Single global checkpoint (current design)

### Why Global Checkpoints?

Events in EventStore have a **global sequential order** (event_number):

```
┌──────────────────────────────────────────────────┐
│ EventStore Database                               │
│                                                   │
│ event_number | stream_uuid | data                │
│ ─────────────────────────────────────────────────│
│ 100          | stream-A    | {...}               │
│ 101          | stream-A    | {...}               │
│ 102          | stream-B    | {...}   ← From diff │
│ 103          | stream-C    | {...}   ← streams! │
│ 104          | stream-A    | {...}               │
└──────────────────────────────────────────────────┘
```

**If we used per-partition checkpoints:**

```elixir
# Hypothetical (BAD) design
checkpoints: %{
  "stream-A" => 104,
  "stream-B" => 102,
  "stream-C" => 103
}
```

**Problem on restart:**
- Which checkpoint do we resume from?
- Event 102? 103? 104?
- We'd create inconsistent replay scenarios!

**With single global checkpoint:**

```elixir
# Current (GOOD) design
last_ack: 104  # Single number for entire subscription
```

**On restart:**
- Resume from event 105
- All partitions start from the same global position
- Consistent, predictable replay

### The Acknowledgement Algorithm

```elixir
# Events can be ACK'd out of order due to per-partition flush timing
acknowledged_event_numbers: MapSet.new([100, 102, 104])

# But checkpoint advances in sequential order
in_flight_event_numbers: [100, 101, 102, 103, 104]

# Walk through in_flight_event_numbers sequentially:
defp checkpoint_acknowledged(data) do
  [ack | rest] = data.in_flight_event_numbers
  
  if MapSet.member?(data.acknowledged_event_numbers, ack) do
    # Event is ACK'd, advance checkpoint
    data
    |> update_last_ack(ack)
    |> continue_with(rest)
    |> checkpoint_acknowledged()
  else
    # Hit a gap! Stop here.
    data
  end
end
```

**Example execution:**

```
State: in_flight = [100, 101, 102, 103, 104]
       acknowledged = MapSet[100, 102, 104]
       last_ack = 0

Step 1: Check 100 → ACK'd? YES ✓ → last_ack = 100
Step 2: Check 101 → ACK'd? NO  ✗ → STOP
Result: last_ack = 100 (cannot advance past gap at 101)

Later: Event 101 is ACK'd
       acknowledged = MapSet[101, 102, 104]
       
Step 1: Check 101 → ACK'd? YES ✓ → last_ack = 101
Step 2: Check 102 → ACK'd? YES ✓ → last_ack = 102
Step 3: Check 103 → ACK'd? NO  ✗ → STOP
Result: last_ack = 102
```

### Timeline Example

```
T=0s: Events arrive
  - Stream-A: #100, #101, #104 → Partition A queue
  - Stream-B: #102 → Partition B queue
  - Stream-C: #103 → Partition C queue

T=3s: Stream-B timer fires first (randomly)
  → Send event #102 to subscriber
  → Subscriber ACKs #102
  → acknowledged = [102]
  → Checkpoint algorithm:
     Check 100: NOT ACK'd → STOP
     last_ack = 0 (cannot advance)

T=5s: Stream-A timer fires
  → Send events #100, #101, #104 to subscriber
  → Subscriber ACKs #104 (ACKs entire batch)
  → acknowledged = [100, 101, 102, 104]
  → Checkpoint algorithm:
     Check 100: ACK'd → last_ack = 100
     Check 101: ACK'd → last_ack = 101
     Check 102: ACK'd → last_ack = 102
     Check 103: NOT ACK'd → STOP
     last_ack = 102

T=10s: Stream-C timer fires
  → Send event #103 to subscriber
  → Subscriber ACKs #103
  → acknowledged = [103, 104]
  → Checkpoint algorithm:
     Check 103: ACK'd → last_ack = 103
     Check 104: ACK'd → last_ack = 104
     last_ack = 104 ✓ All done!

T=10s: Checkpoint persisted to database
  → Storage.Subscription.ack_last_seen_event(..., last_ack: 104)
```

## State Machine Integration

The buffer flush behavior integrates with the subscription FSM across multiple states:

### State: `subscribed`

Normal operation when caught up with the event store.

```elixir
defstate subscribed do
  defevent flush_buffer(partition_key), data: data do
    data =
      data
      |> clear_partition_timer(partition_key)
      |> flush_partition_on_timeout(partition_key)
    
    next_state(:subscribed, data)
  end
end
```

**Behavior:** Flush the partition, send events to subscribers.

### State: `max_capacity`

When subscriber is overwhelmed with in-flight events.

```elixir
defstate max_capacity do
  defevent flush_buffer(partition_key), data: data do
    data =
      data
      |> clear_partition_timer(partition_key)
      |> flush_partition_on_timeout(partition_key)  # Attempts to send
    
    # Events likely remain (subscriber still at capacity)
    # Restart timer to ensure bounded latency
    data =
      case Map.get(data.partitions, partition_key) do
        nil -> data  # Partition emptied somehow
        _remaining -> maybe_start_partition_timer(data, partition_key)
      end
    
    next_state(:max_capacity, data)
  end
end
```

**Behavior:** Attempt to flush, but if subscriber still at capacity, restart timer to ensure eventual delivery.

### State: `catching_up` / `request_catch_up`

Reading historical events from storage.

```elixir
defstate catching_up do
  defevent flush_buffer(partition_key), data: data do
    # Simply clear timer, catch-up process handles delivery
    data = clear_partition_timer(data, partition_key)
    next_state(:catching_up, data)
  end
end
```

**Behavior:** Clear timer without attempting flush, as the catch-up process reads events directly from storage in batches.

## Edge Cases

### 1. Timer fires while at max_capacity

**Scenario:**
- Subscriber is processing many in-flight events
- Timer fires for a partition

**Handling:**
```elixir
# max_capacity state handler
defevent flush_buffer(partition_key) do
  # Try to send (likely fails due to capacity)
  data = flush_partition_on_timeout(data, partition_key)
  
  # If events remain, restart timer
  data = 
    if partition_has_events?(data, partition_key) do
      maybe_start_partition_timer(data, partition_key)
    else
      data
    end
end
```

**Result:** Timer automatically restarts, ensuring bounded latency even when subscriber is slow.

### 2. Partition becomes empty before timer fires

**Scenario:**
- Timer started when event arrived
- `buffer_size` reached before timeout
- Partition flushed and emptied

**Handling:**
```elixir
defp notify_partition_subscriber(data, partition_key) do
  # ... send events ...
  
  if partition_emptied do
    cancel_partition_timer(data, partition_key)  # Clean up
  end
end
```

**Result:** Timer cancelled, no spurious timeout message.

### 3. Multiple timers fire simultaneously

**Scenario:**
- Several partitions reach timeout at the same time

**Handling:**
```elixir
# Each partition timer sends a distinct message
{:flush_buffer, "stream-A"}
{:flush_buffer, "stream-B"}
{:flush_buffer, "stream-C"}

# Processed sequentially by FSM
defstate subscribed do
  defevent flush_buffer(partition_key) do
    # Each partition handled independently
    flush_partition_on_timeout(data, partition_key)
  end
end
```

**Result:** Each partition flushed independently, maintaining isolation.

### 4. Subscription stops/restarts

**Scenario:**
- Subscription crashes or is stopped
- Timers are lost

**Handling:**
```elixir
# On startup
def init(opts) do
  # Timers are NOT restored
  # Events will be read from storage during catch-up
  # New timers start as events are enqueued
end

# On stop
def terminate(_reason, _state) do
  # Timers automatically cleaned up by process termination
  :ok
end
```

**Result:** Graceful handling, no timer leaks, consistent replay from checkpoint.

## Performance Considerations

### Memory Overhead

**Per-partition data:**
```elixir
partitions: %{
  partition_key => :queue.queue()  # ~40 bytes + event data
}

buffer_timers: %{
  partition_key => timer_ref  # ~8 bytes per timer
}
```

**Worst case (100 partitions):**
- Timer refs: 100 × 8 bytes = 800 bytes
- Queue overhead: 100 × 40 bytes = 4 KB
- **Total overhead: ~5 KB** (negligible)

### CPU Overhead

**When `buffer_flush_after: 0` (disabled):**
- Zero overhead: `maybe_start_partition_timer` returns immediately
- No timers created

**When enabled:**
- `Process.send_after/3`: ~1-2 μs (microseconds)
- Timer cleanup: ~0.5 μs
- **Total per partition: <3 μs** (negligible)

### Timer Scalability

**Erlang timer wheel:**
- Efficient for thousands of concurrent timers
- O(1) timer insertion and cancellation
- Tested with 1000+ concurrent partitions (see test suite)

**Practical limits:**
- 10,000 partitions: No measurable impact
- 100,000 partitions: Still performs well
- Memory and event processing are the bottlenecks, not timers

## Summary

The `buffer_flush_after` feature provides:

1. ✅ **Bounded latency** through per-partition timers
2. ✅ **High throughput** by not interfering with buffer_size-based flushing
3. ✅ **Partition independence** preventing starvation
4. ✅ **Consistent replay** via global checkpoint ordering
5. ✅ **Low overhead** when disabled or with few partitions

The design carefully balances:
- Per-partition **delivery timing** (independent timers)
- Global **checkpoint consistency** (sequential acknowledgement)

This ensures both predictable latency AND reliable event replay guarantees.
