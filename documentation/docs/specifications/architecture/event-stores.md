# 2. StruoDB Architecture — Event Stores

## 2.1 Summary

An event store is a facility for storing incoming events and propagating them
to one or more linked aggregators. Both event collectors and event aggregators
contain an event store. For an event collector the store is filled by newly 
created events. For an event aggregator the store is filled by events forwarded
from collectors or other aggregators.

## 2.2 Supporting Changes in Existing Specs and Code

* Note that the existing ./service code is just temporary for testing TypeScript
  calls to Gleam code and will soon be obsolete.
* In ddl_spec.md and associated code, whenever a table is created for a stream,
  two additional tables are created to track migration history and pending 
  aggregations. CREATE STREAM transpilation needs expansion to something like:
  ```
  -- Existing
  CREATE TABLE <stream name> ...
  
  -- New
  CREATE TABLE _struo_<stream_name>_migration_history(
    seq INTEGER NOT NULL PRIMARY KEY, 
    hash CHAR(64) NOT NULL
  );
    
  CREATE TABLE _struo_<stream_name>_pending_aggregations (
    aggregator_node_id INTEGER NOT NULL,
    event_hlc CHAR(15) NOT NULL REFERENCES <stream name>(_struo_hlc) ON DELETE CASCADE,
    PRIMARY KEY (aggregator_node_id, event_hlc)
  );
  ```
  Notes: 
    1. _struo_<stream_name>_pending_aggregations will have considerable churn
       so will need tuning to handle heavy inserts and deletes (no updates).
    2. The "ON DELETE CASCADE" allows deletion of delayed pending aggregations if
       an event has been delivered to a quorum (possibly a minority) of other aggregators.
* In dml_spec.md and associated code, StruoQL INSERT transpilation needs to be
  passed an additional parameter, a list of integer aggregator node IDs.
  The output SQL INSERT needs to be expanded to insert records
  into _struo_<stream name>_pending_aggregations along with the existing
  stream insertions, one pending record for every event and aggregator
  combination.

## 2.3 Event Store Variations

### 2.3.1 Database Types

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

### 2.3.2 Database Persistence Types

* In Memory / Ephemeral
* File-Based / Persistent

### 2.3.3 Event Aggregation Strategies

* **Sent Immediately Upon Collection** - Events are sent as soon as practical
  after they are received.
* **Sent in Batches by Size** - Events are held until a given number of events
  has been received, and then they are sent in a batch all at once.
* **Sent in Batches by Time Interval** - Events are sent when the oldest
  event reaches a given age. All newer events are sent at the same time.
* **Shared Database/Not Sent** - Events stored in a database are immediately 
  shared with its one aggregator simply by having both share the same database.

### 2.3.4 Event Retention Strategies

* **Indefinite** - Events are never deleted by the event collector itself.
* **Removed After Aggregation** - Events are deleted from the event collector 
  database after they have been delivered to a quorum of event aggregators
  (a number greater than zero and less than or equal to the total number of aggregators
  for the stream).
* **Time-Limited** - Events are deleted from the event collector database
  after they have been delivered to a quorum of event aggregators
  (a number greater than zero and less than or equal to the total number of aggregators
  for the stream) *and* a given time interval has elapsed since event creation 
  (meaning _struo_created_at, not _struo_hlc_timestamp).

## 2.4 Event Store Software Components

* **StruoQL Schema Migration** - Applies the migration commands for a schema.
  Ensures that the event collector's database is up-to-date with the
  schema and that the migration is append-only.
* **StruoQL Event Creation** - Transpiles StruoQL INSERT statements to
  PostgreSQL and executes them against the database.
* **Database Repository** - Sends StruoQL CREATE SCHEMA, ALTER SCHEMA, 
  and INSERT statements to the connected PostgreSQL database. Reads
  existing schema migration histories and writes new migration hash codes
  as migrations occur. Deletes events when the retention strategy results
  in their obsolescence.
* **PGLite** - Implements the connected PostgreSQL database as inline
  PGLite.
* **Aggregator Registration** - Establishes communications with one or
  more event aggregators and retrieves the aggregator's schema for application
  within this collector.
* **Event Delivery** - Forwards events to one or more event aggregators.
* **Event Obsolescence** - Manages deletion of events according to a configured
  retention schedule.

## 2.5 Event Store Configuration

