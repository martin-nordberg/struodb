# 2. StruoDB Architecture — Event Collectors

## 2.1 Event Collector Variations

### 2.1.1 Event Collector Types

* **Web Browser Application** - The event collector is deployed as library code 
  within a larger JavaScript application running in a web browser. Events
  originate from user interaction with the browser.
* **Bun or NodeJS Application** - A custom JavaScript applications run in a 
  container or on a server. The application itself originates events by
  whatever mechanism is relevant for its domain (*e.g.* the node is the
  software controlling a specialized sensor).
* **Bun Service (with HTTP clients)** - A general purpose event collector
  operates as a web service collecting events from one or more external 
  clients who send event creation commands via HTTP calls.

### 2.1.2 Database Types

* **PGLite** - WASM edition of PostgreSQL that runs in browser, NodeJS, or Bun
* **PostgreSQL in Container** - For a container-deployed Bun service or a 
  custom NodeJS or Bun application, PostgreSQL runs in the same container.
* **Standalone PostgreSQL** - PostgreSQL is deployed separately from
  the event collector as a distinct database. 

| Collector Type      | PGLite | PostgreSQL in Container | Standalone PostgreSQL |
|---------------------|--------|-------------------------|-----------------------|
| **Web Browser App** | Yes    | Not Applicable          | No                    |
| **Bun/NodeJS App**  | Yes    | Custom                  | Yes                   |
| **Bun Service**     | Yes    | Yes                     | Yes                   |

### 2.1.3 Database Persistence

* In Memory / Ephemeral
* File-Based / Persistent

### 2.1.4 Event Aggregation Strategy

* **Sent Immediately Upon Collection** - Events are sent as soon as practical
  after they are received.
* **Sent in Batches by Size** - Events are held until a given number of events
  has been received, and then they are sent in a batch all at once.
* **Sent in Batches by Time Interval** - Events are sent when the oldest
  event reaches a given age. All newer events are sent at the same time.

### 2.1.5 Event Retention

* **Indefinite** - Events are never deleted by the event collector itself.
* **Removed After** Aggregation - Events are deleted from the event collector 
  database after they have been delivered to a given number of event aggregators.
* **Time-Limited** - Events are deleted from the event collector database
  after they have been delivered to a given number of event aggregators
  *and* a given time interval has elapsed since event creation.
* **Size-Limited** - Events are deleted, oldest first, when more than a given
  number of events has been created, regardless of whether they have been 
  successfully aggregated.
* **Age-limited** - Events are deleted when they are older than a given time
  interval, regardless of whether they have been successfully aggregated.

## 2.2 Event Collector Software Components

* **StruoQL Schema Migration** - Reads the migration commands for a schema.
  Ensures that the event collector's database is up-to-date with the
  schema and that the migration is append-only.
* **StruoQL Over HTTP** - For a Bun service event collector, accepts event
  creation (INSERT) commands via HTTP.
* **StruoQL Event Creation** - Transpiles StruoQL INSERT statements to
  PostgreSQL.
* **PostgreSQL Database I/O** - Sends StruoQL CREATE SCHEMA, ALTER SCHEMA, 
  and INSERT statements to the connected PostgreSQL database. Reads
  existing schema migration histories.
* **PGLite** - Implements the connected PostgreSQL database as inline
  PGLite.
* **Aggregator Registration** - Establishes communications with one or
  more event aggregators and sends the collector's schema to each
  aggregator.
* **Event Delivery** - Forwards events to one or more event aggregators.
* **Event Obsolescence** - Manages deletion of events according to a configured
  retention schedule.
