# 4. StruoDB Architecture — Event Aggregators

## 4.1 Incoming Events

## 4.2 Synchronization With Other Aggregators

## 4.3 Query Interface for Projections



## 4.4 Event Aggregator Software Components

* **Event Store** - The composite component that stores and forwards events.
* **StruoQL Over HTTP** - Accepts event creation (INSERT) commands via HTTP.
* **Collector Registration** - Provides a web service for event collectors and
  other aggregators to register as event sources to this aggregator.
  Returns the aggregator's schema migration script for use by the collector.
  Registration is per stream.