* The PostgreSQL Database connection URL
* A list of one or more stream names
* A list of aggregator node IDs
* For each stream: 
  - The defining StruoQL migration sequence
  - A list of aggregators for the stream by node ID
  - For each aggregator of this stream:
    o the aggregation strategy
    o the retention strategy
* For each aggregator:
  - The HTTP base endpoint URL for registration and event delivery
TODO: Define a JSON format for the above

## 2.6 Event Store Logic

### 2.6.1 Schema Migration Sub-Logic

* The containing application reads the existing stream migration hash codes
  via the Database Repository (_struo_<stream_name>_migration_history ordered
  by seq).
* The containing application calls applyMigration to determine the PostgreSQL
  needed to update the schema.
* The containing application calls Database Repository to
  execute the CREATE/ALTER TABLE statements.
* The containing application calls Database Repository to
  INSERT any new hash codes for the stream migration steps.

### 2.6.2 Application Initialization

* The containing application starts.
* The containing application initializes the event store configuration.
* For each stream directly defined by the store (e.g. in a config file):
  - The containing application reads the stream's schema definition 
    (sequence of migrations).
  - The schema migrations steps of §2.6.1 are completed.
* For each stream supported by the store:
  - For each aggregator defined for the stream:
    o The store calls Aggregator Registration to register with the linked
      aggregator and to retrieve the aggregator's schema for the stream.
    o The schema migrations steps of §2.6.1 are completed.
* The containing application begins accepting event creation commands.

### 2.6.3 Event Creation

* The containing application receives or generates a StruoQL INSERT command.
* The containing application processes the insert:
  - The StruoQL Event Creation component transpiles the StruoQL to PostgreSQL.
  - The StruoQL Event Creation component calls Database Repository
    to execute the SQL INSERTs for the stream and pending aggregations.

### 2.6.4 Event Aggregation

* The containing application determines that events need to be aggregated, 
  according to the aggregation strategy for a given stream and aggregator.
* For each pending row in _struo_pending_aggregations for the given aggregator:
  - The Event Delivery component calls the Database Repository to query for the
    pending events for the given aggregator.
  - The Event Delivery component calls the HTTP aggregation endpoint, passing the
    needed PostgreSQL SQL code to insert the event into the aggregator's stream.
    (Likely this can be done with a bulk INSERT.)
  - The Event Delivery component calls the Database Repository to
    delete the delivered events (probably a bulk delete).

### 2.6.5 Event Obsolescence

* At some fixed interval the Event Obsolescence runs as follows:
* For each retention strategy configured on a stream:
  - The Database Repository is called to find events needing removal.
  - The Database Repository is called to delete those events

## 2.7 Software Component Details

### 2.7.1 StruoQL Schema Migration Component

* Name: schema_migration
* Path: ./services/schema_migration
* Type: Shared Library
* Language: TypeScript 
* Runtime: Bun
* Dependencies:
  - Database Repository
  - Bridge to ddl_facade.gleam

### 2.7.2 StruoQL Event Creation

* Name: event_creation
* Path: ./services/event_creation
* Type: Shared Library
* Language: TypeScript
* Runtime: Bun
* Dependencies:
  - Database Repository
  - Bridge to dml_facade.gleam

### 2.7.3 Database Repository

* Name: database_repo
* Path: ./services/database_repo
* Type: Shared Library
* Language: TypeScript
* Runtime: Bun
* Dependencies:
  - Bun SQL

### 2.7.4 PGLite

[Not a custom component, just a dependency for embedded PostgreSQL]

### 2.7.5 Aggregator Registration

* Name: aggregator_registration
* Path: ./services/aggregator_registration
* Type: Shared Library
* Language: TypeScript
* Runtime: Bun
* Dependencies:
  - Bun standard HTTP fetch API

### 2.7.6 Event Delivery

* Name: event_delivery
* Path: ./services/event_delivery
* Type: Shared Library
* Language: TypeScript
* Runtime: Bun
* Dependencies:
  - Bun standard HTTP fetch API
  - Database Repository

### 2.7.7 Event Obsolescence

* Name: event_obsolescence
* Path: ./services/event_obsolescence
* Type: Shared Library
* Language: TypeScript
* Runtime: Bun
* Dependencies:
  - Database Repository

### 2.7.8 Event Store

* Name: event_store
* Path: ./services/event_store
* Type: Shared Library
* Language: TypeScript
* Runtime: Bun
* Dependencies:
  - schema_migration
  - event_creation
  - database_repo (transitive)
  - aggregator_registration
  - event_delivery
  - event_obsolescence

